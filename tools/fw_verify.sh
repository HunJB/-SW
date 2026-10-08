#!/usr/bin/env bash
# 계측·Deallocate 펌웨어를 올린 Cosmos+ 보드가 설계대로 동작하는지 호스트에서 검증한다.
# 주의: 대상 장치의 앞쪽 약 1.6GiB를 덮어쓴다. 반드시 OpenSSD 장치인지 확인하고 실행할 것.
#
# 사용법: sudo DEV=/dev/nvme1n1 EXPECTED_SERIAL=보드시리얼 ./fw_verify.sh
#
# 카운터는 펌웨어가 10초마다 UART로 내보내는 EXPSTAT,tag=PERIOD 줄에서 읽는다.
#   - 실행 중에는 데이터 내용 검사(T3~T5)만 바로 판정하고, 카운터 기대값은 expect.csv 에 적어 둔다.
#   - 카운터를 확인할 시점마다 13초 동안 아무것도 하지 않고 기다린다. 그 사이에 PERIOD 줄이
#     하나 찍혀 그 시점의 값이 된다 (checkpoints.csv 에 시각을 남긴다).
#   - 끝난 뒤 UART 로그(tools/uart_capture.py 로 받은 것)로 판정한다:
#       python3 tools/parse_expstat.py --check <결과 폴더> <uart.log>
#     UART를 이 PC에서 받고 있다면 UART_LOG=<그 파일> 을 주면 끝에서 바로 판정한다.
#   - UART를 받는 PC와 이 PC의 시계가 맞아 있어야 한다 (timedatectl).
#
# 단계 (데이터 검사가 하나라도 실패하면 거기서 멈춘다)
#   T0 장치 확인, discard 지원 표시
#   T1 쓰기 카운터: 쓴 양과 host_wr_B 가 같은지
#   T2 Deallocate 기본: 쓴 범위를 discard 하면 그만큼 무효화되고, 다시 하면 변화가 없는지.
#      방금 써서 data buffer에 남은 범위는 건너뛰는지
#   T3 경계: 16KB slice 를 일부만 덮는 범위는 건드리지 않는지
#   T4 데이터 보존: discard 하지 않은 범위는 그대로이고, discard 한 범위에 다시 쓰면 읽히는지
#   T5 동시성: 쓰기·검증이 도는 동안 다른 범위에 쓰기와 discard 를 반복해도 문제가 없는지
#
# 결과: $OUT/report.txt, checkpoints.csv, expect.csv, (판정 뒤) counter_check.txt
set -euo pipefail

DEV=${DEV:?DEV를 지정하세요 (예: /dev/nvme1n1)}
EXPECTED_SERIAL=${EXPECTED_SERIAL:?nvme list에서 확인한 OpenSSD 시리얼을 지정하세요}
OUT=${OUT:-$HOME/exp/fw_verify_$(date +%Y%m%d_%H%M%S)}
T5_LOOPS=${T5_LOOPS:-3}          # T5에서 쓰기·검증을 반복하는 횟수
CMD_TIMEOUT=${CMD_TIMEOUT:-300}  # 명령 하나가 이 시간(초) 안에 끝나지 않으면 보드가 멈춘 것으로 본다
DIRECT=${DIRECT:-1}              # 0은 시험용(파일을 장치 대신 쓸 때)
CP_WAIT=${CP_WAIT:-13}           # 카운터 시점마다 기다리는 시간(초). PERIOD 주기(10초) + 시계 차이 여유
UART_LOG=${UART_LOG:-}           # 이 PC에서 받고 있는 UART 로그. 있으면 끝에서 바로 판정
HERE=$(cd "$(dirname "$0")" && pwd)
PARSE="$HERE/parse_expstat.py"

MiB=$((1024 * 1024))
SLICE=16384
LBA=4096

mkdir -p "$OUT"
REPORT="$OUT/report.txt"
: > "$REPORT"

say()  { echo "$*" | tee -a "$REPORT"; }
fail() { say "FAIL  $*"; say "중단. 보드가 멈췄다면 UART 마지막 출력을 기록하고 원본 펌웨어로 되돌리세요."; exit 1; }
pass() { say "PASS  $*"; }

