#!/usr/bin/env bash
# Split Batch: 마운트된 파일시스템 전체를 K조각으로 나눠 fstrim을 순서대로 실행하고 조각 사이에 쉰다.
# Batch(fstrim 한 번)와 TRIM 대상 범위가 같으므로 공정하게 비교된다.
#
# 사용법: sudo MNT=/mnt/ssd-test K=8 GAP=1 EVENTS=/path/events.csv CYCLE=5 ./split_trim.sh
set -euo pipefail

MNT=${MNT:?MNT를 지정하세요}
K=${K:-8}
GAP=${GAP:-1}
EVENTS=${EVENTS:-/dev/null}
CYCLE=${CYCLE:-0}

dev=$(findmnt -no SOURCE "$MNT")
size=$(blockdev --getsize64 "$dev")
# 조각 경계를 1MiB 단위로 맞춘다. 펌웨어의 매핑 단위(16KB) 중간에서 잘리면
# 그 slice는 어느 조각에서도 무효화되지 않아 Batch와 TRIM 양이 달라진다.
align=$((1024 * 1024))
chunk=$(( (size + K - 1) / K ))
chunk=$(( (chunk + align - 1) / align * align ))

for ((i = 0; i < K; i++)); do
  off=$(( i * chunk ))
  echo "$(date +%s%N),$CYCLE,split_trim_${i}_start" >> "$EVENTS"
  fstrim -v -o "$off" -l "$chunk" "$MNT" || true
  echo "$(date +%s%N),$CYCLE,split_trim_${i}_end" >> "$EVENTS"
  if (( i < K - 1 )); then sleep "$GAP"; fi
done
