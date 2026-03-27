#!/bin/bash
# Diagnostic dump for Alienware ASM100 shutdown issue
# Run as root on the batocera-dell machine

LOG=/userdata/asm100-diag.log
echo "=== ASM100 DIAGNOSTIC $(date) ===" > $LOG

echo "=== DMI ===" >> $LOG
cat /sys/class/dmi/id/product_name >> $LOG
cat /sys/class/dmi/id/sys_vendor >> $LOG
cat /sys/class/dmi/id/board_name >> $LOG
cat /sys/class/dmi/id/bios_version >> $LOG

echo "=== Kernel ===" >> $LOG
uname -r >> $LOG
cat /proc/cmdline >> $LOG

echo "=== Reboot config ===" >> $LOG
cat /sys/kernel/reboot/type >> $LOG 2>&1
cat /sys/kernel/reboot/mode >> $LOG 2>&1

echo "=== Power off handler ===" >> $LOG
cat /proc/kallsyms 2>/dev/null | grep pm_power_off >> $LOG

echo "=== ACPI wakeup sources ===" >> $LOG
cat /proc/acpi/wakeup >> $LOG

echo "=== Wake-on-LAN ===" >> $LOG
ethtool eth0 2>/dev/null | grep -i wake >> $LOG

echo "=== USB devices ===" >> $LOG
lsusb >> $LOG 2>&1

echo "=== Loaded modules (nvidia/wmi/acpi) ===" >> $LOG
lsmod | grep -iE 'nvidia|wmi|acpi|alienware' >> $LOG

echo "=== nvidia device users ===" >> $LOG
fuser /dev/nvidia0 >> $LOG 2>&1
lsof /dev/nvidia* >> $LOG 2>&1

echo "=== ACPI errors in dmesg ===" >> $LOG
dmesg | grep -i 'acpi.*error\|acpi.*warn\|acpi.*conflict\|resource conflict' >> $LOG

echo "=== Power/shutdown related dmesg ===" >> $LOG
dmesg | grep -iE 'power|shutdown|halt|reboot|pm_power' >> $LOG

echo "=== Running processes ===" >> $LOG
ps aux >> $LOG

echo "=== Network interfaces ===" >> $LOG
ip link show >> $LOG

echo "=== EFI variables ===" >> $LOG
ls /sys/firmware/efi/efivars/ | head -20 >> $LOG

echo "=== Done ===" >> $LOG
echo "Diagnostic saved to $LOG"
cat $LOG
