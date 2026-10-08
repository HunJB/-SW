#!/usr/bin/env bash
# w1_retention_delete.sh — 보존 기간 만료형 삭제 워크로드 (주 워크로드)
#
# cycle마다 파일 묶음(세대)을 하나 쓰고, 보존 기간이 지난 가장 오래된 세대를 한꺼번에 지운다.
# 측정 전에 RETENTION_CYCLES 세대를 먼저 써서 장치를 목표 사용률까지 채운다.
#
# 필수 환경변수: MNT, EVENTS_CSV
# 옵션 환경변수 (run_experiment.sh 가 용량에 맞춰 정해 준다):
#   FILE_SIZE_MIB     (기본 16)  파일 하나 크기
#   FILES_PER_CYCLE   (기본 20)  한 세대의 파일 수
#   RETENTION_CYCLES  (기본 5)   유지하는 세대 수
#   NUM_CYCLES        (기본 20)  측정 cycle 수

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

FILE_SIZE_MIB="${FILE_SIZE_MIB:-16}"
FILES_PER_CYCLE="${FILES_PER_CYCLE:-20}"
RETENTION_CYCLES="${RETENTION_CYCLES:-5}"
NUM_CYCLES="${NUM_CYCLES:-20}"

ensure_mounted
init_events_csv

write_gen() {   # 세대 번호
    local g="$1" i
    mkdir -p "${MNT}/w1_g${g}"
    for ((i = 0; i < FILES_PER_CYCLE; i++)); do
        write_file "${MNT}/w1_g${g}/f${i}.dat" "$FILE_SIZE_MIB"
    done
}
delete_gen() {  # 세대 번호
    local g="$1" i
    for ((i = 0; i < FILES_PER_CYCLE; i++)); do
        delete_file_with_lba_log "${MNT}/w1_g${g}/f${i}.dat"
    done
    rmdir "${MNT}/w1_g${g}"
    sync_deletes
}

echo "[W1] file=${FILE_SIZE_MIB}MiB files/gen=${FILES_PER_CYCLE} retention=${RETENTION_CYCLES} cycles=${NUM_CYCLES}"

# 사전 쓰기 (측정 구간 밖)
for ((g = 0; g < RETENTION_CYCLES; g++)); do
    echo "[W1] 사전 쓰기 세대 ${g}/${RETENTION_CYCLES}"
    write_gen "$g"
done
measure_begin

# 측정 cycle: 오래된 세대 삭제 → (정책에 따라 TRIM) → 새 세대 쓰기
# 삭제를 먼저 하므로 사용 중인 데이터는 RETENTION_CYCLES 세대를 넘지 않는다.
for ((c = 1; c <= NUM_CYCLES; c++)); do
    echo "[W1] cycle ${c}/${NUM_CYCLES}"
    log_event cycle_start "cycle$c"
    delete_gen $((c - 1))
    maybe_trim "$c"
    write_gen $((RETENTION_CYCLES + c - 1))
    end_cycle "$c"
done

echo "[W1] 완료. 이벤트 로그: $EVENTS_CSV"
