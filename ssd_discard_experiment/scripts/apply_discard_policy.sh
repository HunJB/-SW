#!/usr/bin/env bash
# apply_discard_policy.sh — DEV를 포맷하고, 지정한 discard 정책으로 마운트한다.
#
# 사용법:
#   DEV=/dev/vdb MNT=/mnt/ssd-test ./apply_discard_policy.sh <policy> [fstrim_cycle_n]
#
# policy 종류:
#   immediate   — mount -o discard (즉시 discard)
#   none        — nodiscard, fstrim 전혀 안 함
#   fstrim      — nodiscard로 마운트하고, 워크로드 스크립트가 fstrim_trigger.sh를
#                 fstrim_cycle_n번째 cycle마다 호출해서 수동으로 fstrim
#
# 주의: 이 스크립트는 DEV를 포맷합니다 (mkfs.ext4 -F). 실행 전 DEV가
#       실험 전용 장치가 맞는지 반드시 확인하세요.

set -euo pipefail

: "${DEV:?DEV 환경변수를 설정하세요 (예: /dev/vdb)}"
: "${MNT:?MNT 환경변수를 설정하세요 (예: /mnt/ssd-test)}"

POLICY="${1:?policy를 지정하세요: immediate | none | fstrim}"

echo "=============================================="
echo "  대상 장치: $DEV"
echo "  마운트 포인트: $MNT"
echo "  정책: $POLICY"
echo "=============================================="
lsblk -o NAME,MODEL,SERIAL,SIZE,FSTYPE,MOUNTPOINTS "$DEV" || true
read -r -p "위 장치를 포맷하고 진행합니다. 맞습니까? (yes 입력) " confirm
if [ "$confirm" != "yes" ]; then
    echo "취소되었습니다."
    exit 1
fi

if findmnt "$MNT" >/dev/null 2>&1; then
    sudo umount "$MNT"
fi

case "$POLICY" in
    immediate)
        sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$DEV"
        sudo mkdir -p "$MNT"
        sudo mount -o discard,noatime "$DEV" "$MNT"
        ;;
    none)
        sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$DEV"
        sudo mkdir -p "$MNT"
        sudo mount -o nodiscard,noatime "$DEV" "$MNT"
        ;;
    fstrim)
        sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$DEV"
        sudo mkdir -p "$MNT"
        sudo mount -o nodiscard,noatime "$DEV" "$MNT"
        # fstrim은 워크로드 스크립트가 cycle 경계마다 직접
        # `sudo fstrim -v "$MNT"` 를 호출해야 함 (run_experiment.sh 참고)
        ;;
    *)
        echo "[ERROR] 알 수 없는 정책: $POLICY (immediate|none|fstrim 중 선택)" >&2
        exit 1
        ;;
esac

findmnt "$MNT"
echo "[OK] $POLICY 정책으로 마운트 완료"
