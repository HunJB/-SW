#!/usr/bin/env bash
# w4_scattered_delete.sh — 흩어진 삭제 워크로드
#
# W1은 가장 오래된 세대를 통째로 지우고 바로 새 세대를 쓰기 때문에, 파일시스템이 방금 비운
# 자리를 곧바로 다시 쓴다. 그러면 SSD는 discard가 없어도 덮어쓰기로 옛 데이터가 무효임을 알게 되고,
# discard 정책 간 GC 차이가 거의 나지 않는다.
# W4는 살아 있는 파일 가운데 무작위로 고른 파일을 지운다. 지운 자리가 장치 전체에 흩어지고,
# 같은 시기에 쓴 블록 안에 살아 있는 데이터와 지운 데이터가 섞인다. discard가 없으면 SSD는
# 지운 데이터를 여전히 유효하다고 보고 GC 때 옮긴다.
#
# 필수 환경변수: MNT, EVENTS_CSV
# 옵션 환경변수 (run_experiment.sh 가 용량에 맞춰 정해 준다):
#   FILE_SIZE_MIB     (기본 4)    파일 하나 크기
#   LIVE_FILES        (기본 2000) 사전 쓰기로 만드는 파일 수 (측정 중에도 이 수를 유지)
#   FILES_PER_CYCLE   (기본 200)  cycle마다 지우고 새로 쓰는 파일 수
#   NUM_CYCLES        (기본 20)
#   W4_SEED           (기본 1)    무작위 선택의 시드. 같은 시드면 정책이 달라도 같은 파일을 지운다

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

FILE_SIZE_MIB="${FILE_SIZE_MIB:-4}"
LIVE_FILES="${LIVE_FILES:-2000}"
FILES_PER_CYCLE="${FILES_PER_CYCLE:-200}"
NUM_CYCLES="${NUM_CYCLES:-20}"
W4_SEED="${W4_SEED:-1}"

ensure_mounted
init_events_csv

LIVE_LIST="${RUN_DIR:-/tmp}/w4_live.txt"
: > "$LIVE_LIST"

path_of() {   # 파일 번호 → 경로 (한 디렉터리에 파일이 너무 많지 않게 500개씩 나눈다)
    echo "${MNT}/w4_d$(( $1 / 500 ))/f$1.dat"
}
write_one() {
    local id="$1" p
    p=$(path_of "$id")
    mkdir -p "$(dirname "$p")"
    write_file "$p" "$FILE_SIZE_MIB"
    echo "$id" >> "$LIVE_LIST"
}

echo "[W4] file=${FILE_SIZE_MIB}MiB live=${LIVE_FILES} per_cycle=${FILES_PER_CYCLE} cycles=${NUM_CYCLES} seed=${W4_SEED}"

# 사전 쓰기 (측정 구간 밖)
for ((i = 0; i < LIVE_FILES; i++)); do
    if (( i % 200 == 0 )); then echo "[W4] 사전 쓰기 ${i}/${LIVE_FILES}"; fi
    write_one "$i"
done
next_id=$LIVE_FILES
measure_begin

for ((c = 1; c <= NUM_CYCLES; c++)); do
    echo "[W4] cycle ${c}/${NUM_CYCLES}"
    log_event cycle_start "cycle$c"
    # 살아 있는 파일 중 FILES_PER_CYCLE개를 시드와 cycle 번호로 정해진 순서로 고른다
    mapfile -t victims < <(python3 - "$LIVE_LIST" "$FILES_PER_CYCLE" "$W4_SEED" "$c" <<'PY'
import random, sys
live = [l.strip() for l in open(sys.argv[1]) if l.strip()]
n, seed, c = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
pick = random.Random(seed * 100003 + c).sample(live, min(n, len(live)))
gone = set(pick)
open(sys.argv[1], "w").write("".join(x + "\n" for x in live if x not in gone))
print("\n".join(pick))
PY
)
    for id in "${victims[@]}"; do
        delete_file_with_lba_log "$(path_of "$id")"
    done
    sync_deletes
    maybe_trim "$c"
    for ((k = 0; k < ${#victims[@]}; k++)); do
        write_one "$next_id"
        next_id=$((next_id + 1))
    done
    end_cycle "$c"
done

echo "[W4] 완료. 이벤트 로그: $EVENTS_CSV"
