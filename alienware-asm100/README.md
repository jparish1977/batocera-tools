# Alienware ASM100 (Alpha / Steam Machine) -- Linux Shutdown Fix

## The Problem

The Alienware Alpha (ASM100) will not fully power off under Linux. The
operating system completes its shutdown sequence -- services stop, filesystems
sync, and the kernel reaches its final power-off call -- but the hardware never
actually cuts power. The alien head and badge LEDs remain lit, fans may
continue running, and the only way to turn the machine off is to hold the
power button for several seconds.

This is particularly frustrating because the machine originally shipped with
SteamOS and shut down correctly under that OS. The problem appears with modern
Linux kernels including Batocera, Ubuntu and others.

## Hardware and Software

Measured on the machine, 2026-09-01. Do not trust the earlier revision of this
file, which got both the Batocera version and the init system wrong.

| Field | Value |
|-------|-------|
| Product | Alienware ASM100 (Alpha / Steam Machine) |
| Board | 0J8H4R |
| BIOS | AMI, version A08 (05/31/2019) |
| GPU | NVIDIA GeForce GTX 860M (GM107M) |
| Boot Mode | UEFI |
| Chipset | Intel Haswell |
| Distro | Batocera **38** (2023/10/14) |
| Kernel | 6.4.16 |
| Init | **sysvinit** (`/sbin/init`, `/sbin/shutdown`, `/etc/inittab`) |
| BusyBox | **not present** -- there is no `/bin/busybox` on this image |
| Root FS | squashfs lower + tmpfs overlay; `/userdata` is ext4 on `/dev/sda2` |

## Root Cause

The kernel's ACPI power-off path fails to cut power on this board. When Linux
performs a soft-off it writes the S5 sleep type to the PM1a control register
via ACPI. On the ASM100 that call completes without error but the hardware
does not respond: the CPU halts and the power supply stays energised.

The ACPI tables contain multiple resource conflicts visible in `dmesg`:

```
ACPI Warning: SystemIO range 0x1828-0x182F conflicts with OpRegion 0x1800-0x187F (\PMIO)
ACPI: OSL: Resource conflict; ACPI support missing from driver?
ACPI Warning: SystemIO range 0x1C40-0x1C4F conflicts with OpRegion 0x1C00-0x1FFF (\GPR)
ACPI Warning: SystemIO range 0x1C30-0x1C3F conflicts with OpRegion 0x1C00-0x1C3F (\GPRL)
ACPI Warning: SystemIO range 0x1C00-0x1C2F conflicts with OpRegion 0x1C00-0x1C3F (\GPRL)
```

## The Investigation

These approaches were tested and **did not work**:

### Kernel Parameters
- **`acpi=force`** -- hung the system on a green screen during shutdown.
- **`acpi_enforce_resources=lax`** -- no effect.
- **`reboot=efi`** -- accepted, power-off still failed.
- **`acpi_osi="Windows 2009"`** -- fan overdrive and a worse hang.

### Shutdown Sequence Modifications
- **Unloading NVIDIA modules before shutdown.** The GTX 860M's driver holds
  ~175 references during normal operation. A script was written to stop
  EmulationStation, kill X, and unload `nvidia_drm`, `nvidia_uvm`,
  `nvidia_modeset` and `nvidia` in order. Logging confirmed all modules
  unloaded with zero remaining references. **Power-off still failed**, so
  NVIDIA is not the blocker.
- **Disabling ACPI wakeup sources** (RP04, PXSX, RP06, EHC1, EHC2, XHC, PEG0)
  and Wake-on-LAN. No effect.
- **SysRq power-off** (`echo o > /proc/sysrq-trigger`). The kernel logged
  "SysRq: Power Off" and the hardware stayed on, placing the failure below the
  kernel, in the firmware interface.

### SteamOS 2.0 Forensics

A SteamOS 2.0 VM was booted to see what Valve did differently:

- **Kernel** `4.16.0-0.steamos2.1-amd64`
- **Kernel parameters** `root=UUID=... ro fbcon=vc:2-6`, no ACPI parameters
- **GRUB** no ACPI options
- **Initramfs** standard ACPI modules only, no DSDT override
- **Kernel config** nothing unusual in ACPI or power management

The visible difference was that SteamOS ran `acpid` and routed power button
events through `acpi-support` into systemd-logind.

That remains a plausible lead rather than a proven cause. It is a difference in
userspace policy, and the failure demonstrated above is below the kernel, so it
does not by itself explain anything. What is established is that kernel 4.16
powered this board off and 6.4.16 does not.

**One claim in the earlier version of this file was simply wrong.** It said
Batocera "calls `/sbin/poweroff` directly, which hits the kernel's broken ACPI
power-off code path", contrasted against systemd. Batocera on this machine does
nothing of the sort. See the next section.

## How Shutdown Actually Works on This Machine

This matters, because getting it wrong is what produced the reboot bug below.

