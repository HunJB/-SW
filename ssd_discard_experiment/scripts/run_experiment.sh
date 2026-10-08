#!/usr/bin/env bash
# run_experiment.sh — "워크로드 × discard 정책" 한 조합을 1회 실행하고 runs/<run_id>/ 에 결과를 남긴다.
#
# 사용법 (root):
#   EXPECTED_SERIAL=<시리얼> MNT=/mnt/ssd-test EXPSTAT=1 \
#   ./run_experiment.sh <workload: w1|w2|w3> <policy: nodiscard|immediate|batch|split> [trim_every] [rep]
#
# 예: W1, 5 cycle마다 fstrim, 1회차
#   sudo -E ./run_experiment.sh w1 batch 5 1
#
# 주요 환경변수
#   EXPECTED_SERIAL  실험 장치의 시리얼. 주면 장치를 시리얼로 찾고 확인 질문을 생략한다
#   DEV              시리얼이 없는 환경(FEMU)에서 장치 경로를 직접 지정
#   EXPSTAT=1        Cosmos+ 계측 펌웨어의 UART 카운터로 GC·DSM 수치를 낸다. 측정 시작·끝과 cycle마다
#                    CP_WAIT(기본 13)초씩 쉬어 그 사이에 찍힌 PERIOD 줄을 기준점으로 쓴다
#   UART_LOG=<파일>  이 PC에서 uart_capture.py 로 받고 있는 UART 로그. 있으면 끝에서 바로 계산한다.
#                    없으면 UART 로그를 실행 폴더에 uart.log 로 복사한 뒤 analysis/correlate_and_compute.py 를 돌린다
#   AUTO_SIZE=1      (기본) W1/W2 크기를 장치 용량에 맞춘다: 목표 사용률 U, cycle당 삭제량 DEL_FRAC
#   U=0.85 DEL_FRAC=0.10 NUM_CYCLES=20 REST_SEC=10
#   SPLIT_K=8 SPLIT_GAP=1   split 정책의 조각 수와 조각 사이 휴지(초)
#   PROBE_IOPS=200 PROBE_MIB=256   배경 읽기 probe

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

: "${MNT:?MNT 환경변수를 설정하세요}"
WORKLOAD="${1:?워크로드 지정: w1|w2|w3}"
POLICY=$(normalize_policy "${2:?정책 지정: nodiscard|immediate|batch|split}")
TRIM_EVERY="${3:-${TRIM_EVERY:-5}}"
REP="${4:-1}"
EXPSTAT="${EXPSTAT:-0}"
AUTO_SIZE="${AUTO_SIZE:-1}"
U="${U:-0.85}"
DEL_FRAC="${DEL_FRAC:-0.10}"
NUM_CYCLES="${NUM_CYCLES:-20}"
REST_SEC="${REST_SEC:-10}"
SPLIT_K="${SPLIT_K:-8}"
SPLIT_GAP="${SPLIT_GAP:-1}"
PROBE_IOPS="${PROBE_IOPS:-200}"
PROBE_MIB="${PROBE_MIB:-256}"

case "$WORKLOAD" in
    w1) WORKLOAD_SCRIPT="$SCRIPT_DIR/workloads/w1_retention_delete.sh" ;;
    w2) WORKLOAD_SCRIPT="$SCRIPT_DIR/workloads/w2_checkpoint_rotate.sh" ;;
    w3) WORKLOAD_SCRIPT="$SCRIPT_DIR/workloads/w3_random_overwrite.sh" ;;
    *) die "알 수 없는 워크로드: $WORKLOAD" ;;
esac

require_root
resolve_dev
for tool in fio filefrag python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool 이 설치되어 있지 않습니다"
done
if [ "$EXPSTAT" = "1" ]; then
    [ -f "$REPO_TOOLS/parse_expstat.py" ] || die "tools/parse_expstat.py 를 찾지 못했습니다"
fi

