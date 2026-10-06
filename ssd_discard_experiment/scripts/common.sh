#!/usr/bin/env bash
# common.sh — 워크로드 스크립트들이 공유하는 함수 모음
# 각 워크로드 스크립트 맨 위에서 `source "$(dirname "$0")/../common.sh"` 로 불러옵니다.

set -euo pipefail

# 필수 환경변수 체크
: "${DEV:?DEV 환경변수(실험 대상 블록장치, 예: /dev/nvme0n1)를 설정하세요}"
: "${MNT:?MNT 환경변수(마운트 포인트, 예: /mnt/ssd-test)를 설정하세요}"
: "${EVENTS_CSV:?EVENTS_CSV 환경변수(호스트 이벤트 로그 저장 경로)를 설정하세요}"

# host_events.csv 헤더가 없으면 생성
init_events_csv() {
    if [ ! -f "$EVENTS_CSV" ]; then
        echo "event_time_ns,event_type,path,start_lba,length_bytes" > "$EVENTS_CSV"
    fi
}

now_ns() {
    date +%s%N
}

# 파일을 생성하고 실제 데이터로 채운 뒤 fsync·close
# 사용법: write_file <경로> <크기_MiB>
write_file() {
    local path="$1"
    local size_mib="$2"
    dd if=/dev/urandom of="$path" bs=1M count="$size_mib" conv=fsync status=none
    local t
    t=$(now_ns)
    echo "${t},file_create,${path},,${size_mib}MiB" >> "$EVENTS_CSV"
}

# 삭제 직전 LBA 범위를 filefrag로 뽑아 기록한 뒤 unlink
# 사용법: delete_file_with_lba_log <경로>
delete_file_with_lba_log() {
    local path="$1"

    if [ ! -f "$path" ]; then
        echo "[WARN] delete_file_with_lba_log: $path 없음, 건너뜀" >&2
        return 0
    fi

    # filefrag -v 출력에서 physical offset(block 단위) 구간을 뽑아낸다.
    # 출력 형식은 커널/파일시스템 버전에 따라 조금씩 다를 수 있으니
    # 실제 환경에서 한 번 `filefrag -v "$path"` 를 눈으로 확인하고
    # 아래 awk 패턴을 맞춰보세요.
    local frag_out
    frag_out=$(filefrag -v "$path" 2>/dev/null || true)

    local t_before
    t_before=$(now_ns)

    echo "$frag_out" | awk -v path="$path" -v t="$t_before" '
        /^[ \t]*[0-9]+:/ {
            # 컬럼 예시: ext: logical_offset: physical_offset: length: flags
            # physical offset(3번째 컬럼)과 length(4번째 컬럼 근처)를 느슨하게 파싱
            gsub(/\.\./, " ", $4)
            split($4, phys, " ")
            print t ",pre_delete_extent," path "," phys[1] "," $6
        }
    ' >> "$EVENTS_CSV"

    rm -f "$path"
    local t_after
    t_after=$(now_ns)
    echo "${t_after},unlink,${path},," >> "$EVENTS_CSV"

    sync
    local t_sync
    t_sync=$(now_ns)
    echo "${t_sync},sync_complete,${path},," >> "$EVENTS_CSV"
}

ensure_mounted() {
    if ! findmnt "$MNT" >/dev/null 2>&1; then
        echo "[ERROR] $MNT 가 마운트되어 있지 않습니다. apply_discard_policy.sh 를 먼저 실행하세요." >&2
        exit 1
    fi
}
