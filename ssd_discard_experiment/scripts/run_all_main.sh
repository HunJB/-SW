#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-main}"
PLAN_ONLY=0
if [[ "$MODE" == "--plan" ]]; then
  MODE="main"
  PLAN_ONLY=1
elif [[ "${2:-}" == "--plan" ]]; then
  PLAN_ONLY=1
fi

EXPECTED_SERIAL="${EXPECTED_SERIAL:-SSDD515T}"
MNT="${MNT:-/mnt/ssd-test}"

EXP_ROOT="${EXP_ROOT:-$HOME/ssd-exp}"
REPO="${REPO:-$EXP_ROOT/repo}"
MAIN_ROOT="${MAIN_ROOT:-$EXP_ROOT/main_experiment}"

RUN_EXPERIMENT="$REPO/ssd_discard_experiment/scripts/run_experiment.sh"
ANALYZER="$REPO/ssd_discard_experiment/analysis/correlate_and_compute.py"
AGGREGATOR="$REPO/ssd_discard_experiment/analysis/aggregate_and_plot.py"

REPS="${REPS:-3}"
TRIM_EVERY="${TRIM_EVERY:-5}"
POLICIES="${POLICIES:-nodiscard immediate batch}"

AUTO_SIZE="${AUTO_SIZE:-1}"
U="${U:-0.85}"
DEL_FRAC="${DEL_FRAC:-0.10}"
FILE_SIZE_MIB="${FILE_SIZE_MIB:-16}"
NUM_CYCLES="${NUM_CYCLES:-20}"
CP_WAIT="${CP_WAIT:-13}"
REST_SEC="${REST_SEC:-10}"
PROBE_IOPS="${PROBE_IOPS:-200}"
PROBE_MIB="${PROBE_MIB:-256}"
SPLIT_K="${SPLIT_K:-8}"
SPLIT_GAP="${SPLIT_GAP:-1}"
SKEW="${SKEW:-1.0}"

STOP_ON_INVALID="${STOP_ON_INVALID:-1}"
UART_IMPORT_DIR="${UART_IMPORT_DIR:-}"
RESUME_MASTER="${RESUME_MASTER:-}"

die(){ echo "[ERROR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "필수 명령 없음: $1"; }

case "$MODE" in
  main|poc|ctrl|ksweep) ;;
  *) die "mode: main | poc | ctrl | ksweep" ;;
esac

[[ "$REPS" =~ ^[1-9][0-9]*$ ]] || die "REPS는 1 이상의 정수"

declare -a PLAN=()
add(){ PLAN+=("$1|$2|$3|${4:-}"); }

case "$MODE" in
  main)
    for ((rep=1; rep<=REPS; rep++)); do
      for p in $POLICIES; do
        if [[ "$p" == split ]]; then add w1 "$p" "$rep" "$SPLIT_K"; else add w1 "$p" "$rep" ""; fi
      done
    done
    ;;
  poc)
    for p in $POLICIES; do
      if [[ "$p" == split ]]; then add w1 "$p" 1 "$SPLIT_K"; else add w1 "$p" 1 ""; fi
    done
    ;;
  ctrl)
    for p in $POLICIES; do
      if [[ "$p" == split ]]; then add w3 "$p" 1 "$SPLIT_K"; else add w3 "$p" 1 ""; fi
    done
    ;;
  ksweep)
    for ((rep=1; rep<=REPS; rep++)); do
      for k in 1 4 8 16; do add w1 split "$rep" "$k"; done
    done
    ;;
esac

echo "============================================================"
echo "본 실험 계획"
echo "MAIN_ROOT=$MAIN_ROOT"
echo "MODE=$MODE / REPS=$REPS / POLICIES=$POLICIES"
echo "총 ${#PLAN[@]}회"
echo "============================================================"
i=0
for row in "${PLAN[@]}"; do
  i=$((i+1))
  IFS='|' read -r wl pol rep k <<<"$row"
  printf "%2d. %-3s %-10s rep=%s %s\n" "$i" "$wl" "$pol" "$rep" "${k:+K=$k}"
