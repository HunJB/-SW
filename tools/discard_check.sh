#!/usr/bin/env bash
# Cosmos+ 보드의 현재 펌웨어가 discard(Deallocate)를 실제로 처리하는지 호스트에서 간접 확인한다.
# 주의: 대상 장치의 데이터를 모두 지운다. 반드시 OpenSSD 장치인지 확인하고 실행할 것.
#
# 사용법: sudo DEV=/dev/nvme1n1 EXPECTED_SERIAL=보드시리얼 ./discard_check.sh
set -euo pipefail

DEV=${DEV:?DEV를 지정하세요 (예: /dev/nvme1n1)}
EXPECTED_SERIAL=${EXPECTED_SERIAL:?nvme list에서 확인한 OpenSSD 시리얼을 지정하세요}
RUNTIME=${RUNTIME:-300}          # 임의 쓰기 구간 길이(초)
OUT=${OUT:-$HOME/exp/discard_check_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"
cd "$OUT"

# 1. 장치 확인: 시리얼이 다르거나 마운트되어 있으면 중단
serial=$(lsblk -dno SERIAL "$DEV" | tr -d ' ')
if [[ "$serial" != "$EXPECTED_SERIAL" ]]; then
  echo "시리얼 불일치: $DEV 는 '$serial' 입니다. 중단합니다." >&2
  exit 1
fi
if findmnt -S "$DEV" >/dev/null || lsblk -no MOUNTPOINTS "$DEV" | grep -q .; then
  echo "$DEV 또는 그 파티션이 마운트되어 있습니다. umount 후 다시 실행하세요." >&2
  exit 1
fi

# 2. 장치가 discard 지원을 표시하는지 기록
{
  echo "== nvme id-ctrl (ONCS) =="
  nvme id-ctrl "$DEV" -H | grep -i -A10 "oncs" || true
  echo "== nvme id-ns (DLFEAT) =="
  nvme id-ns "$DEV" -H | grep -i -A6 "dlfeat" || true
  echo "== lsblk -D =="
  lsblk -D "$DEV"
} | tee support.txt

# 3. 작은 범위 discard가 명령 수준에서 받아들여지는지
if blkdiscard -o 0 -l $((4*1024*1024)) "$DEV"; then
  echo "small_blkdiscard=ok" | tee -a support.txt
else
  echo "small_blkdiscard=fail (장치가 discard를 받지 않음. 이후 단계 의미 없음)" | tee -a support.txt
  exit 0
fi

fio_common=(--filename="$DEV" --ioengine=libaio --direct=1 --group_reporting)

# 4. 장치 전체를 한 번 순차로 채워 빈 블록을 없앤다
fio --name=fill "${fio_common[@]}" --rw=write --bs=128k --iodepth=32 \
    --output-format=json --output=fill.json

# 5. 임의 쓰기 1차: GC 때문에 대역폭이 떨어지는지 기록
fio --name=before "${fio_common[@]}" --rw=randwrite --bs=4k --iodepth=32 \
    --time_based --runtime="$RUNTIME" --write_bw_log=before --log_avg_msec=1000 \
    --output-format=json --output=before.json

# 6. 장치 전체 discard. 걸린 시간도 기록
start=$(date +%s.%N)
blkdiscard "$DEV"
end=$(date +%s.%N)
echo "full_blkdiscard_seconds=$(echo "$end - $start" | bc)" | tee -a support.txt

# 7. 임의 쓰기 2차: discard가 FTL까지 반영됐다면 처음처럼 높은 대역폭으로 돌아온다
fio --name=after "${fio_common[@]}" --rw=randwrite --bs=4k --iodepth=32 \
    --time_based --runtime="$RUNTIME" --write_bw_log=after --log_avg_msec=1000 \
    --output-format=json --output=after.json

echo "완료: $OUT"
echo "before_bw.1.log 와 after_bw.1.log 의 초반 대역폭을 비교하세요."
