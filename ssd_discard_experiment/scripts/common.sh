#!/usr/bin/env bash
# common.sh — 실행 스크립트와 워크로드 스크립트가 함께 쓰는 함수 모음.
# `source "$SCRIPT_DIR/common.sh"` (워크로드에서는 `../common.sh`) 로 불러온다.
#
# 모든 스크립트는 root로 실행한다 (sudo -E ./run_experiment.sh ...).
# 안에서 sudo를 따로 부르지 않는다.

set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_TOOLS="$(cd "$COMMON_DIR/../../tools" 2>/dev/null && pwd || true)"   # parse_expstat.py, split_trim.sh

FS_BLOCK=4096   # ext4 블록 크기. Cosmos+의 논리 블록(4KB)과 같다

now_ns() { date +%s%N; }

die() { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "root로 실행하세요 (예: sudo -E $0 ...)"
}

# ---------- 정책 이름 ----------
# nodiscard(none) | immediate | batch(fstrim) | split
normalize_policy() {
    case "$1" in
        none|nodiscard)  echo nodiscard ;;
        immediate)       echo immediate ;;
        fstrim|batch)    echo batch ;;
        split)           echo split ;;
        *) die "알 수 없는 정책: $1 (nodiscard|immediate|batch|split)" ;;
    esac
}

# ---------- 장치 확인 ----------
# EXPECTED_SERIAL 이 있으면 시리얼로 장치를 찾는다(재부팅하면 nvme0n1/nvme1n1 이름이 바뀔 수 있다).
# DEV 도 함께 주었다면 둘이 일치해야 한다.
resolve_dev() {
    if [ -n "${EXPECTED_SERIAL:-}" ]; then
        local found
        found=$(lsblk -dno NAME,SERIAL | awk -v s="$EXPECTED_SERIAL" '$2 == s {print "/dev/" $1}')
        [ -n "$found" ] || die "시리얼 $EXPECTED_SERIAL 인 장치를 찾지 못했습니다"
        [ "$(echo "$found" | wc -l)" -eq 1 ] || die "시리얼 $EXPECTED_SERIAL 인 장치가 여러 개입니다"
        if [ -n "${DEV:-}" ] && [ "$DEV" != "$found" ]; then
            die "DEV=$DEV 의 시리얼이 $EXPECTED_SERIAL 이 아닙니다 (그 시리얼은 $found)"
        fi
        DEV="$found"
    fi
    : "${DEV:?DEV 또는 EXPECTED_SERIAL 을 설정하세요}"
    [ -b "$DEV" ] || die "$DEV 는 블록 장치가 아닙니다"
    # 시스템 디스크 보호: / 또는 /boot 가 올라가 있는 디스크는 거부
    if lsblk -nro MOUNTPOINT "$DEV" | grep -qE '^(/|/boot|/boot/efi)$'; then
        die "$DEV 에 시스템 파티션이 마운트되어 있습니다. 실험 장치가 아닙니다"
    fi
    export DEV
}

# ---------- 이벤트 로그 ----------
# 열: event_time_ns,event_type,path,start_lba,length_bytes
#   start_lba    : 장치 기준 4KB 블록 번호 (create_extent, pre_delete_extent 에서만)
#   length_bytes : 바이트
init_events_csv() {
    : "${EVENTS_CSV:?EVENTS_CSV 를 설정하세요}"
    if [ ! -f "$EVENTS_CSV" ]; then
        echo "event_time_ns,event_type,path,start_lba,length_bytes" > "$EVENTS_CSV"
    fi
}
log_event() {   # 종류 [path] [start_lba] [length_bytes]
    echo "$(now_ns),$1,${2:-},${3:-},${4:-}" >> "$EVENTS_CSV"
}

ensure_mounted() {
    : "${MNT:?MNT 를 설정하세요}"
    findmnt "$MNT" >/dev/null 2>&1 || die "$MNT 가 마운트되어 있지 않습니다. apply_discard_policy.sh 를 먼저 실행하세요"
}

# ---------- 파일 쓰기와 삭제 ----------
# write_file <경로> <크기_MiB> : page cache를 거치지 않고 쓰고 fsync
write_file() {
    local path="$1" size_mib="$2"
    dd if=/dev/urandom of="$path" bs=1M count="$size_mib" oflag=direct conv=fsync status=none
    log_event file_create "$path" "" "$((size_mib * 1024 * 1024))"
    if [ "${LOG_EXTENTS:-1}" = "1" ]; then log_file_extents "$path" create_extent; fi
}

