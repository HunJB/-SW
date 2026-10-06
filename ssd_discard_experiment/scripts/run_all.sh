#!/usr/bin/env bash
# run_all.sh — 여러 조합을 순서대로 run_experiment.sh에 넘겨 자동 반복 실행
#
# 사용법:
#   DEV=/dev/nvme0n1 MNT=/mnt/ssd-test ./run_all.sh poc
#   DEV=/dev/nvme0n1 MNT=/mnt/ssd-test ./run_all.sh main   # 필수 본실험 9회 (PDF1 기준)
#
# poc  : w1 워크로드 × (immediate, none, fstrim) × 1회 = 3회
# main : w1 워크로드 × (immediate, none, fstrim) × 3반복 = 9회

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${DEV:?DEV 환경변수를 설정하세요}"
: "${MNT:?MNT 환경변수를 설정하세요}"

MODE="${1:?모드 지정: poc | main}"
FSTRIM_CYCLE_N="${FSTRIM_CYCLE_N:-5}"

run_one() {
    local workload="$1" policy="$2" rep="$3"
    echo ""
    echo "################################################################"
    echo "# ${workload} / ${policy} / rep=${rep}"
    echo "################################################################"
    DEV="$DEV" MNT="$MNT" "${SCRIPT_DIR}/run_experiment.sh" \
        "$workload" "$policy" "$FSTRIM_CYCLE_N" "$rep"
}

case "$MODE" in
    poc)
        for policy in immediate none fstrim; do
            run_one w1 "$policy" 1
        done
        echo "[run_all] POC 완료 (3회). analysis/correlate_and_compute.py로 결과를 먼저 확인하세요."
        echo "[run_all] 통과 기준(PDF2 8장): 방식 간 WAF 차이 0.2 이상, 또는"
        echo "          discard 안 보냄 조건에서 죽은 데이터 비율 10% 이상"
        ;;
    main)
        for policy in immediate none fstrim; do
            for rep in 1 2 3; do
                run_one w1 "$policy" "$rep"
            done
        done
        echo "[run_all] 필수 본실험 완료 (9회)."
        ;;
    *)
        echo "[ERROR] 알 수 없는 모드: $MODE (poc|main)" >&2
        exit 1
        ;;
esac
