#!/bin/bash
# Universal ACPI S5 direct power off
# For machines where the kernel's ACPI power-off path is broken
#
# Reads PM1a_CNT_BLK port from FADT and S5 SLP_TYP from DSDT,
# calculates the register value, and writes it directly via /dev/port.
#
# Falls back to /sbin/poweroff.real if ACPI table parsing fails.

sync; sync

python3 -c "
import struct, os, sys

def read_fadt_pm1a_cnt():
    '''Read PM1a_CNT_BLK port address from FADT (offset 0x48, 4 bytes LE)'''
    try:
        with open('/sys/firmware/acpi/tables/FACP', 'rb') as f:
            data = f.read()
        return struct.unpack_from('<I', data, 0x48)[0]
    except Exception as e:
        print(f'Failed to read FADT: {e}', file=sys.stderr)
        return None

def read_dsdt_s5_slp_typ():
    '''Read S5 sleep type value from DSDT _S5_ package'''
    try:
        with open('/sys/firmware/acpi/tables/DSDT', 'rb') as f:
            data = f.read()
        idx = data.find(b'_S5_')
        if idx < 0:
            print('_S5_ not found in DSDT', file=sys.stderr)
            return None
        # Find the Package opcode (0x12) after the _S5_ name
        for i in range(idx, min(idx + 30, len(data))):
            if data[i] == 0x12:
                # SLP_TYP is typically at offset +3 after package opcode
                # Package format: 0x12 <length> <count> <value>
                # The value may be encoded as:
                #   0x0A <byte> for ByteConst
                #   0x00-0xFF directly for small values
                val_offset = i + 3
                if val_offset < len(data):
                    if data[val_offset] == 0x0A:
                        return data[val_offset + 1]
                    else:
                        return data[val_offset]
        print('Could not parse S5 SLP_TYP from DSDT', file=sys.stderr)
        return None
    except Exception as e:
        print(f'Failed to read DSDT: {e}', file=sys.stderr)
        return None

# Read values from ACPI tables
port = read_fadt_pm1a_cnt()
slp_typ = read_dsdt_s5_slp_typ()

if port is None or slp_typ is None:
    print('ACPI table parsing failed, falling back to poweroff.real', file=sys.stderr)
    os.execv('/sbin/poweroff.real', ['/sbin/poweroff.real', '-f'])
    sys.exit(1)

# Calculate register value: (SLP_TYP << 10) | SLP_EN (bit 13)
value = (slp_typ << 10) | (1 << 13)

print(f'ACPI S5 power off: port=0x{port:04X} SLP_TYP={slp_typ} value=0x{value:04X}')

# Write to PM1a_CNT_BLK
try:
    fd = os.open('/dev/port', os.O_WRONLY)
    os.lseek(fd, port, os.SEEK_SET)
    os.write(fd, struct.pack('<H', value))
    os.close(fd)
except Exception as e:
    print(f'Failed to write PM register: {e}', file=sys.stderr)
    os.execv('/sbin/poweroff.real', ['/sbin/poweroff.real', '-f'])
"