if [[ "$DIRECT" == "1" ]]; then OD="oflag=direct"; ID="iflag=direct"; FD="--direct=1"; else OD="conv=notrunc"; ID=""; FD="--direct=0"; fi

run() {   # 멈춘 보드에서 스크립트가 끝없이 기다리지 않도록 시간 제한을 둔다
  timeout "$CMD_TIMEOUT" "$@" || fail "명령 실패 또는 ${CMD_TIMEOUT}초 초과: $*"
}
echo "name,epoch_ns,idle_until_ns" > "$OUT/checkpoints.csv"
echo "label,from,to,field,op,value" > "$OUT/expect.csv"
cp_mark() {  # $1 = 시점 이름. 기록한 뒤 CP_WAIT 초 동안 아무것도 하지 않는다
  sync
  local t; t=$(date +%s%N)
  echo "$1,$t,$(( t + CP_WAIT * 1000000000 ))" >> "$OUT/checkpoints.csv"
  sleep "$CP_WAIT"
}
want() {     # $1 = 설명, $2 = 시작 시점, $3 = 끝 시점, $4 = 항목, $5 = eq|ge, $6 = 값
  echo "$1,$2,$3,$4,$5,$6" >> "$OUT/expect.csv"
  local sign="="; [[ "$5" == "ge" ]] && sign="≥"
  say "      기록 $1: $4 $sign $6 (UART 로그로 판정)"
}
expect() { # $1 = 설명, $2 = 실제, $3 = 기대
  if [[ "$2" == "$3" ]]; then say "      ok   $1 = $2"; else fail "$1: 실제 $2, 기대 $3"; fi
}
wr()   { run dd if="$1" of="$DEV" bs=1M seek="$2" count="$3" $OD status=none; }       # 파일, 위치(MiB), 길이(MiB)
rd()   { timeout "$CMD_TIMEOUT" dd if="$DEV" bs=1M skip="$1" count="$2" $ID status=none; }  # 위치(MiB), 길이(MiB)
rd_slice() { timeout "$CMD_TIMEOUT" dd if="$DEV" bs="$SLICE" skip=$(( $1 / SLICE )) count=1 $ID status=none; }  # 위치(바이트)의 slice 하나
trim() { run blkdiscard -o "$1" -l "$2" "$DEV"; }                                      # 위치(바이트), 길이(바이트)
# 마지막에 쓴 2MB는 펌웨어의 data buffer에 남아 discard 대상에서 빠진다.
# 다른 곳에 4MiB를 써서 buffer를 비워 둔다.
flush_buf() { wr /dev/zero 1536 4; }

# ---------- T0 ----------
say "== T0 장치 확인 =="
serial=$(lsblk -dno SERIAL "$DEV" | tr -d ' ')
[[ "$serial" == "$EXPECTED_SERIAL" ]] || fail "시리얼 불일치: $DEV 는 '$serial'"
if findmnt -S "$DEV" >/dev/null || lsblk -no MOUNTPOINT "$DEV" | grep -q .; then
  fail "$DEV 또는 그 파티션이 마운트되어 있음. umount 후 다시 실행"
fi
size=$(blockdev --getsize64 "$DEV")
(( size >= 2048 * MiB )) || fail "장치가 2GiB보다 작음"
[[ "$(blockdev --getss "$DEV")" == "$LBA" ]] || fail "논리 블록 크기가 4096이 아님"

oncs=$(nvme id-ctrl "$DEV" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["oncs"])')
(( oncs & 0x4 )) || fail "장치가 Dataset Management 지원을 표시하지 않음 (ONCS=$oncs). 패치한 펌웨어가 아님"
disc_max=$(lsblk -dbno DISC-MAX "$DEV" | tr -d ' ')
[[ "$disc_max" != "0" ]] || fail "커널이 discard를 켜지 않음 (DISC-MAX=0)"
if [[ "${ASSUME_UART_OK:-0}" != "1" ]]; then
  echo "UART에 'EXPSTAT,tag=PERIOD,schema=2,...' 줄이 약 10초마다 찍히고 있어야 하고,"
  echo "그 출력을 uart_capture.py 로 파일에 받고 있어야 합니다."
  read -r -p "둘 다 확인했으면 yes 입력: " ans
  [[ "$ans" == "yes" ]] || fail "UART 주기 출력 또는 로그 수집이 확인되지 않아 중단"
