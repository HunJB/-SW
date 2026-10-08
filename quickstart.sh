#!/usr/bin/env bash
# quickstart.sh — 저장소 src 로 빌드한 펌웨어를 올린 Cosmos+ 보드를 터미널에서 단계별로 점검한다.
#
# 사용법:
#   sudo ./quickstart.sh                 # 1단계부터 차례로
#   sudo ./quickstart.sh --from 4        # 4단계부터 (장치 확인은 항상 다시 함)
#   sudo EXPECTED_SERIAL=<시리얼> ./quickstart.sh   # 장치를 묻지 않고 시리얼로 지정
#
# 단계
#   1 필요한 프로그램 확인
#   2 PC 시험 (보드를 쓰지 않음)
#   3 실험 장치 찾기와 확인
#   4 펌웨어 확인 (schema=3 계측 펌웨어가 올라가 있는지)
#   5 펌웨어 검증 fw_verify.sh (장치 앞쪽 약 1.6GiB를 덮어씀)
#   6 짧은 실험 한 번 (W1, batch, 4 cycle. 장치를 포맷하고 용량의 약 1.3배를 씀)
#
# 3단계 전까지는 보드에 아무 명령도 보내지 않는다.
# 4단계를 통과하기 전에는 보드에 쓰기·discard·벤더 명령을 보내지 않는다.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FROM=1
MNT="${MNT:-/mnt/ssd-test}"
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:?--from 뒤에 단계 번호}"; shift 2 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done

step() { echo; echo "========== [$1/6] $2 =========="; }
die()  { echo; echo "[중단] $*" >&2; exit 1; }
ask()  { local a; read -r -p "$1 [y/n]: " a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }

[ "$(id -u)" -eq 0 ] || die "root로 실행하세요: sudo ./quickstart.sh"

# ---------- 1 ----------
if [ "$FROM" -le 1 ]; then
    step 1 "필요한 프로그램 확인"
    missing=""
    for c in fio nvme python3 gcc make filefrag blkdiscard fstrim lsblk findmnt blockdev; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
        echo "없는 프로그램:$missing"
        die "다음을 실행한 뒤 다시 시작하세요: sudo apt install -y fio nvme-cli python3 build-essential e2fsprogs util-linux"
    fi
    echo "모두 있음"
fi

# ---------- 2 ----------
if [ "$FROM" -le 2 ]; then
    step 2 "PC 시험 (보드를 쓰지 않음)"
    make -C "$HERE/tests/host" test || die "PC 시험 실패. 받은 코드가 온전한지 확인하세요 (git status)"
    make -C "$HERE/tests/host" clean >/dev/null
fi

# ---------- 3 ----------
step 3 "실험 장치 찾기"
root_src="$(findmnt -no SOURCE / || true)"
echo "NVMe 장치 목록:"
lsblk -dpno NAME,SERIAL,MODEL,SIZE | awk '$1 ~ /nvme/' | sed 's/^/  /'
echo "시스템 디스크: ${root_src:-알 수 없음} 가 속한 장치 (선택할 수 없음)"

if [ -z "${EXPECTED_SERIAL:-}" ]; then
    echo
    echo "위 목록에서 OpenSSD의 시리얼(두 번째 칸)을 그대로 입력하세요."
    read -r -p "OpenSSD 시리얼: " EXPECTED_SERIAL
fi
[ -n "$EXPECTED_SERIAL" ] || die "시리얼이 비어 있습니다"
DEV="$(lsblk -dpno NAME,SERIAL | awk -v s="$EXPECTED_SERIAL" '$2 == s {print $1}')"
[ -n "$DEV" ] || die "시리얼 $EXPECTED_SERIAL 인 장치가 없습니다"
[ "$(echo "$DEV" | wc -l)" -eq 1 ] || die "시리얼 $EXPECTED_SERIAL 인 장치가 여러 개입니다"
case "$root_src" in
    "$DEV"*) die "$DEV 는 시스템 디스크입니다. OpenSSD의 시리얼을 다시 확인하세요" ;;
esac
if lsblk -nro MOUNTPOINT "$DEV" | grep -q .; then
    lsblk -o NAME,MOUNTPOINT "$DEV"
    die "$DEV 가 마운트되어 있습니다. umount 후 다시 실행하세요"