ktag=""
if [ "$POLICY" = "split" ]; then ktag="_k${SPLIT_K}"; fi
RUN_ID="${WORKLOAD}_${POLICY}${ktag}_rep${REP}_$(date +%Y%m%d_%H%M%S)"
RUNS_ROOT="${RUNS_ROOT:-$SCRIPT_DIR/../runs}"
RUN_DIR="$RUNS_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
EVENTS_CSV="$RUN_DIR/host_events.csv"
CP_WAIT="${CP_WAIT:-13}"
export DEV MNT POLICY TRIM_EVERY EXPSTAT RUN_DIR EVENTS_CSV REST_SEC SPLIT_K SPLIT_GAP NUM_CYCLES CP_WAIT

echo "[RUN] $RUN_ID → $RUN_DIR"

# --- 주기적 자동 TRIM 차단 (끝나면 원래대로) ---
timer_was_active=$(systemctl is-active fstrim.timer 2>/dev/null || true)
systemctl stop fstrim.timer 2>/dev/null || true
PROBE_PID=""
cleanup() {
    if [ -n "$PROBE_PID" ]; then kill -INT "$PROBE_PID" 2>/dev/null || true; wait "$PROBE_PID" 2>/dev/null || true; fi
    if findmnt "$MNT" >/dev/null 2>&1; then umount "$MNT" || true; fi
    if [ "$timer_was_active" = "active" ]; then systemctl start fstrim.timer || true; fi
}
trap cleanup EXIT

# 1) 포맷 + 정책 적용
"$SCRIPT_DIR/apply_discard_policy.sh" "$POLICY"
init_events_csv

# 2) 크기 결정: 용량에 맞추지 않으면 장치가 차지 않아 GC가 일어나지 않는다
CAP=$(df -B1 --output=avail "$MNT" | tail -1 | tr -d ' ')
if [ "$AUTO_SIZE" = "1" ]; then
    case "$WORKLOAD" in
        w1)
            export FILE_SIZE_MIB="${FILE_SIZE_MIB:-16}"
            read -r FILES_PER_CYCLE RETENTION_CYCLES < <(python3 - "$CAP" "$U" "$DEL_FRAC" "$FILE_SIZE_MIB" "$PROBE_MIB" <<'PY'
import sys
cap, u, d, fmib, pmib = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
files = max(1, int(d * cap / (fmib << 20)))
gen = files * (fmib << 20)
print(files, max(2, int((u * cap - (pmib << 20)) / gen)))
PY
)
            export FILES_PER_CYCLE RETENTION_CYCLES ;;
        w2)
            read -r CHECKPOINT_SIZE_MIB KEEP_LAST < <(python3 - "$CAP" "$U" "$DEL_FRAC" "$PROBE_MIB" <<'PY'
import sys
cap, u, d, pmib = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
ck = max(1, int(d * cap) >> 20)
print(ck, max(2, int((u * cap - (pmib << 20)) / (ck << 20))))
PY
)
            export CHECKPOINT_SIZE_MIB KEEP_LAST ;;
        w3)
            export TARGET_FILE_SIZE_MIB="${TARGET_FILE_SIZE_MIB:-$(python3 -c "print(int(($U * $CAP) / 2**20) - $PROBE_MIB)")}" ;;
    esac
fi

