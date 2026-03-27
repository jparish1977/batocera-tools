#!/bin/bash
# Installer for the Alienware ASM100 shutdown fix on Batocera Linux
#
# This script:
# 1. Detects if running on an Alienware ASM100
# 2. Installs the power-off fix script
# 3. Hooks it into custom.sh so it persists across reboots
#
# Usage: bash install.sh
#   or:  curl -sSL <raw-url> | bash

set -e

PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
INSTALL_DIR="/userdata/system/jap"
SCRIPT_NAME="asm100_poweroff.sh"
CUSTOM_SH="/userdata/system/custom.sh"

# Check hardware
if [ "$PRODUCT" != "ASM100" ] || [ "$VENDOR" != "Alienware" ]; then
    echo "WARNING: This machine is $VENDOR $PRODUCT, not Alienware ASM100."
    echo "This fix is hardware-specific. It writes directly to PM registers"
    echo "and may not work (or could cause issues) on other hardware."
    read -p "Continue anyway? (y/N) " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

# Write the power-off script
cat > "$INSTALL_DIR/$SCRIPT_NAME" << 'POWEROFF'
#!/bin/bash
# ASM100 direct PM register power off
# The ACPI power off is broken on this board
# Write S5 sleep type (0x3C00) to PM1a_CNT_BLK (port 0x1804)
sync; sync
python3 -c "
import struct, os
fd = os.open('/dev/port', os.O_WRONLY)
os.lseek(fd, 0x1804, os.SEEK_SET)
os.write(fd, struct.pack('<H', 0x3C00))
os.close(fd)
"
POWEROFF
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
echo "Installed $INSTALL_DIR/$SCRIPT_NAME"

# Add to custom.sh if not already present
HOOK="cp $INSTALL_DIR/$SCRIPT_NAME /sbin/poweroff && chmod +x /sbin/poweroff"
if grep -qF "asm100_poweroff" "$CUSTOM_SH" 2>/dev/null; then
    echo "Hook already present in $CUSTOM_SH, skipping."
else
    # Create custom.sh if it doesn't exist
    if [ ! -f "$CUSTOM_SH" ]; then
        echo "#!/bin/bash" > "$CUSTOM_SH"
        chmod +x "$CUSTOM_SH"
    fi
    cat >> "$CUSTOM_SH" << HOOK_EOF

# ASM100 shutdown fix: replace broken ACPI poweroff with direct PM register write
$HOOK
HOOK_EOF
    echo "Added boot hook to $CUSTOM_SH"
fi

# Apply immediately (replace poweroff for this session)
cp "$INSTALL_DIR/$SCRIPT_NAME" /sbin/poweroff
chmod +x /sbin/poweroff
echo ""
echo "Alienware ASM100 shutdown fix installed successfully."
echo "The fix is active now and will persist across reboots."
echo "Test by shutting down from the EmulationStation menu."
