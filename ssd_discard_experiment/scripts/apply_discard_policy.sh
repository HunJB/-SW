#!/usr/bin/env bash
# apply_discard_policy.sh — DEV를 ext4로 포맷하고 지정한 discard 정책으로 마운트한다.
#
# 사용법 (root):
#   EXPECTED_SERIAL=<시리얼> MNT=/mnt/ssd-test ./apply_discard_policy.sh <policy>
#
# policy:
#   nodiscard (none)   discard를 보내지 않음
#   immediate          mount -o discard
#   batch (fstrim)     nodiscard로 마운트. TRIM_EVERY cycle마다 fstrim 한 번 (common.sh의 end_cycle)
#   split              nodiscard로 마운트. 같은 시점에 fstrim을 K조각으로 나눠 보냄
#
# 장치 확인: EXPECTED_SERIAL 이 있으면 시리얼로 장치를 찾고 묻지 않는다.
#            없으면 DEV 를 보여 주고 yes 를 입력받는다(FEMU처럼 시리얼이 없는 환경용).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

: "${MNT:?MNT 환경변수를 설정하세요 (예: /mnt/ssd-test)}"
POLICY=$(normalize_policy "${1:?policy를 지정하세요: nodiscard | immediate | batch | split}")

require_root
resolve_dev

echo "=============================================="
echo "  대상 장치: $DEV    마운트 포인트: $MNT    정책: $POLICY"
echo "=============================================="
lsblk -o NAME,MODEL,SERIAL,SIZE,FSTYPE,MOUNTPOINT "$DEV" || true
if [ -z "${EXPECTED_SERIAL:-}" ] && [ "${ASSUME_YES:-0}" != "1" ]; then
    read -r -p "위 장치를 포맷하고 진행합니다. 맞습니까? (yes 입력) " confirm
    [ "$confirm" = "yes" ] || die "취소되었습니다"
fi

# 이 장치가 어디에 마운트되어 있든 모두 내린다
while read -r target; do
    [ -n "$target" ] && umount "$target"
done < <(findmnt -rno TARGET -S "$DEV" || true)
if findmnt "$MNT" >/dev/null 2>&1; then die "$MNT 에 다른 장치가 마운트되어 있습니다"; fi

mkfs.ext4 -F -q -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$DEV"
mkdir -p "$MNT"
if [ "$POLICY" = "immediate" ]; then opts="discard,noatime"; else opts="nodiscard,noatime"; fi
mount -o "$opts" "$DEV" "$MNT"

findmnt "$MNT"
echo "[OK] $POLICY 정책으로 마운트 완료 ($opts)"