# 3) manifest
serial=$(lsblk -dno SERIAL "$DEV" | tr -d ' ')
python3 - "$RUN_DIR/manifest.json" <<PY
import json, sys
m = {
    "run_id": "$RUN_ID", "workload": "$WORKLOAD", "policy": "$POLICY", "rep": int("$REP"),
    "dev": "$DEV", "serial": "$serial", "mnt": "$MNT",
    "mount_opts": "$(findmnt -no OPTIONS "$MNT")",
    "capacity_bytes": int("$CAP"), "auto_size": int("$AUTO_SIZE"), "U": float("$U"), "del_frac": float("$DEL_FRAC"),
    "num_cycles": int("$NUM_CYCLES"), "trim_every": int("$TRIM_EVERY"), "rest_sec": float("$REST_SEC"),
    "split_k": int("$SPLIT_K"), "split_gap": float("$SPLIT_GAP"),
    "file_size_mib": "${FILE_SIZE_MIB:-}", "files_per_cycle": "${FILES_PER_CYCLE:-}",
    "retention_cycles": "${RETENTION_CYCLES:-}", "checkpoint_size_mib": "${CHECKPOINT_SIZE_MIB:-}",
    "keep_last": "${KEEP_LAST:-}", "target_file_size_mib": "${TARGET_FILE_SIZE_MIB:-}",
    "probe_iops": int("$PROBE_IOPS"), "expstat": int("$EXPSTAT"),
    "kernel": "$(uname -r)", "fio": "$(fio --version)",
    "start_time": "$(date -Iseconds)",
}
json.dump(m, open(sys.argv[1], "w"), indent=2, ensure_ascii=False)
PY

# 4) 배경 읽기 probe: 일정한 속도(PROBE_IOPS)로 읽어 지연만 관찰한다. W3는 fio 쓰기 자체가 측정 대상.
if [ "$WORKLOAD" != "w3" ]; then
    PROBE_FILE="$MNT/probe.bin"
    dd if=/dev/urandom of="$PROBE_FILE" bs=1M count="$PROBE_MIB" oflag=direct conv=fsync status=none
    log_event probe_start
    fio --name=read_probe --filename="$PROBE_FILE" \
        --rw=randread --bs=4k --direct=1 --ioengine=libaio --iodepth=1 --numjobs=1 \
        --readonly --allow_file_create=0 --rate_iops="$PROBE_IOPS" \
        --time_based=1 --runtime=864000 \
        --lat_percentiles=1 --percentile_list=50:95:99 \
        --write_lat_log="$RUN_DIR/probe" --log_unix_epoch=1 \
        --output-format=json --output="$RUN_DIR/fio_probe.json" &
    PROBE_PID=$!
    sleep 3
fi

# 5) 워크로드
"$WORKLOAD_SCRIPT"

# 6) 마무리
sync
log_event measure_end
checkpoint end
if [ -n "$PROBE_PID" ]; then
    kill -INT "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=""
fi
umount "$MNT"

if [ "$EXPSTAT" = "1" ] && [ -n "${UART_LOG:-}" ] && [ -r "${UART_LOG:-}" ]; then
    cp "$UART_LOG" "$RUN_DIR/uart.log"
fi

python3 - "$RUN_DIR/manifest.json" <<'PY'
import datetime, json, sys
m = json.load(open(sys.argv[1]))
m["end_time"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
json.dump(m, open(sys.argv[1], "w"), indent=2, ensure_ascii=False)
PY

# 7) 요약 (FTL 이벤트 로그가 없어도 카운터와 probe만으로 계산한다)
python3 "$SCRIPT_DIR/../analysis/correlate_and_compute.py" "$RUN_DIR" --skew "${SKEW:-1.0}" || true

echo "=============================================="
echo "[RUN] $RUN_ID 종료. 결과: $RUN_DIR"
if [ "$EXPSTAT" = "1" ] && [ ! -f "$RUN_DIR/uart.log" ]; then
    echo "  GC·DSM 수치는 UART 로그가 있어야 나옵니다. 실험이 끝난 뒤"
    echo "  UART를 받은 PC의 로그를 $RUN_DIR/uart.log 로 복사하고"
    echo "  python3 analysis/correlate_and_compute.py $RUN_DIR 를 다시 실행하세요."
    echo "  (여러 실행을 하나의 로그로 받았다면 그 파일을 각 실행 폴더에 같은 이름으로 복사하면 됩니다.)"
elif [ "$EXPSTAT" != "1" ]; then
    echo "  FEMU: /tmp/femu_ftl_log.csv 를 $RUN_DIR/ftl_gc_log.csv 로 복사한 뒤"
    echo "        analysis/correlate_and_compute.py $RUN_DIR 를 다시 실행하세요."
fi
echo "=============================================="
