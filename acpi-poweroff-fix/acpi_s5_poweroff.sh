#!/bin/bash
# Direct ACPI S5 power-off.
#
# For boards where the kernel's ACPI power-off path completes without error
# but the hardware never actually cuts power.
#
# THIS IS NOT A REPLACEMENT FOR poweroff/halt/reboot.
#
# It is invoked by init as the FINAL action of runlevel 0, after services are
# stopped, swap is off and filesystems are unmounted or remounted read-only.
# See install.sh. Replacing /sbin/poweroff with this script is wrong twice
# over: on this hardware /sbin/poweroff is a symlink to the sysvinit
# multi-call binary /sbin/halt, so writing over it also breaks /sbin/reboot,
# and calling it directly cuts power before anything has been shut down.
#
# Reads PM1a_CNT_BLK from the FADT and the S5 sleep type from the DSDT at
# runtime, so there is nothing hardcoded per machine.
#
# If anything fails, falls through to the stock `halt -dhp`, which is exactly
# what this entry ran before. A failure degrades to the original behaviour
# rather than leaving init with nothing to do.

HALT_REAL="${HALT_REAL:-/sbin/halt}"

# --dry-run resolves and prints the ACPI values without writing the register
# or touching the power state. Use it to verify a new machine before trusting
# the hook: getting the FADT offset wrong yields a plausible-looking port that
# simply does nothing.
S5_DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && S5_DRY_RUN=1
export S5_DRY_RUN

if [ "$S5_DRY_RUN" = "0" ]; then
    sync
    sync
fi

python3 - <<'PY'
import os
import struct
import sys


def pm1a_cnt_blk():
    """PM1a_CNT_BLK I/O port from the FADT.

    Offset 0x40, 4 bytes little-endian. NOT 0x48, which is PM2_CNT_BLK: on
    an Intel PCH with ACPI base 0x1800 that is 0x1850 rather than 0x1804,
    and writing S5 there does nothing.

    ACPI 2.0+ also carries X_PM1a_CNT_BLK, a 12-byte Generic Address
    Structure at 0xAC. Prefer it when it declares SystemIO, since the legacy
    32-bit field is deprecated. Count carefully: X_FIRMWARE_CTRL is at 0x84
    and X_DSDT at 0x8C, so the extended PM blocks start at 0x94 and
    X_PM1a_CNT_BLK is the third of them. 0xB0 lands mid-structure and yields
    garbage.
    """
    with open('/sys/firmware/acpi/tables/FACP', 'rb') as f:
        data = f.read()

    # X_PM1a_CNT_BLK GAS: space_id(1) bit_width(1) bit_offset(1)
    #                     access_size(1) address(8)
    if len(data) >= 0xAC + 12:
        space_id = data[0xAC]
        address = struct.unpack_from('<Q', data, 0xAC + 4)[0]
        if space_id == 1 and address:          # 1 = SystemIO
            return address

    port = struct.unpack_from('<I', data, 0x40)[0]
    if not port:
        raise ValueError('FADT declares no PM1a_CNT_BLK')
    return port


def s5_slp_typ():
    """SLP_TYP for S5, from the _S5_ package in the DSDT."""
    with open('/sys/firmware/acpi/tables/DSDT', 'rb') as f:
        data = f.read()
    idx = data.find(b'_S5_')
    if idx < 0:
        raise ValueError('_S5_ not found in DSDT')
    # PackageOp (0x12) follows the name, then PkgLength and NumElements.
    for i in range(idx, min(idx + 30, len(data))):
        if data[i] == 0x12:
            val = i + 3
            if val >= len(data):
                break
            # ByteConst (0x0A) prefixes a literal byte; small ints are inline.
            return data[val + 1] if data[val] == 0x0A else data[val]
    raise ValueError('no PackageOp found after _S5_')


port = pm1a_cnt_blk()
slp_typ = s5_slp_typ()
value = (slp_typ << 10) | (1 << 13)   # SLP_TYP | SLP_EN

sys.stderr.write('ACPI S5: port=0x%04X SLP_TYP=%d value=0x%04X\n'
                 % (port, slp_typ, value))

if os.environ.get('S5_DRY_RUN') == '1':
    sys.stderr.write('dry run: nothing written\n')
    raise SystemExit(0)

fd = os.open('/dev/port', os.O_WRONLY)
os.lseek(fd, port, os.SEEK_SET)
os.write(fd, struct.pack('<H', value))
os.close(fd)
PY

[ "$S5_DRY_RUN" = "1" ] && exit 0

# Only reached if the write above did not cut power.
echo "ACPI S5 write did not power off, falling back to ${HALT_REAL} -dhp" >&2
exec "${HALT_REAL}" -dhp