fi
cp_mark t0
pass "T0 시리얼 $serial, ONCS=$oncs, DISC-MAX=$disc_max"

# ---------- T1 ----------
say "== T1 쓰기 카운터 =="
wr /dev/zero 0 256
cp_mark t1
want "T1 256MiB 쓰기" t0 t1 host_wr_B eq "$((256 * MiB))"
want "T1 discard 없음" t0 t1 dsm_cmd eq 0
pass "T1 (카운터는 나중에 판정)"

# ---------- T2 ----------
say "== T2 Deallocate 기본 =="
flush_buf; cp_mark t2a
trim 0 $((64 * MiB)); cp_mark t2b
want "T2 discard 도달" t2a t2b dsm_cmd ge 1
want "T2 요청량" t2a t2b dsm_req_B eq "$((64 * MiB))"
want "T2 무효화" t2a t2b dsm_inval_B eq "$((64 * MiB))"
want "T2 무시 없음" t2a t2b dsm_ignored_B eq 0
trim 0 $((64 * MiB)); cp_mark t2c
want "T2 재요청 무효화 없음" t2b t2c dsm_inval_B eq 0
want "T2 재요청은 이미 해제" t2b t2c dsm_already_free_B eq "$((64 * MiB))"
# 방금 쓴 1MiB(64 slice)는 아직 data buffer에 dirty로 남아 있으므로 건너뛰어야 한다(dsm_ignored_B로 잡힘).
# buffer를 비운 뒤에는 무효화된다.
wr /dev/zero 320 1; cp_mark t2d
trim $((320 * MiB)) $((1 * MiB)); cp_mark t2e
want "T2 buffer 범위는 건너뜀" t2d t2e dsm_ignored_B eq "$((1 * MiB))"
want "T2 buffer 범위 무효화 없음" t2d t2e dsm_inval_B eq 0
flush_buf
trim $((320 * MiB)) $((1 * MiB)); cp_mark t2f
want "T2 buffer 비운 뒤 무효화" t2e t2f dsm_inval_B eq "$((1 * MiB))"
pass "T2 (카운터는 나중에 판정)"

# ---------- T3 ----------
say "== T3 slice 경계 =="
# 128MiB 지점(T1에서 써 둔 곳). 한 LBA 안쪽에서 시작해 1MiB를 discard 한다.
#   범위: LBA s+1 .. s+256 (256개). 완전히 덮이는 slice는 s+4 .. s+255 → 63개.
#   앞 slice의 LBA 3개와 뒤 slice의 LBA 1개, 합쳐 4개(16KB)는 무시되어야 한다.
base=$((128 * MiB))
head -c $((2 * MiB)) /dev/urandom > "$OUT/t3_ref.bin"
wr "$OUT/t3_ref.bin" 128 2
flush_buf
edge_before=$( { rd_slice "$base"; rd_slice $((base + MiB)); } | sha256sum | cut -c1-16)
flush_buf   # 방금 읽은 양쪽 slice가 buffer에 남아 있으면 경계 처리가 틀려도 가려진다
cp_mark t3a
trim $((base + LBA)) $((1 * MiB)); cp_mark t3b
want "T3 63 slice 무효화" t3a t3b dsm_inval_B eq "$((63 * SLICE))"
want "T3 LBA 4개 무시" t3a t3b dsm_ignored_B eq "$((4 * LBA))"
edge_after=$( { rd_slice "$base"; rd_slice $((base + MiB)); } | sha256sum | cut -c1-16)
expect "일부만 덮인 양쪽 slice의 내용" "$edge_after" "$edge_before"
# slice 하나 안에 들어가는 범위(LBA 2개)는 전부 무시
trim $((base + 64 * MiB + LBA)) $((2 * LBA)); cp_mark t3c
want "T3 slice보다 작은 범위 무효화 없음" t3b t3c dsm_inval_B eq 0
want "T3 slice보다 작은 범위 무시" t3b t3c dsm_ignored_B eq "$((2 * LBA))"
pass "T3 (내용 확인 완료, 카운터는 나중에 판정)"

