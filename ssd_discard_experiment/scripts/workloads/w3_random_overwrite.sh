#!/usr/bin/env bash
# w3_random_overwrite.sh — 대조군 워크로드
#
# 파일 삭제가 전혀 없는 조건. discard 방식을 뭘 쓰든 결과가 거의 같아야
# 정상(측정 기준점). fio로 고정된 파일에 랜덤 쓰기만 반복한다.
#
# 필수 환경변수: DEV, MNT, EVENTS_CSV
# 옵션 환경변수:
#   TARGET_FILE_SIZE_MIB (기본 2048)  미리 만들어둘 대상 파일 크기
#   RUNTIME_SEC            (기본 300)   fio 실행 시간(초)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

TARGET_FILE_SIZE_MIB="${TARGET_FILE_SIZE_MIB:-2048}"
RUNTIME_SEC="${RUNTIME_SEC:-300}"
TARGET_FILE="${MNT}/w3_target.dat"

ensure_mounted
init_events_csv

if ! command -v fio >/dev/null 2>&1; then
    echo "[ERROR] fio가 설치되어 있지 않습니다 (sudo apt install fio)" >&2
    exit 1
fi

echo "[W3] 대상 파일 준비 (${TARGET_FILE_SIZE_MIB}MiB)"
write_file "$TARGET_FILE" "$TARGET_FILE_SIZE_MIB"

echo "[W3] fio 랜덤 쓰기 ${RUNTIME_SEC}초 실행 (삭제 없음 — 대조군)"
fio --name=w3_random_write \
    --filename="$TARGET_FILE" \
    --rw=randwrite \
    --bs=4k \
    --direct=1 \
    --ioengine=libaio \
    --iodepth=4 \
    --numjobs=1 \
    --time_based=1 \
    --runtime="$RUNTIME_SEC" \
    --lat_percentiles=1 \
    --percentile_list=50:95:99 \
    --output-format=json \
    --output="${EVENTS_CSV%.csv}_w3_fio.json"

echo "[W3] 완료. 삭제가 없으므로 pre_delete_extent/unlink 이벤트는 기록되지 않음."
