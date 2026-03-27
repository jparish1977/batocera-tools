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
