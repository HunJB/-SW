#!/usr/bin/env bash
# W1 보존 기간 만료형 워크로드 실행기 (ext4, 4가지 방식)
#   POLICY = nodiscard | immediate | batch | split
# 주의: 대상 장치를 mkfs 한다. 시리얼을 반드시 지정할 것.
#
# 사용법 예:
#   sudo DEV=/dev/nvme1n1 EXPECTED_SERIAL=XXXX POLICY=batch REP=1 ./w1_runner.sh
#
# 계측 펌웨어를 올린 보드에서는 EXPSTAT=1 을 붙이면 카운터 스냅샷이 자동 저장된다.
# Split Batch의 조각 수는 K로 바꾼다(민감도 실험: K=1, 4, 8, 16).
# 결과(OS 디스크에 저장): manifest.txt, events.csv, gen_*.json, probe_lat.*.log, fstrim.log,
#                         expstat_start.bin, expstat_c<cycle>.bin, expstat_end.bin, summary.txt, summary.json
set -euo pipefail

DEV=${DEV:?}
EXPECTED_SERIAL=${EXPECTED_SERIAL:?}
POLICY=${POLICY:?nodiscard|immediate|batch|split}
REP=${REP:-1}
MNT=${MNT:-/mnt/ssd-test}
U=${U:-0.85}                 # 목표 사용률
DEL_FRAC=${DEL_FRAC:-0.10}   # 한 cycle에 지우는 양 (용량 대비)
FILE_MB=${FILE_MB:-16}       # 파일 하나 크기
CYCLES=${CYCLES:-20}
BATCH_EVERY=${BATCH_EVERY:-5}
K=${K:-8}                    # Split Batch 조각 수
GAP=${GAP:-1}                # Split Batch 조각 사이 휴지(초)
REST=${REST:-10}             # cycle 끝 휴지(초)
PROBE_MB=${PROBE_MB:-256}
PROBE_IOPS=${PROBE_IOPS:-200}
WAIT_COUNTERS=${WAIT_COUNTERS:-0}   # 1이면 측정 시작/끝에서 Enter를 기다림(UART로 직접 기록할 때)
EXPSTAT=${EXPSTAT:-0}               # 1이면 펌웨어 카운터 스냅샷(admin 0xC2)을 측정 시작/끝에 자동 저장
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HOME/exp/w1_${POLICY}_rep${REP}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"
EVENTS="$OUT/events.csv"
echo "epoch_ns,cycle,phase" > "$EVENTS"
mark() { echo "$(date +%s%N),$1,$2" >> "$EVENTS"; }
snapshot() {   # $1 = start | c<cycle> | end
  [[ "$EXPSTAT" == "1" ]] || return 0
  nvme admin-passthru "$DEV" --opcode=0xC2 --data-len=4096 --read --raw-binary \
       > "$OUT/expstat_$1.bin" 2> "$OUT/expstat_$1.err" \
    || { echo "스냅샷 실패: $OUT/expstat_$1.err 확인 (펌웨어가 0xC2를 지원하는지)" >&2; exit 1; }
}

# --- 안전 확인 ---
serial=$(lsblk -dno SERIAL "$DEV" | tr -d ' ')
[[ "$serial" == "$EXPECTED_SERIAL" ]] || { echo "시리얼 불일치: $serial" >&2; exit 1; }
if findmnt -S "$DEV" >/dev/null; then umount "$DEV"; fi

# --- 자동 TRIM 차단 (끝나면 원래대로) ---
timer_was_active=$(systemctl is-active fstrim.timer || true)
systemctl stop fstrim.timer 2>/dev/null || true
restore() { [[ "$timer_was_active" == "active" ]] && systemctl start fstrim.timer || true; }
trap restore EXIT

# --- 파일시스템 생성과 마운트 ---
mkfs.ext4 -F -q -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$DEV"
mkdir -p "$MNT"
if [[ "$POLICY" == "immediate" ]]; then opts="discard,noatime"; else opts="nodiscard,noatime"; fi
mount -o "$opts" "$DEV" "$MNT"

C=$(df -B1 --output=avail "$MNT" | tail -1)
files_per_gen=$(python3 -c "print(max(1, int($DEL_FRAC*$C/($FILE_MB*1024*1024))))")
live_gens=$(python3 -c "print(max(2, int(($U*$C - $PROBE_MB*1024*1024)/($files_per_gen*$FILE_MB*1024*1024))))")

