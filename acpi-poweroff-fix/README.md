# acpi-poweroff-fix -- Universal Linux ACPI Power-Off Fix

## The Problem

Some x86 Linux machines complete their shutdown sequence but never actually cut
power. The kernel reaches its final ACPI power-off call, the call completes
without error, but the hardware stays on: LEDs lit, fans running, requiring the
power button to be held.

This is typically a regression in the kernel's ACPI subsystem that breaks the
S5 (soft-off) transition for a particular chipset.

## The Fix

Write the S5 sleep type directly to the PM1a control register through
`/dev/port`, bypassing the broken ACPI path.

`acpi_s5_poweroff.sh` reads the values from the machine's own ACPI tables at
runtime, so nothing is hardcoded:

1. **PM1a_CNT_BLK** port address, from `X_PM1a_CNT_BLK` at FADT offset
   `0xAC` when it declares SystemIO, otherwise the legacy field at `0x40`
2. **S5 SLP_TYP**, from the `_S5_` package in the DSDT
3. Register value, computed as `(SLP_TYP << 10) | SLP_EN`

**Not offset `0x48`.** That is PM2_CNT_BLK. An earlier version of this script
read it and got a valid-looking I/O port that simply does nothing when you
write S5 to it. Check your values before trusting them:

```bash
./acpi_s5_poweroff.sh --dry-run
```

This resolves and prints the port, sleep type and register value without
writing anything or changing the power state.

Requirements: Python 3, `/dev/port`, and `/sys/firmware/acpi/tables/`. If
parsing or the write fails, the script falls through to `exec /sbin/halt -dhp`
so the machine ends up exactly where it would have without the fix.

## Where to Hook It -- Read This Before Installing

**Do not replace `/sbin/poweroff`, `/sbin/halt`, `/sbin/reboot` or
`/sbin/shutdown`.** On sysvinit and BusyBox alike these are a single multi-call
binary behind several symlinks, dispatching on `argv[0]`. Overwriting one
overwrites all of them.

This is not hypothetical. The first version of this fix shipped with:

```bash
cp /sbin/poweroff /sbin/poweroff.real
cp acpi_poweroff.sh /sbin/poweroff        # WRONG
```

`cp` writes **through** a symlink rather than replacing it, so on a machine
where `/sbin/poweroff -> /sbin/halt` that second line overwrote the multi-call
binary. `/sbin/reboot` pointed at the same file, so asking the machine to
restart powered it off instead. See `../alienware-asm100/README.md` for the
full write-up.

There is a second reason not to hook the command. Calling the power-off script
in place of `poweroff` runs it **immediately**, before init has stopped any
services or unmounted anything. `sync` flushes the page cache but cannot flush
what a process has not written yet, so anything an application writes on exit
is lost. The register write belongs at the **end** of the shutdown, as the
final action on the power-off path only.

### sysvinit

Point the runlevel-0 `wait` action in `/etc/inittab` at the script, and leave
the runlevel-6 action alone:

```
hlt0:0:wait:/sbin/acpi-s5-poweroff      # was /sbin/halt -dhp
reb0:6:wait:/sbin/reboot                # unchanged
```

Then `telinit q`, because init parsed the table at boot.

Install the script on the **root** filesystem, not on a separate data
partition. Typical inittab runs `umount -a -r -f` before the halt action, so a
script living elsewhere may be unreachable by the time it is needed.

### systemd

**Untested.** A unit ordered late in the shutdown transaction:

```ini
[Unit]
Description=ACPI S5 direct power off
DefaultDependencies=no
After=umount.target
Before=poweroff.target

[Service]
Type=oneshot
ExecStart=/sbin/acpi-s5-poweroff

[Install]
WantedBy=poweroff.target
```

Confirm the ordering on your system before relying on it. The requirements are
that it runs after filesystems are down, and only on the power-off path, never
on reboot.

### Read-only root with an overlay (Batocera and similar)

`/sbin` and `/etc` are rebuilt from the squashfs on every boot, so the hook has
to be reapplied each time from a persistent location. See
`../alienware-asm100/apply-at-boot.sh` for a worked example, including
restoring a multi-call binary that an earlier install clobbered.

## Finding the Values by Hand

The script does this for you. To check its work:

```bash
# PM1a_CNT_BLK: legacy field at FADT offset 0x40, 4 bytes little-endian,
# and the ACPI 2.0 Generic Address Structure at 0xAC. They should agree.
python3 -c "
import struct
d = open('/sys/firmware/acpi/tables/FACP','rb').read()
print('legacy @0x40:', hex(struct.unpack_from('<I', d, 0x40)[0]))
print('X_PM1a  @0xAC:', 'space_id', d[0xAC], hex(struct.unpack_from('<Q', d, 0xB0)[0]))
"

# S5 SLP_TYP from the DSDT
python3 -c "
d = open('/sys/firmware/acpi/tables/DSDT','rb').read()
i = d.find(b'_S5_')
for j in range(i, i+30):
    if d[j] == 0x12:
        v = j + 3
        print('SLP_TYP:', d[v+1] if d[v] == 0x0A else d[v])
        break
"
```

Then `value = (SLP_TYP << 10) | (1 << 13)`.

## Diagnosing

`diagnose.sh` dumps DMI, kernel, ACPI tables, init layout, wakeup sources and
the relevant `dmesg` lines. Run it before and after any change.

`test_shutdown.sh` tries the various power-off methods (`poweroff`, sysrq, EFI,
ACPI, halt, PCI) so you can establish which, if any, work on your board before
reaching for a register write.

## Files

| File | Description |
|------|-------------|
| `acpi_s5_poweroff.sh` | The S5 register write, with runtime ACPI table lookup and a fallback to stock `halt`. |
| `diagnose.sh` | Diagnostic dump. |
| `test_shutdown.sh` | Tries different power-off methods. |

## License

MIT
