#!/usr/bin/env bash
# w1_retention_delete.sh — 보존기간 만료형 삭제 워크로드 (연구 PDF의 주 워크로드)
#
# 날짜별 파일을 계속 쓰고, 보존 기간(RETENTION_FILES개)이 지난 가장 오래된
# 파일들을 한꺼번에 지운 뒤, 같은 양을 새로 기록하는 cycle을 반복한다.
#
# 필수 환경변수: DEV, MNT, EVENTS_CSV
# 옵션 환경변수:
#   FILE_SIZE_MIB     (기본 8)   파일 하나 크기
#   FILES_PER_CYCLE    (기본 20)  cycle마다 새로 쓰는 파일 수
#   RETENTION_CYCLES  (기본 5)   몇 cycle 지난 파일부터 삭제 대상인지
#   NUM_CYCLES        (기본 20)  전체 반복 횟수
#   SEED              (기본 42)  파일 이름 셔플용 시드 (재현성)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

FILE_SIZE_MIB="${FILE_SIZE_MIB:-8}"
FILES_PER_CYCLE="${FILES_PER_CYCLE:-20}"
RETENTION_CYCLES="${RETENTION_CYCLES:-5}"
NUM_CYCLES="${NUM_CYCLES:-20}"
SEED="${SEED:-42}"

ensure_mounted
init_events_csv
RANDOM=$SEED

echo "[W1] 시작: file_size=${FILE_SIZE_MIB}MiB files/cycle=${FILES_PER_CYCLE} " \
     "retention=${RETENTION_CYCLES}cycles cycles=${NUM_CYCLES}"

for ((cycle = 0; cycle < NUM_CYCLES; cycle++)); do
    echo "[W1] cycle ${cycle}/${NUM_CYCLES}"

    # 1) 이번 cycle의 새 파일들 기록 (시계열 DB의 "새 데이터 적재"에 해당)
    for ((i = 0; i < FILES_PER_CYCLE; i++)); do
        write_file "${MNT}/w1_c${cycle}_f${i}.dat" "$FILE_SIZE_MIB"
    done

    # 2) 보존 기간이 지난 cycle의 파일들을 한꺼번에 삭제
    expired_cycle=$((cycle - RETENTION_CYCLES))
    if [ "$expired_cycle" -ge 0 ]; then
        echo "[W1]   cycle ${expired_cycle}의 파일 삭제 (보존기간 만료)"
        for ((i = 0; i < FILES_PER_CYCLE; i++)); do
            delete_file_with_lba_log "${MNT}/w1_c${expired_cycle}_f${i}.dat"
        done
    fi

    # 짧은 휴지 구간 (PDF: "삭제 직후 아무 I/O 없이 종료하면 GC 차이를 놓칠 수 있다"
    # → 다음 cycle의 write가 바로 이어지므로 별도 sleep 불필요. 필요시 조정.
done

echo "[W1] 완료. 이벤트 로그: $EVENTS_CSV"
