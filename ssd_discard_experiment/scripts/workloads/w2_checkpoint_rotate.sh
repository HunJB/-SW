#!/usr/bin/env bash
# w2_checkpoint_rotate.sh — 체크포인트 순환 워크로드
#
# 큰 단일 파일(체크포인트)을 주기적으로 쓰고, 최근 KEEP_LAST개만 남기고
# 그보다 오래된 체크포인트는 즉시 삭제한다. (AI 학습 체크포인트, DB 백업
# 순환과 비슷한 "삭제 단위가 큰" 패턴)
#
# 필수 환경변수: DEV, MNT, EVENTS_CSV
# 옵션 환경변수:
#   CHECKPOINT_SIZE_MIB  (기본 256)  체크포인트 하나 크기
#   KEEP_LAST             (기본 3)    최근 몇 개를 유지할지
#   NUM_CHECKPOINTS       (기본 15)   총 몇 번 체크포인트를 쓸지

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

CHECKPOINT_SIZE_MIB="${CHECKPOINT_SIZE_MIB:-256}"
KEEP_LAST="${KEEP_LAST:-3}"
NUM_CHECKPOINTS="${NUM_CHECKPOINTS:-15}"

ensure_mounted
init_events_csv

echo "[W2] 시작: checkpoint_size=${CHECKPOINT_SIZE_MIB}MiB keep_last=${KEEP_LAST} " \
     "num_checkpoints=${NUM_CHECKPOINTS}"

for ((i = 0; i < NUM_CHECKPOINTS; i++)); do
    echo "[W2] checkpoint ${i}/${NUM_CHECKPOINTS} 기록"
    write_file "${MNT}/w2_ckpt_${i}.bin" "$CHECKPOINT_SIZE_MIB"

    old_idx=$((i - KEEP_LAST))
    if [ "$old_idx" -ge 0 ]; then
        echo "[W2]   오래된 checkpoint ${old_idx} 삭제"
        delete_file_with_lba_log "${MNT}/w2_ckpt_${old_idx}.bin"
    fi
done

echo "[W2] 완료. 이벤트 로그: $EVENTS_CSV"
