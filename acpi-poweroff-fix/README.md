# acpi-poweroff-fix — Universal Linux ACPI Power-Off Fix

## The Problem

Some x86 Linux machines complete their shutdown sequence but never actually
cut power. The kernel reaches its final ACPI power-off call, the call
completes without error, but the hardware stays on — LEDs lit, fans running,
requiring a hard power-off via the power button.

This is typically caused by a regression in the kernel's ACPI subsystem that
breaks the S5 (soft-off) transition for certain chipsets.

## The Fix

Bypass the kernel's ACPI power-off path and write the S5 sleep type value
directly to the PM1a control register via `/dev/port`.

The script **automatically reads** the correct values from the machine's
ACPI tables at runtime:

1. **PM1a_CNT_BLK port address** — from the FADT (offset 0x48)
2. **S5 sleep type value** — from the DSDT `_S5_` package
3. **Register value** — calculated as `(SLP_TYP << 10) | SLP_EN`

No hardcoded values. Works on any x86 Linux machine with:
- Python 3
- `/dev/port` (standard on x86)
- `/sys/firmware/acpi/tables/` (standard on UEFI/ACPI systems)

If ACPI table parsing fails, it falls back to `/sbin/poweroff.real`.

## Usage

### Quick Test

```bash
# Back up the real poweroff first
cp /sbin/poweroff /sbin/poweroff.real

# Replace with the fix
cp acpi_poweroff.sh /sbin/poweroff
chmod +x /sbin/poweroff

# Test
shutdown -h now
```

### Permanent Installation on Batocera

Batocera uses a read-only squashfs root, so `/sbin/poweroff` resets each
boot. Add to `/userdata/system/custom.sh`:

```bash
cp /path/to/acpi_poweroff.sh /sbin/poweroff
chmod +x /sbin/poweroff
```

### Permanent Installation on systemd Distros

```bash
cp acpi_poweroff.sh /usr/local/sbin/acpi-poweroff
chmod +x /usr/local/sbin/acpi-poweroff

cat > /etc/systemd/system/acpi-poweroff.service << 'EOF'
[Unit]
Description=ACPI Direct Power Off
DefaultDependencies=no
Before=poweroff.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/acpi-poweroff

[Install]
WantedBy=poweroff.target
EOF

systemctl enable acpi-poweroff
```

## Origin Story

This fix was developed while debugging a years-old shutdown bug on the
Alienware Alpha (ASM100/Steam Machine) running Batocera Linux. The full
investigation is documented in the [alienware-asm100](../alienware-asm100/)
directory, including:

- Detailed ACPI debugging methodology
- Every approach tested and why it failed
- SteamOS 2.0 forensic analysis revealing the root cause (kernel ACPI
  regression between 4.16 and 6.x)
- How systemd's power management stack accidentally avoided the bug

## How It Works

The ACPI specification defines a standard mechanism for entering sleep
states (including S5/soft-off):

1. The OS reads the `PM1a_CNT_BLK` I/O port address from the FADT
2. The OS reads the `SLP_TYP` value for the desired sleep state from the DSDT
3. The OS writes `(SLP_TYP << 10) | SLP_EN` to the PM1a control register
4. The chipset's power management controller sequences the power rails down

This is exactly what the kernel does when you call `poweroff`. On affected
machines, something in the kernel's ACPI layer prevents the write from
reaching the hardware. This script does the write directly through
`/dev/port`, bypassing the kernel's ACPI subsystem entirely.

## Safety

- **Same operation as a normal shutdown** — identical register, identical
  value, just a different code path
- **Equivalent to a soft power button press** — the chipset handles power
  sequencing safely
- **Safer than holding the power button** — which is an unconditional hard
  power-off that risks data corruption
- **Graceful fallback** — if ACPI table parsing fails, falls back to the
  original `poweroff` binary

## Known Working Hardware

| Machine | Board | BIOS | PM1a Port | S5 SLP_TYP | Value |
|---------|-------|------|-----------|------------|-------|
| Alienware ASM100 (Alpha R1) | 0J8H4R | A08 | 0x1804 | 7 | 0x3C00 |

**Please report** if this fix works on your hardware so we can expand
the table.

## Files

| File | Description |
|------|-------------|
| `acpi_poweroff.sh` | The fix — universal, reads ACPI tables at runtime |
| `diagnose.sh` | Diagnostic dump for debugging power-off issues |
| `test_shutdown.sh` | Tests different power-off methods |

## License

MIT
