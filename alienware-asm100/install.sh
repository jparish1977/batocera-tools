#!/bin/bash
# Installer for the Alienware ASM100 S5 power-off fix on Batocera Linux.
#
# Installs the S5 script and the boot-time applier into /userdata (persistent),
# removes any earlier broken install, and hooks custom.sh so the fix is
# reapplied on every boot.
#
# Usage: bash install.sh

set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PERSIST_DIR="/userdata/system/jap"
CUSTOM_SH="/userdata/system/custom.sh"
APPLY="${PERSIST_DIR}/apply-at-boot.sh"
LOG="/var/log/asm100-apply.log"

[ "$(id -u)" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }

PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)

if [ "$PRODUCT" != "ASM100" ] || [ "$VENDOR" != "Alienware" ]; then
    echo "WARNING: this machine is ${VENDOR:-unknown} ${PRODUCT:-unknown}, not an Alienware ASM100."
    echo "The fix writes directly to a PM control register and edits inittab."
    printf 'Continue anyway? (y/N) '
    read -r confirm
    case "$confirm" in
        y|Y) ;;
        *) echo "Aborted."; exit 1 ;;
    esac
fi

mkdir -p "$PERSIST_DIR"
install -m 0755 "${SRC_DIR}/asm100_s5_poweroff.sh" "${PERSIST_DIR}/asm100_s5_poweroff.sh"
install -m 0755 "${SRC_DIR}/apply-at-boot.sh"      "$APPLY"
echo "Installed scripts into ${PERSIST_DIR}"

# Remove any earlier install. Versions before this one did
#   cp .../asm100_poweroff.sh /sbin/poweroff
# which follows the symlink /sbin/poweroff -> /sbin/halt and overwrites the
# sysvinit multi-call binary, breaking `reboot` as well. apply-at-boot.sh
# restores /sbin/halt; this strips the line that keeps re-breaking it.
if [ -f "$CUSTOM_SH" ]; then
    if grep -qE 'asm100_poweroff\.sh|ASM100 shutdown fix|chmod \+x /sbin/poweroff' "$CUSTOM_SH"; then
        cp "$CUSTOM_SH" "${CUSTOM_SH}.pre-asm100-fix"
        grep -vE 'asm100_poweroff\.sh|ASM100 shutdown fix|chmod \+x /sbin/poweroff' \
            "${CUSTOM_SH}.pre-asm100-fix" > "$CUSTOM_SH"
        echo "Removed the old poweroff-clobbering hook (backup: ${CUSTOM_SH}.pre-asm100-fix)"
    fi
else
    printf '#!/bin/bash\n' > "$CUSTOM_SH"
    chmod +x "$CUSTOM_SH"
fi

if grep -qF "apply-at-boot.sh" "$CUSTOM_SH"; then
    echo "Boot hook already present in ${CUSTOM_SH}"
else
    cat >> "$CUSTOM_SH" << HOOK

# ASM100 S5 power-off: reapply the runlevel-0 halt hook after the overlay reset
bash ${APPLY} >> ${LOG} 2>&1
HOOK
    echo "Added boot hook to ${CUSTOM_SH}"
fi

echo
echo "Applying now..."
bash "$APPLY" | tee -a "$LOG"

echo
echo "Installed. Verify with:"
echo "  ls -l /sbin/halt /sbin/poweroff /sbin/reboot"
echo "  grep ':0:wait:\\|:6:wait:' /etc/inittab"
echo
echo "Then test BOTH actions from the EmulationStation menu:"
echo "  Restart system  -> should reboot"
echo "  Shutdown system -> should power off completely"