done

[[ "$PLAN_ONLY" == 0 ]] || exit 0

for c in lsblk awk findmnt swapon git uname python3 sudo tee tar blockdev readlink grep find sort comm cp systemctl cmp diff; do need "$c"; done
[[ -d "$REPO/.git" ]] || die "repo 없음: $REPO"
[[ -f "$RUN_EXPERIMENT" ]] || die "run_experiment.sh 없음"
[[ -f "$ANALYZER" ]] || die "analyzer 없음"
[[ -f "$AGGREGATOR" ]] || die "aggregator 없음"

mkdir -p "$MAIN_ROOT" "$MAIN_ROOT/archive"
sudo -v
COMMIT="$(git -C "$REPO" rev-parse HEAD)"

plan_text(){
  i=0
  for row in "${PLAN[@]}"; do
    i=$((i+1))
    IFS='|' read -r wl pol rep k <<<"$row"
    printf "%d\t%s\t%s\t%s\t%s\n" "$i" "$wl" "$pol" "$rep" "$k"
  done
}

config_text(){
cat <<EOF
mode=$MODE
commit=$COMMIT
expected_serial=$EXPECTED_SERIAL
reps=$REPS
policies=$POLICIES
trim_every=$TRIM_EVERY
U=$U
del_frac=$DEL_FRAC
file_size_mib=$FILE_SIZE_MIB
num_cycles=$NUM_CYCLES
cp_wait=$CP_WAIT
rest_sec=$REST_SEC
probe_iops=$PROBE_IOPS
probe_mib=$PROBE_MIB
split_k=$SPLIT_K
split_gap=$SPLIT_GAP
skew=$SKEW
EOF
}

if [[ -n "$RESUME_MASTER" ]]; then
  MASTER="$(readlink -f "$RESUME_MASTER")"
  [[ -d "$MASTER" ]] || die "resume master 없음: $MASTER"
  t1="$(mktemp)"; t2="$(mktemp)"
  plan_text > "$t1"; config_text > "$t2"
  cmp -s "$t1" "$MASTER/plan.tsv" || { diff -u "$MASTER/plan.tsv" "$t1" || true; die "plan 불일치"; }
  cmp -s "$t2" "$MASTER/config.txt" || { diff -u "$MASTER/config.txt" "$t2" || true; die "config 불일치"; }
  rm -f "$t1" "$t2"
else
  STAMP="$(date +%Y%m%d_%H%M%S)"
  MASTER="$MAIN_ROOT/${MODE}-${STAMP}"
  mkdir -p "$MASTER"/{runs,run_meta,report}
  plan_text > "$MASTER/plan.tsv"
  config_text > "$MASTER/config.txt"
  git -C "$REPO" status --short > "$MASTER/git_status.txt"
  uname -a > "$MASTER/host_kernel.txt"
fi

printf '%s\n' "$MASTER" > "$MAIN_ROOT/current-main.txt"
echo "[MASTER] $MASTER"

resolve_dev(){
  mapfile -t devs < <(lsblk -dpno NAME,SERIAL | awk -v s="$EXPECTED_SERIAL" '$2==s {print $1}')
  [[ "${#devs[@]}" -eq 1 ]] || die "serial=$EXPECTED_SERIAL 장치가 정확히 1개여야 함"
  DEV="${devs[0]}"
}

