#!/usr/bin/env bash
# run_all.sh — 여러 조합을 차례로 run_experiment.sh 에 넘긴다.
#
# 사용법 (root):
#   EXPECTED_SERIAL=<시리얼> MNT=/mnt/ssd-test EXPSTAT=1 [UART_LOG=<파일>] ./run_all.sh <mode>
#
#   poc    W1 × 4정책 × 1회                      (4회)
#   main   W1 × 4정책 × REPS회 (기본 5)           (20회)
#   ksweep W1 × split × K ∈ {1,4,8,16} × REPS회   (Split Batch 조각 수 민감도)
#   ctrl   W3 × 4정책 × 1회                      (삭제 없는 대조군)
#
# Cosmos+ 보드는 재부팅하면 FTL이 빈 상태로 돌아간다. 실행마다 같은 초기 상태에서 시작하도록
# PAUSE_BETWEEN=1 (기본)이면 각 실행 전에 멈춰 보드를 재부팅할 시간을 준다.
# 재부팅 뒤 장치 이름이 바뀔 수 있으므로 EXPECTED_SERIAL 로 장치를 찾는다.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

: "${MNT:?MNT 환경변수를 설정하세요}"
MODE="${1:?모드 지정: poc | main | ksweep | ctrl}"
REPS="${REPS:-5}"
TRIM_EVERY="${TRIM_EVERY:-5}"
PAUSE_BETWEEN="${PAUSE_BETWEEN:-1}"
POLICIES="nodiscard immediate batch split"

require_root

run_one() {   # workload policy rep
    echo ""
    echo "################################################################"
    echo "# $1 / $2 / rep=$3 ${SPLIT_K:+/ K=$SPLIT_K}"
    echo "################################################################"
    if [ "$PAUSE_BETWEEN" = "1" ]; then
        read -r -p "보드를 재부팅하고 nvme list 에 장치가 보이면 Enter (건너뛰려면 s): " ans
        if [ "$ans" = "s" ]; then echo "건너뜀"; return 0; fi
    fi
    "$SCRIPT_DIR/run_experiment.sh" "$1" "$2" "$TRIM_EVERY" "$3"
}

case "$MODE" in
    poc)
        for p in $POLICIES; do run_one w1 "$p" 1; done ;;
    main)
        # 반복을 바깥에 두어, 시간에 따른 장치 상태 변화가 한 정책에 몰리지 않게 한다
        for ((rep = 1; rep <= REPS; rep++)); do
            for p in $POLICIES; do run_one w1 "$p" "$rep"; done
        done ;;
    ksweep)
        for ((rep = 1; rep <= REPS; rep++)); do
            for k in 1 4 8 16; do SPLIT_K=$k; export SPLIT_K; run_one w1 split "$rep"; done
        done ;;
    ctrl)
        for p in $POLICIES; do run_one w3 "$p" 1; done ;;
    *) die "알 수 없는 모드: $MODE (poc|main|ksweep|ctrl)" ;;
esac

echo "[run_all] $MODE 완료. analysis/aggregate_and_plot.py 로 정리하세요."