EmulationStation issues `shutdown -h now` and `shutdown -r now` (both strings
are present in the `emulationstation` binary; `batocera-es-swissknife` and
`batocera-shutdown` use the same). That is sysvinit's `shutdown`, so the machine
enters a runlevel change and `/etc/inittab` drives the rest:

```
shd0:06:wait:/etc/init.d/rcK        # both halt (0) and reboot (6)
shd1:06:wait:/sbin/swapoff -a
shd2:06:wait:/bin/umount -a -r -f
hlt0:0:wait:/sbin/halt -dhp         # runlevel 0 only
reb0:6:wait:/sbin/reboot            # runlevel 6 only
```

Services are stopped, swap is off, and filesystems are unmounted or remounted
read-only **before** the final action runs. There is already a correct, ordered
shutdown here with a clean split between halt and reboot. The fix hooks the last
line of the halt branch and nothing else.

Two consequences worth stating plainly:

- Anything that runs at `hlt0` runs after `/userdata` may have been unmounted.
  The S5 script therefore lives on the root overlay, at
  `/sbin/asm100-s5-poweroff`, not under `/userdata`.
- `/sbin/halt` is the sysvinit **multi-call binary**. It branches on `argv[0]`,
  and both `/sbin/poweroff` and `/sbin/reboot` are symlinks to it:

  ```
  lrwxrwxrwx /sbin/poweroff -> /sbin/halt
  lrwxrwxrwx /sbin/reboot   -> /sbin/halt
  -rwxr-xr-x /sbin/halt      (22848 bytes, stock)
  ```

## The Solution

Bypass the broken ACPI path by writing the S5 sleep type directly to the PM1a
control register through `/dev/port`, as the **final action of runlevel 0**.

### Deriving the values

1. **PM1a_CNT_BLK** from the FADT at offset **`0x40`**: **`0x1804`** on this
   board. ACPI 2.0+ also carries `X_PM1a_CNT_BLK` as a Generic Address
   Structure at **`0xAC`**, which agrees: SystemIO, 16 bits, `0x1804`.
2. **S5 SLP_TYP** from the `_S5_` package in the DSDT: **`0x07`**.
3. Register value: `(SLP_TYP << 10) | SLP_EN` = `(7 << 10) | (1 << 13)` =
   **`0x3C00`**.

**Offset `0x48` is PM2_CNT_BLK, not PM1a_CNT_BLK.** An earlier version of the
script read `0x48` and got `0x1850`, which is a real register on a real port
and looks entirely plausible. Writing the S5 value there does nothing. Measured
on this board:

```
legacy PM1a_CNT_BLK @0x40 = 0x1804    X_PM1a_CNT_BLK @0xAC = 0x1804
legacy PM2_CNT_BLK  @0x48 = 0x1850    X_PM2_CNT_BLK  @0xC4 = 0x1850
                                      X_PM_TMR_BLK   @0xD0 = 0x1808
```

That matches the Intel PCH layout exactly: ACPI base `0x1800`, PM1a_CNT at
base+0x04, PM_TMR at base+0x08, PM2_CNT at base+0x50.

Verify on any new machine before trusting it, without powering anything off:

```bash
/sbin/asm100-s5-poweroff --dry-run
```

`asm100_s5_poweroff.sh` reads both values from
`/sys/firmware/acpi/tables/` at runtime rather than hardcoding them, so it is
not tied to this board. If parsing or the write fails it falls through to
`exec /sbin/halt -dhp`, which is exactly what that inittab entry ran before, so
a failure degrades to stock behaviour instead of leaving init with nothing to do.

### Safety

- It is the same operation the kernel is supposed to perform, at the same point
  in the shutdown, just without the broken ACPI abstraction in the way.
- The chipset's power management controller still sequences the rails, so this
  is equivalent to a soft power button press and gentler than holding the
  button.
- By the time it runs, `rcK` has stopped every service, EmulationStation has
  exited and written its gamelists, and `umount -a -r -f` has unmounted or
  remounted read-only. Nothing is being written.

## What Went Wrong the First Time

The original installer did this:

```bash
cp /userdata/system/jap/asm100_poweroff.sh /sbin/poweroff     # WRONG
```

`cp` writes **through** a symlink rather than replacing it. Since
`/sbin/poweroff` is a symlink to `/sbin/halt`, that command overwrote the
sysvinit multi-call binary itself. And because `/sbin/reboot` is a symlink to
the same file, **`reboot` began executing the power-off script**: asking the
machine to restart powered it off instead.

Two things about that bug are worth keeping:

- It still cut power at the right moment. `hlt0` and `reb0` both run after the
  full shutdown sequence, so no data was lost through the EmulationStation
  menu. The shutdown half worked by accident, correctly.