preflight(){
  resolve_dev
  [[ -b "$DEV" ]] || die "block device 아님: $DEV"

  echo "[DEVICE] $DEV"
  lsblk -o NAME,PATH,MODEL,SERIAL,SIZE,FSTYPE,MOUNTPOINTS "$DEV"

  if lsblk -nrpo NAME,MOUNTPOINTS "$DEV" | awk 'NF>=2 && $2!="" {x=1} END{exit !x}'; then
    die "대상 장치 또는 자식에 mount가 남아 있음"
  fi

  while read -r s; do
    [[ -n "${s:-}" ]] || continue
    [[ "$s" != "$DEV"* ]] || die "대상 장치가 swap에 사용 중: $s"
  done < <(swapon --noheadings --show=NAME 2>/dev/null || true)

  systemctl is-active --quiet fstrim.service 2>/dev/null && die "fstrim.service active"

  SIZE="$(sudo blockdev --getsize64 "$DEV")"
  LBS="$(sudo blockdev --getss "$DEV")"
  echo "[DEVICE] size=$SIZE lbs=$LBS"
}

validate_uart(){
  local f="$1"
  [[ -s "$f" ]] || die "UART log 없음: $f"
  grep -Eq '^[0-9]+[[:space:]]+EXPSTAT,' "$f" || die "timestamped EXPSTAT 형식 아님"
  grep -q 'EXPSTAT,tag=PERIOD,' "$f" || die "PERIOD 없음"
}

validate_result(){
  local d="$1"
  python3 - "$d" "$NUM_CYCLES" <<'PY'
import csv, json, sys
from pathlib import Path
d=Path(sys.argv[1]); n=int(sys.argv[2])
s=json.load(open(d/"summary.json"))
e=json.load(open(d/"expstat_summary.json"))
bad=False
print("[CHECK] source=", s.get("source"), "verdict=", s.get("verdict"), "rebooted=", e.get("rebooted"))
if s.get("source")!="cosmos-uart": bad=True
if str(s.get("verdict","")).lower()!="valid": bad=True
if e.get("rebooted") is True: bad=True
rows=list(csv.DictReader(open(d/"cycles.csv", newline="")))
print("[CHECK] cycle intervals=", len(rows), "expected=", n+1)
if len(rows)!=n+1: bad=True
raise SystemExit(2 if bad else 0)
PY
}

TOTAL="${#PLAN[@]}"
IDX=0

