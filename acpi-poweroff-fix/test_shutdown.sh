#!/bin/bash
# Test different power off methods for Alienware ASM100
# Run as root on the batocera-dell machine
# Usage: ./test_shutdown.sh [method]
#   methods: poweroff, sysrq, efi, acpi, halt

LOG=/userdata/shutdown.log
METHOD=${1:-poweroff}

echo "=== SHUTDOWN TEST: $METHOD @ $(date) ===" > $LOG

# Step 1: Stop EmulationStation
echo "Stopping ES..." >> $LOG
/etc/init.d/S31emulationstation stop >> $LOG 2>&1
echo "ES stopped" >> $LOG

# Step 2: Kill X
echo "Killing X..." >> $LOG
killall X 2>/dev/null
killall xinit 2>/dev/null
killall startx 2>/dev/null
sleep 2
killall -9 X 2>/dev/null
killall -9 xinit 2>/dev/null
sleep 1
echo "X killed" >> $LOG

# Step 3: Unload nvidia
echo "Unloading nvidia..." >> $LOG
rmmod nvidia_drm 2>/dev/null
rmmod nvidia_uvm 2>/dev/null
rmmod nvidia_modeset 2>/dev/null
rmmod nvidia 2>/dev/null
sleep 1
echo "nvidia refs after:" >> $LOG
lsmod | grep nvidia >> $LOG 2>&1

# Step 4: Disable wakeup sources
echo "Disabling wakeup sources..." >> $LOG
for src in RP04 PXSX RP06 EHC1 EHC2 XHC PEG0; do
    state=$(grep "^$src" /proc/acpi/wakeup | grep -c enabled)
    if [ "$state" -gt 0 ]; then
        echo "$src" > /proc/acpi/wakeup
        echo "  Disabled $src" >> $LOG
    fi
done
ethtool -s eth0 wol d 2>/dev/null
echo "Wakeup sources disabled" >> $LOG

# Step 5: Sync
echo "Syncing..." >> $LOG
sync
sync

# Step 6: Power off using selected method
echo "Power off method: $METHOD" >> $LOG
sync

case "$METHOD" in
    poweroff)
        echo "Using /sbin/poweroff -f" >> $LOG
        /sbin/poweroff -f
        ;;
    sysrq)
        echo "Using sysrq power off" >> $LOG
        echo o > /proc/sysrq-trigger
        ;;
    efi)
        echo "Using EFI reset to shutdown" >> $LOG
        echo 1 > /sys/kernel/reboot/mode 2>/dev/null
        echo efi > /sys/kernel/reboot/type 2>/dev/null
        /sbin/poweroff -f
        ;;
    acpi)
        echo "Using direct ACPI power off" >> $LOG
        echo acpi > /sys/kernel/reboot/type 2>/dev/null
        /sbin/poweroff -f
        ;;
    halt)
        echo "Using halt" >> $LOG
        /sbin/halt -f -p
        ;;
    pci)
        echo "Using PCI reboot type" >> $LOG
        echo pci > /sys/kernel/reboot/type 2>/dev/null
        /sbin/poweroff -f
        ;;
    *)
        echo "Unknown method: $METHOD" >> $LOG
        echo "Usage: $0 [poweroff|sysrq|efi|acpi|halt|pci]"
        exit 1
        ;;
esac
