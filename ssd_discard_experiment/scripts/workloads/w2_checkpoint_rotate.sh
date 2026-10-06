#!/usr/bin/env bash
# w2_checkpoint_rotate.sh — 체크포인트 순환 워크로드
#
# 큰 파일(체크포인트)을 주기적으로 쓰고 최근 KEEP_LAST개만 남긴다.
# 삭제 단위가 큰 패턴(학습 체크포인트, 백업 순환)이다.
#
# 필수 환경변수: MNT, EVENTS_CSV
# 옵션 환경변수:
#   CHECKPOINT_SIZE_MIB  (기본 256)  체크포인트 하나 크기
#   KEEP_LAST            (기본 3)    유지할 개수
#   NUM_CYCLES           (기본 15)   측정 cycle 수 (cycle마다 체크포인트 하나)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

CHECKPOINT_SIZE_MIB="${CHECKPOINT_SIZE_MIB:-256}"
KEEP_LAST="${KEEP_LAST:-3}"
NUM_CYCLES="${NUM_CYCLES:-${NUM_CHECKPOINTS:-15}}"

ensure_mounted
init_events_csv

echo "[W2] checkpoint=${CHECKPOINT_SIZE_MIB}MiB keep_last=${KEEP_LAST} cycles=${NUM_CYCLES}"

# 사전 쓰기 (측정 구간 밖)
for ((i = 0; i < KEEP_LAST; i++)); do
    write_file "${MNT}/w2_ckpt_${i}.bin" "$CHECKPOINT_SIZE_MIB"
done
measure_begin

for ((c = 1; c <= NUM_CYCLES; c++)); do
    echo "[W2] cycle ${c}/${NUM_CYCLES}"
    log_event cycle_start "cycle$c"
    delete_file_with_lba_log "${MNT}/w2_ckpt_$((c - 1)).bin"
    sync_deletes
    maybe_trim "$c"
    write_file "${MNT}/w2_ckpt_$((KEEP_LAST + c - 1)).bin" "$CHECKPOINT_SIZE_MIB"
    end_cycle "$c"
done

echo "[W2] 완료. 이벤트 로그: $EVENTS_CSV"