for row in "${PLAN[@]}"; do
  IDX=$((IDX+1))
  IFS='|' read -r WL POLICY REP K <<<"$row"
  KTAG="${K:+_k$K}"
  TAG="$(printf '%02d_%s_%s%s_r%s' "$IDX" "$WL" "$POLICY" "$KTAG" "$REP")"
  META="$MASTER/run_meta/$TAG"
  mkdir -p "$META"

  if [[ -f "$META/DONE" ]]; then
    echo "[SKIP] $TAG already done"
    continue
  fi

  UART_NAME="uart_${TAG}.log"

  echo
  echo "############################################################"
  echo "# $IDX / $TOTAL : $WL / $POLICY / rep=$REP ${K:+/ K=$K}"
  echo "############################################################"
  echo "Development PC:"
  echo "  1) FTL 초기화"
  echo "  2) 초기 counter clean 확인"
  echo "  3) SDK serial terminal 닫기"
  echo "  4) 새 UART capture 시작: $UART_NAME"
  read -r -p "완료 후 READY 입력 (중단 q): " a
  [[ "$a" != q ]] || exit 0
  [[ "$a" == READY ]] || die "READY 필요"

  preflight
  {
    echo "device=$DEV"
    echo "size=$SIZE"
    echo "lbs=$LBS"
    echo "uart_name=$UART_NAME"
    date -Iseconds
  } > "$META/preflight.txt"

  find "$MASTER/runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort > "$META/before.txt"

  set +e
  set -o pipefail
  sudo env -u UART_LOG -u DEV \
    EXPECTED_SERIAL="$EXPECTED_SERIAL" \
    MNT="$MNT" EXPSTAT=1 RUNS_ROOT="$MASTER/runs" \
    AUTO_SIZE="$AUTO_SIZE" U="$U" DEL_FRAC="$DEL_FRAC" \
    FILE_SIZE_MIB="$FILE_SIZE_MIB" NUM_CYCLES="$NUM_CYCLES" \
    CP_WAIT="$CP_WAIT" REST_SEC="$REST_SEC" \
    PROBE_IOPS="$PROBE_IOPS" PROBE_MIB="$PROBE_MIB" \
    SPLIT_K="${K:-$SPLIT_K}" SPLIT_GAP="$SPLIT_GAP" \
    bash "$RUN_EXPERIMENT" "$WL" "$POLICY" "$TRIM_EVERY" "$REP" \
    2>&1 | tee "$META/console.log"
  rc=${PIPESTATUS[0]}
  set -e
  echo "$rc" > "$META/run_exit_code.txt"

  find "$MASTER/runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort > "$META/after.txt"
  mapfile -t newdirs < <(comm -13 "$META/before.txt" "$META/after.txt")
  [[ "${#newdirs[@]}" -eq 1 ]] || die "새 run 폴더를 정확히 하나 식별하지 못함"
  RUN_DIR="$MASTER/runs/${newdirs[0]}"
  echo "$RUN_DIR" > "$META/run_dir.txt"

  [[ "$rc" -eq 0 ]] || {
    sudo dmesg -T | tail -n 160 > "$META/dmesg_tail.txt" 2>/dev/null || true
    touch "$META/FAILED_WORKLOAD"
    die "$TAG workload 실패"
  }

  echo
  echo "Windows UART capture를 Ctrl+C로 종료하고,"
  echo "이번 로그를 다음 경로로 복사:"
  echo "  $META/uart.log"

  if [[ -n "$UART_IMPORT_DIR" && -s "$UART_IMPORT_DIR/$UART_NAME" ]]; then
    cp "$UART_IMPORT_DIR/$UART_NAME" "$META/uart.log"
    echo "[UART] 자동 가져오기 완료"
  else
    read -r -p "복사 후 UART 입력 (중단 q): " u
    [[ "$u" != q ]] || exit 0
    [[ "$u" == UART ]] || die "UART 입력 필요"
  fi

  validate_uart "$META/uart.log"
  sudo cp "$META/uart.log" "$RUN_DIR/uart.log"

  set +e
  sudo python3 "$ANALYZER" "$RUN_DIR" --skew "$SKEW" 2>&1 | tee "$META/analysis.log"
  arc=${PIPESTATUS[0]}
  set -e
  echo "$arc" > "$META/analyze_exit_code.txt"
  [[ "$arc" -eq 0 ]] || die "$TAG 분석 실패"

  set +e
  validate_result "$RUN_DIR" 2>&1 | tee "$META/validation.log"
  vrc=${PIPESTATUS[0]}
  set -e
  echo "$vrc" > "$META/validation_exit_code.txt"

  if [[ "$vrc" -ne 0 && "$STOP_ON_INVALID" == 1 ]]; then
    touch "$META/FAILED_VALIDATION"
    die "$TAG validation 실패"
  fi

  cp "$RUN_DIR/summary.json" "$META/summary.json"
  cp "$RUN_DIR/expstat_summary.json" "$META/expstat_summary.json"
  cp "$RUN_DIR/cycles.csv" "$META/cycles.csv"
  touch "$META/DONE"

  echo "[DONE] $TAG"
done

echo "[AGGREGATE]"
cd "$REPO"
python3 "$AGGREGATOR" "$MASTER/runs" --out-dir "$MASTER/report" \
  2>&1 | tee "$MASTER/aggregate.log"

ARCHIVE="$MAIN_ROOT/archive/$(basename "$MASTER").tar.gz"
sudo tar -czf "$ARCHIVE" -C "$(dirname "$MASTER")" "$(basename "$MASTER")"
sudo chown "$(id -u):$(id -g)" "$ARCHIVE"

echo
echo "================ ALL DONE ================"
echo "MASTER : $MASTER"
echo "REPORT : $MASTER/report"
echo "ARCHIVE: $ARCHIVE"
