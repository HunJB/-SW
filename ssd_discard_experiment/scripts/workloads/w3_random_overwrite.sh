#!/usr/bin/env bash
# w3_random_overwrite.sh — 대조군 워크로드
#
# 파일 삭제가 없다. discard 정책이 무엇이든 결과가 거의 같아야 정상이다(측정 기준점).
# 고정된 파일에 fio로 임의 쓰기만 한다. 쓰기 단위는 FTL 매핑 단위(16KB)에 맞춘다.
#
# 필수 환경변수: MNT, EVENTS_CSV
# 옵션 환경변수:
#   TARGET_FILE_SIZE_MIB (기본 2048)  대상 파일 크기
#   RUNTIME_SEC          (기본 300)   fio 실행 시간(초)
#   W3_BS                (기본 16k)   쓰기 단위

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

TARGET_FILE_SIZE_MIB="${TARGET_FILE_SIZE_MIB:-2048}"
RUNTIME_SEC="${RUNTIME_SEC:-300}"
W3_BS="${W3_BS:-16k}"
TARGET_FILE="${MNT}/w3_target.dat"

ensure_mounted
init_events_csv
command -v fio >/dev/null 2>&1 || die "fio가 설치되어 있지 않습니다 (apt install fio)"

echo "[W3] 대상 파일 준비 (${TARGET_FILE_SIZE_MIB}MiB)"
write_file "$TARGET_FILE" "$TARGET_FILE_SIZE_MIB"
measure_begin

echo "[W3] fio 임의 쓰기 ${RUNTIME_SEC}초 (삭제 없음)"
log_event cycle_start cycle1
fio --name=w3_random_write \
    --filename="$TARGET_FILE" \
    --rw=randwrite --bs="$W3_BS" --direct=1 --ioengine=libaio --iodepth=4 --numjobs=1 \
    --time_based=1 --runtime="$RUNTIME_SEC" \
    --lat_percentiles=1 --percentile_list=50:95:99 \
    --output-format=json --output="${EVENTS_CSV%/*}/w3_fio.json"
log_event file_create "$TARGET_FILE(randwrite)" "" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["jobs"][0]["write"]["io_bytes"])' "${EVENTS_CSV%/*}/w3_fio.json")"
end_cycle 1

echo "[W3] 완료"