cat > "$OUT/manifest.txt" <<EOF
policy=$POLICY rep=$REP dev=$DEV serial=$serial mount_opts=$opts
capacity_bytes=$C U=$U del_frac=$DEL_FRAC file_mb=$FILE_MB
files_per_gen=$files_per_gen live_gens=$live_gens cycles=$CYCLES
batch_every=$BATCH_EVERY K=$K gap=$GAP rest=$REST probe_iops=$PROBE_IOPS expstat=$EXPSTAT
kernel=$(uname -r) fio=$(fio --version)
EOF
cat "$OUT/manifest.txt"

write_gen() {   # $1 = 세대 번호, $2 = cycle 번호
  local g=$1 c=$2 d="$MNT/g$1"
  mkdir -p "$d"
  mark "$c" "write_${g}_start"
  fio --name=gen"$g" --directory="$d" --nrfiles="$files_per_gen" \
      --filesize="${FILE_MB}M" --file_service_type=sequential \
      --rw=write --bs=1M --ioengine=libaio --iodepth=16 --direct=1 \
      --output-format=json --output="$OUT/gen_${g}.json"
  sync
  mark "$c" "write_${g}_end"
}

# --- 읽기 probe 파일과 사전 쓰기 (측정 전) ---
fio --name=probe_fill --filename="$MNT/probe.bin" --size="${PROBE_MB}M" \
    --rw=write --bs=1M --direct=1 --ioengine=libaio --iodepth=16 >/dev/null
for ((g = 0; g < live_gens; g++)); do write_gen "$g" -1; done
oldest=0; next=$live_gens
sync

if [[ "$WAIT_COUNTERS" == "1" ]]; then
  read -r -p "[측정 시작] 펌웨어 카운터를 기록한 뒤 Enter: "
fi
snapshot start
mark 0 "measure_start"

# --- 읽기 probe 시작 (끝에 SIGINT로 종료) ---
fio --name=probe --filename="$MNT/probe.bin" --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=1 --direct=1 --readonly \
    --rate_iops="$PROBE_IOPS" --time_based --runtime=86400 \
    --write_lat_log="$OUT/probe" --output-format=json --output="$OUT/probe.json" &
probe_pid=$!
sleep 5

# --- cycle 반복 ---
for ((c = 1; c <= CYCLES; c++)); do
  mark "$c" "delete_start"
  rm -rf "$MNT/g$oldest"
  sync
  mark "$c" "delete_end"
  oldest=$((oldest + 1))

  if (( c % BATCH_EVERY == 0 )); then
    case "$POLICY" in
      batch)
        mark "$c" "fstrim_start"
        fstrim -v "$MNT" >> "$OUT/fstrim.log"
        mark "$c" "fstrim_end" ;;
      split)
        MNT="$MNT" K="$K" GAP="$GAP" EVENTS="$EVENTS" CYCLE="$c" \
          "$HERE/split_trim.sh" >> "$OUT/fstrim.log" ;;
    esac
  fi

  write_gen "$next" "$c"
  next=$((next + 1))
  mark "$c" "rest_start"
  sleep "$REST"
  snapshot "c$c"
done

sync
mark "$CYCLES" "measure_end"
snapshot end
kill -INT "$probe_pid"; wait "$probe_pid" || true

if [[ "$WAIT_COUNTERS" == "1" ]]; then
  read -r -p "[측정 끝] 펌웨어 카운터를 기록한 뒤 Enter: "
fi

umount "$MNT"

# --- 카운터 요약과 실행 유효성 확인 ---
if [[ "$EXPSTAT" == "1" ]]; then
  python3 "$HERE/parse_expstat.py" --bin "$OUT/expstat_start.bin" "$OUT/expstat_end.bin" | tee "$OUT/summary.txt"
  python3 "$HERE/parse_expstat.py" --bin "$OUT/expstat_start.bin" "$OUT/expstat_end.bin" --json > "$OUT/summary.json"
  dsm=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["dsm_cmd"], int(d["rebooted"]))' "$OUT/summary.json")
  read -r dsm_cmd rebooted <<< "$dsm"
  verdict="valid"
  if [[ "$rebooted" == "1" ]]; then verdict="INVALID: 측정 중 보드가 재부팅됨"; fi
  if [[ "$POLICY" == "nodiscard" && "$dsm_cmd" != "0" ]]; then verdict="INVALID: No Discard인데 discard 명령 ${dsm_cmd}개가 도달함"; fi
  if [[ "$POLICY" != "nodiscard" && "$dsm_cmd" == "0" ]]; then verdict="INVALID: discard 명령이 한 번도 도달하지 않음"; fi
  echo "verdict=$verdict" | tee -a "$OUT/manifest.txt"
fi
echo "완료: $OUT"