# 파일이 차지한 장치 범위를 기록한다 (쓴 직후: create_extent, 삭제 직전: pre_delete_extent).
# filefrag -v 의 한 줄: "   0:        0..    2047:      34816..     36863:   2048: ..."
# 숫자 사이 공백 수가 달라져도 되도록 ':' 로 나눠 3번째(physical), 4번째(length) 칸을 읽는다.
log_file_extents() {   # 경로 [이벤트 이름]
    local path="$1" kind="${2:-pre_delete_extent}" t
    t=$(now_ns)
    filefrag -v "$path" 2>/dev/null | awk -F: -v path="$path" -v t="$t" -v bs="$FS_BLOCK" -v kind="$kind" '
        $1 ~ /^[ \t]*[0-9]+$/ && NF >= 4 {
            split($3, phys, /\.\./)
            start = phys[1] + 0; len = $4 + 0
            if (len > 0) printf "%s,%s,%s,%d,%d\n", t, kind, path, start, len * bs
        }' >> "$EVENTS_CSV"
}

# delete_file_with_lba_log <경로> : 범위를 기록하고 unlink. sync는 하지 않는다(sync_deletes 참고).
delete_file_with_lba_log() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "[WARN] $path 없음, 건너뜀" >&2
        return 0
    fi
    if [ "${LOG_EXTENTS:-1}" = "1" ]; then log_file_extents "$path"; fi
    rm -f "$path"
    log_event unlink "$path"
}

# 한 cycle의 삭제가 끝난 뒤 한 번 호출한다. 삭제를 파일마다 sync하면 저널 commit이 파일 수만큼
# 생겨 immediate 정책의 discard 명령 모양이 달라지므로, 묶음 삭제 뒤에 한 번만 sync한다.
sync_deletes() {
    sync
    log_event sync_complete
}

# ---------- 펌웨어 카운터 스냅샷 (Cosmos+ 계측 펌웨어) ----------
# EXPSTAT=1 일 때만 동작. 원본 펌웨어는 모르는 admin 명령을 받으면 멈추므로 자동으로 보내지 않는다.
snapshot() {   # 이름
    [ "${EXPSTAT:-0}" = "1" ] || return 0
    : "${RUN_DIR:?RUN_DIR 를 설정하세요}"
    nvme admin-passthru "$DEV" --opcode=0xC2 --data-len=4096 --read --raw-binary \
        > "$RUN_DIR/expstat_$1.bin" 2> "$RUN_DIR/expstat_$1.err" \
        || die "카운터 스냅샷 실패: $RUN_DIR/expstat_$1.err"
}

# ---------- 측정 구간과 cycle 끝 처리 ----------
# 워크로드는 사전 쓰기가 끝난 뒤 measure_begin 을 한 번, cycle마다 삭제 직후 maybe_trim, 끝에 end_cycle 을 부른다.
measure_begin() {
    sync
    snapshot start
    log_event measure_start
}

# maybe_trim <cycle 번호(1부터)> : 삭제 직후에 부른다. 정책이 batch/split 이고 TRIM_EVERY 번째 cycle이면 TRIM을 보낸다.
maybe_trim() {
    local c="$1" policy every
    policy=$(normalize_policy "${POLICY:-nodiscard}")
    every="${TRIM_EVERY:-5}"
    if [ "$policy" != "batch" ] && [ "$policy" != "split" ]; then return 0; fi
    if (( c % every != 0 )); then return 0; fi
    log_event fstrim_start "cycle$c"
    if [ "$policy" = "batch" ]; then
        fstrim -v "$MNT" >> "${RUN_DIR:-.}/fstrim_output.log"
    else
        [ -x "$REPO_TOOLS/split_trim.sh" ] || die "tools/split_trim.sh 를 찾지 못했습니다"
        MNT="$MNT" K="${SPLIT_K:-8}" GAP="${SPLIT_GAP:-1}" "$REPO_TOOLS/split_trim.sh" \
            >> "${RUN_DIR:-.}/fstrim_output.log"
    fi
    log_event fstrim_end "cycle$c"
}

# end_cycle <cycle 번호> : 쉬고, 스냅샷을 남긴다.
end_cycle() {
    local c="$1"
    sleep "${REST_SEC:-10}"
    snapshot "c$c"
    log_event cycle_end "cycle$c"
}
