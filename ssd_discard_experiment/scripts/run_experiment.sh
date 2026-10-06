#!/usr/bin/env bash
# run_experiment.sh — "파일시스템 × 워크로드 × discard정책 × 사용률" 한 조합을
# 1회 실행하고, 결과를 runs/<run_id>/ 아래에 저장한다.
#
# 사용법:
#   DEV=/dev/nvme0n1 MNT=/mnt/ssd-test \
#   ./run_experiment.sh <workload: w1|w2|w3> <policy: immediate|none|fstrim> \
#                        <fstrim_cycle_n> <rep_number>
#
# 예시: ext4 + W1 + fstrim(5cycle마다) + 1번째 반복
#   ./run_experiment.sh w1 fstrim 5 1

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${DEV:?DEV 환경변수를 설정하세요}"
: "${MNT:?MNT 환경변수를 설정하세요}"

WORKLOAD="${1:?워크로드 지정: w1|w2|w3}"
POLICY="${2:?정책 지정: immediate|none|fstrim}"
FSTRIM_CYCLE_N="${3:-5}"
REP="${4:-1}"

RUN_ID="${WORKLOAD}_${POLICY}_fstrim${FSTRIM_CYCLE_N}_rep${REP}_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${SCRIPT_DIR}/../runs/${RUN_ID}"
mkdir -p "$RUN_DIR"

export EVENTS_CSV="${RUN_DIR}/host_events.csv"

echo "[RUN] ${RUN_ID}"
echo "[RUN] 결과 저장 위치: ${RUN_DIR}"

# 1) 장치 초기화 + 정책 적용 (포맷 포함 — apply_discard_policy.sh 내부에서 확인 프롬프트 뜸)
DEV="$DEV" MNT="$MNT" "${SCRIPT_DIR}/apply_discard_policy.sh" "$POLICY"

# 2) manifest 기록 시작
cat > "${RUN_DIR}/manifest.json" <<EOF
{
  "run_id": "${RUN_ID}",
  "dev": "${DEV}",
  "mnt": "${MNT}",
  "workload": "${WORKLOAD}",
  "policy": "${POLICY}",
  "fstrim_cycle_n": ${FSTRIM_CYCLE_N},
  "rep": ${REP},
  "start_time": "$(date -Iseconds)"
}
EOF

# 3) 배경 읽기 probe 시작 (존재하면) — W3는 probe 대신 fio 쓰기 자체가 측정 대상이므로 생략
if [ "$WORKLOAD" != "w3" ]; then
    PROBE_FILE="${MNT}/probe.bin"
    dd if=/dev/urandom of="$PROBE_FILE" bs=1M count=64 conv=fsync status=none
    fio --name=read_probe \
        --filename="$PROBE_FILE" \
        --rw=randread \
        --bs=4k \
        --direct=1 \
        --ioengine=libaio \
        --iodepth=1 \
        --numjobs=1 \
        --readonly \
        --allow_file_create=0 \
        --time_based=1 \
        --runtime=99999 \
        --lat_percentiles=1 \
        --percentile_list=50:95:99 \
        --output-format=json \
        --output="${RUN_DIR}/fio_probe.json" &
    PROBE_PID=$!
    echo "[RUN] 배경 read probe 시작 (pid=${PROBE_PID})"
else
    PROBE_PID=""
fi

# 4) 워크로드 실행 (fstrim 정책이면 cycle마다 fstrim을 끼워 넣는 래퍼 사용)
case "$WORKLOAD" in
    w1) WORKLOAD_SCRIPT="${SCRIPT_DIR}/workloads/w1_retention_delete.sh" ;;
    w2) WORKLOAD_SCRIPT="${SCRIPT_DIR}/workloads/w2_checkpoint_rotate.sh" ;;
    w3) WORKLOAD_SCRIPT="${SCRIPT_DIR}/workloads/w3_random_overwrite.sh" ;;
    *) echo "[ERROR] 알 수 없는 워크로드: $WORKLOAD" >&2; exit 1 ;;
esac

if [ "$POLICY" = "fstrim" ] && [ "$WORKLOAD" != "w3" ]; then
    # fstrim 정책: 워크로드를 cycle 단위로 쪼개 실행하면서 N cycle마다 fstrim
    # (간단화를 위해, 워크로드 스크립트의 NUM_CYCLES를 1로 고정하고 바깥에서 반복 호출)
    TOTAL_CYCLES="${TOTAL_CYCLES:-20}"
    for ((c = 0; c < TOTAL_CYCLES; c++)); do
        DEV="$DEV" MNT="$MNT" EVENTS_CSV="$EVENTS_CSV" NUM_CYCLES=1 \
            "$WORKLOAD_SCRIPT"
        if (( (c + 1) % FSTRIM_CYCLE_N == 0 )); then
            echo "[RUN] cycle $((c + 1)): fstrim 실행"
            t_before=$(date +%s%N)
            sudo fstrim -v "$MNT" | tee -a "${RUN_DIR}/fstrim_output.log"
            t_after=$(date +%s%N)
            echo "${t_before},fstrim_start,,," >> "$EVENTS_CSV"
            echo "${t_after},fstrim_end,,," >> "$EVENTS_CSV"
        fi
    done
else
    DEV="$DEV" MNT="$MNT" EVENTS_CSV="$EVENTS_CSV" "$WORKLOAD_SCRIPT"
fi

# 5) 종료 뒷정리
if [ -n "$PROBE_PID" ]; then
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
fi

sync
echo "[RUN] 완료 시각 기록"
python3 - "$RUN_DIR" <<'PYEOF'
import json, sys, datetime
run_dir = sys.argv[1]
path = f"{run_dir}/manifest.json"
with open(path) as f:
    m = json.load(f)
m["end_time"] = datetime.datetime.now().isoformat()
with open(path, "w") as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
PYEOF

echo "=============================================="
echo "[RUN] ${RUN_ID} 종료"
echo "[RUN] 다음 단계:"
echo "  1) FTL 쪽 로그(ftl_gc_log.csv / dsm 카운터 등)를 ${RUN_DIR}/ 로 복사"
echo "     - FEMU: /tmp/femu_ftl_log.csv 를 복사"
echo "     - Cosmos+: UART/카운터 덤프를 읽어와 ${RUN_DIR}/ftl_dsm_stats.txt 로 저장"
echo "  2) analysis/correlate_and_compute.py 실행"
echo "=============================================="