fi
size=$(blockdev --getsize64 "$DEV")
echo "선택: $DEV  시리얼 $EXPECTED_SERIAL  용량 $((size / 1024 / 1024)) MiB"
export DEV EXPECTED_SERIAL MNT

# ---------- 4 ----------
if [ "$FROM" -le 4 ]; then
    step 4 "펌웨어 확인"
    # 여기서는 표준 Identify 와 커널 정보만 읽는다. 원본 펌웨어에도 안전하다.
    oncs=$(nvme id-ctrl "$DEV" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["oncs"])')
    disc_max=$(lsblk -dbno DISC-MAX "$DEV" | tr -d ' ')
    echo "ONCS=$oncs (4의 자리 비트가 Dataset Management 지원), DISC-MAX=$disc_max"
    if ! (( oncs & 0x4 )) || [ "$disc_max" = "0" ]; then
        die "이 보드는 discard 지원을 표시하지 않습니다. 저장소의 src 로 빌드한 펌웨어가 아닙니다.
       이 상태에서는 5·6단계를 실행하면 안 됩니다. 펌웨어를 다시 올린 뒤 실행하세요."
    fi
    echo "discard 지원 표시 확인"
    echo
    echo "UART 창의 부팅 줄이 'EXPSTAT,tag=BOOT,schema=3,snapshot_opc=0xC2,...' 로 시작해야"
    echo "호스트가 카운터를 읽을 수 있는 펌웨어입니다. schema=2 이하는 이전 버전이라 5·6단계에서 보드가 멈춥니다."
    ask "UART에서 schema=3 을 확인했습니까?" || die "schema=3 펌웨어가 아닙니다. 저장소의 최신 src 로 다시 빌드해 올리세요"
    export ASSUME_SCHEMA3=1
fi

# ---------- 5 ----------
if [ "$FROM" -le 5 ]; then
    step 5 "펌웨어 검증 (fw_verify.sh)"
    echo "$DEV 의 앞쪽 약 1.6GiB를 덮어씁니다."
    ask "진행할까요?" || die "사용자가 중단"
    start=$(date +%s)
    "$HERE/tools/fw_verify.sh" || {
        dmesg | tail -n 40 > "$HOME/quickstart_dmesg_$(date +%H%M%S).txt" 2>/dev/null || true
        die "검증 실패. 위 출력과 UART 마지막 줄, $HOME/quickstart_dmesg_*.txt 를 보내 주세요"
    }
    echo "검증 소요: $(( $(date +%s) - start ))초"
fi

# ---------- 6 ----------
step 6 "짧은 실험 한 번 (W1, batch)"
echo "$DEV 를 ext4로 포맷하고, 85%까지 채운 뒤 4 cycle을 돌립니다."
echo "쓰는 양은 약 $(( size * 125 / 100 / 1024 / 1024 / 1024 )) GiB 입니다. 시간은 보드의 쓰기 속도에 달려 있습니다."
echo "5단계에서 쓴 데이터가 남아 있으므로, 본 측정과 달리 초기 상태가 깨끗하지 않습니다(동작 확인용)."
if ask "지금 실행할까요?"; then
    start=$(date +%s)
    EXPSTAT=1 NUM_CYCLES=4 REST_SEC=5 \
        "$HERE/ssd_discard_experiment/scripts/run_experiment.sh" w1 batch 2 0 \
        || die "실험 실행 실패. 위 출력을 보내 주세요"
    echo
    echo "실험 소요: $(( $(date +%s) - start ))초"
    last=$(ls -dt "$HERE"/ssd_discard_experiment/runs/w1_batch_rep0_* | head -1)
    echo "결과 폴더: $last"
    echo "summary.json 의 verdict 가 valid 이고 dsm_invalid_bytes 가 0보다 크면 정상입니다."
    echo "(4 cycle은 짧아서 GC가 아직 시작되지 않았을 수 있습니다. gc_copy_bytes 0은 이 단계에선 문제가 아닙니다.)"
else
    echo "건너뜀. 나중에: sudo ./quickstart.sh --from 6"
fi

echo
echo "여기까지 통과했으면 본 측정으로 넘어갑니다:"
echo "  cd $HERE/ssd_discard_experiment/scripts"
echo "  export EXPECTED_SERIAL=$EXPECTED_SERIAL MNT=$MNT EXPSTAT=1"
echo "  sudo -E ./run_all.sh poc"