- It was **not** harmless everywhere. Typing `poweroff`, `halt` or `reboot` at a
  shell, or running `batocera-es-swissknife --reboot`, does not go through a
  runlevel change. Stock sysvinit would have invoked `shutdown` in that case;
  the replacement cut power immediately with only `sync; sync` for protection,
  losing anything EmulationStation or RetroArch had not yet written.

The current fix touches no stock binary. Use `install` or `rm` before writing,
never `cp` onto a path that might be a symlink.

## Installation

```bash
scp -r alienware-asm100 root@<batocera-host>:/tmp/
ssh root@<batocera-host> "bash /tmp/alienware-asm100/install.sh"
```

The installer:

1. Copies `asm100_s5_poweroff.sh` and `apply-at-boot.sh` into
   `/userdata/system/jap/` (persistent).
2. Strips any earlier `cp ... /sbin/poweroff` hook from
   `/userdata/system/custom.sh`, keeping a backup.
3. Adds a hook calling `apply-at-boot.sh`, logging to
   `/var/log/asm100-apply.log`.
4. Runs it immediately.

`apply-at-boot.sh` is idempotent and runs on every boot. It restores a
clobbered `/sbin/halt` from the squashfs lower directory, installs
`/sbin/asm100-s5-poweroff`, repoints the runlevel-0 action at it, and signals
pid 1 so sysvinit rereads a table it parsed at boot. Batocera 38 has no
`telinit`, so the signal is sent with `kill -HUP 1`; both sysvinit and BusyBox
init reread inittab on SIGHUP.

The reload is verifiable rather than assumed. sysvinit logs
`init: No inittab.d directory found` to `/var/log/messages` each time it parses
the table, so that line appearing at the applier's timestamp is the evidence
the hook is live.

### "Changes to /sbin are lost on every reboot" is not quite true here

The root overlay is tmpfs, but if `batocera-save-overlay` has ever been run,
`/boot/boot/overlay` holds a saved upper layer that is restored at boot. On this
machine that image was saved 2026-08-11 with the clobbered 398 byte `/sbin/halt`
inside it:

```
# mount -o loop,ro /boot/boot/overlay /tmp/ovchk
-rwxr-xr-x 1 root root 398 Aug 11 09:29 /tmp/ovchk/sbin/halt
```

So the broken binary returned on every boot from a second source, with an August
mtime, independently of the `cp` in `custom.sh`. Removing that line alone would
not have fixed it. `apply-at-boot.sh` restores from the squashfs lower directory
precisely because the overlay cannot be assumed clean.

The remaining gap is the few seconds between init parsing inittab at boot and
`custom.sh` running. To close it, remount `/boot` read-write and re-run
`batocera-save-overlay` with the fix in place, so the saved image carries the
stock `halt`, the S5 script and the patched inittab. Then init reads the correct
table directly at boot and the SIGHUP becomes a backstop.

Note that `/` is an overlay mount and already read-write, so nothing else in
this fix requires remounting anything. `/boot` is vfat mounted `ro` and is the
only part that does.

### Verifying

```bash
ls -l /sbin/halt /sbin/poweroff /sbin/reboot
grep ':0:wait:\|:6:wait:' /etc/inittab
```

`/sbin/halt` should be the stock 22848 byte binary, both symlinks intact, the
runlevel-0 line pointing at `/sbin/asm100-s5-poweroff`, and the runlevel-6 line
still `/sbin/reboot`.

Then test **both** actions from the EmulationStation menu. Restart must reboot;
shutdown must power the machine off completely.

## Adapting for Other Distributions

The register write is portable. The hook is not.

### sysvinit

As above: repoint the runlevel-0 `wait` action in `/etc/inittab`, then
`telinit q`.

### systemd

**Untested here.** A unit ordered late in the shutdown transaction:

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

Verify the ordering on your system before relying on it. The requirement is
that it runs after filesystems are down and only on the power-off path, never
on reboot.

### Do not

Replace `/sbin/poweroff`, `/sbin/halt`, `/sbin/reboot` or `/sbin/shutdown`. On
sysvinit and BusyBox alike these are one multi-call binary behind several
symlinks, and overwriting one breaks the others.

## Files

| File | Description |
|------|-------------|
| `asm100_s5_poweroff.sh` | The S5 register write, with runtime ACPI table lookup and a fallback to stock `halt`. |
| `apply-at-boot.sh` | Idempotent applier. Restores `/sbin/halt`, installs the script, patches inittab, reloads init. |
| `install.sh` | One-time installer. Cleans up old installs and hooks `custom.sh`. |
| `diagnose.sh` | Diagnostic dump: ACPI, init layout, GPU, USB, power. |
| `test_shutdown.sh` | Tries different power-off methods for debugging. |

## Tested On

- Alienware ASM100 (Alpha R1), BIOS A08
- Batocera 38 (2023/10/14), kernel 6.4.16, sysvinit
- NVIDIA GeForce GTX 860M with the proprietary driver

## License

MIT