# ---------- T4 ----------
say "== T4 데이터 보존 =="
head -c $((32 * MiB)) /dev/urandom > "$OUT/t4_a.bin"
head -c $((32 * MiB)) /dev/urandom > "$OUT/t4_b.bin"
head -c $((32 * MiB)) /dev/urandom > "$OUT/t4_a2.bin"
wr "$OUT/t4_a.bin" 256 32      # A
wr "$OUT/t4_b.bin" 288 32      # B (A 바로 뒤)
flush_buf; cp_mark t4a
trim $((256 * MiB)) $((32 * MiB)); cp_mark t4b
want "T4 A 무효화" t4a t4b dsm_inval_B eq "$((32 * MiB))"
rd 288 32 | cmp -s - "$OUT/t4_b.bin" || fail "discard 하지 않은 범위 B의 내용이 바뀜"
say "      ok   B 내용 유지"
rd 256 32 > /dev/null || fail "discard 한 범위 A를 읽는 중 오류"
say "      ok   discard 한 범위 읽기 완료(값은 정해져 있지 않음)"
wr "$OUT/t4_a2.bin" 256 32
flush_buf
rd 256 32 | cmp -s - "$OUT/t4_a2.bin" || fail "discard 뒤 다시 쓴 A의 내용이 다름"
say "      ok   A에 다시 쓴 내용 일치"
rd 288 32 | cmp -s - "$OUT/t4_b.bin" || fail "A를 다시 쓴 뒤 B의 내용이 바뀜"
rm -f "$OUT"/t4_*.bin "$OUT/t3_ref.bin"
pass "T4"

# ---------- T5 ----------
say "== T5 쓰기와 discard 동시 실행 =="
# C(512~768MiB): fio가 쓰고 CRC로 검증. D(1024~1280MiB): 그동안 16MiB씩 쓰고 바로 discard.
cp_mark t5a
fio --name=t5 --filename="$DEV" --offset=$((512 * MiB)) --size=$((256 * MiB)) \
    --rw=write --bs=1M --ioengine=libaio --iodepth=16 $FD \
    --verify=crc32c --do_verify=1 --loops="$T5_LOOPS" \
    --output="$OUT/t5_fio.txt" &
fio_pid=$!
churn=0
while kill -0 "$fio_pid" 2>/dev/null; do
  slot=$((1024 + (churn % 16) * 16))
  wr /dev/zero "$slot" 16
  trim $((slot * MiB)) $((16 * MiB))
  churn=$((churn + 1))
done
wait "$fio_pid" || fail "fio 검증 실패: $OUT/t5_fio.txt"
cp_mark t5b
(( churn >= 1 )) || fail "discard가 fio와 겹쳐 실행되지 않음"
want "T5 discard 수" t5a t5b dsm_cmd ge "$churn"
want "T5 DSM 중첩 오류 없음" t5a t5b dsm_nest_err eq 0
want "T5 erase 실패 없음" t5a t5b erase_fail eq 0
pass "T5 (쓰기·discard 반복 ${churn}회, CRC 검증 통과)"

say ""
say "데이터 검사 전체 통과. 결과 폴더: $OUT"
if [[ -n "$UART_LOG" && -r "$UART_LOG" ]]; then
  say "카운터 판정 (UART 로그: $UART_LOG):"
  python3 "$PARSE" --check "$OUT" "$UART_LOG" --skew "${SKEW:-1.0}" | tee -a "$REPORT" || exit 1
else
  say "카운터 판정은 UART 로그를 받은 뒤에 합니다:"
  say "  1) UART를 받은 PC에서 uart.log 를 이 PC로 복사"
  say "  2) python3 $PARSE --check $OUT <uart.log>"
fi
