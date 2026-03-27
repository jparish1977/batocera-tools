# Alienware ASM100 (Alpha / Steam Machine) — Linux Shutdown Fix

## The Problem

The Alienware Alpha (ASM100) will not fully power off under Linux. The
operating system completes its shutdown sequence — services stop, filesystems
sync, and the kernel reaches its final power-off call — but the hardware never
actually cuts power. The alien head and badge LEDs remain lit, fans may
continue running, and the only way to turn the machine off is to hold the
power button for several seconds (hard power-off).

This is particularly frustrating because the machine originally shipped with
SteamOS (a Debian-based Linux distribution from Valve) and shut down
correctly under that OS. The problem manifests with modern Linux kernels and
distributions including Batocera, Ubuntu, and others.

## Hardware Details

| Field | Value |
|-------|-------|
| Product | Alienware ASM100 (Alpha / Steam Machine) |
| Board | 0J8H4R |
| BIOS | AMI, version A08 (05/31/2019) |
| GPU | NVIDIA GeForce GTX 860M (GM107M) |
| Boot Mode | UEFI |
| Chipset | Intel Haswell |

## Root Cause

The kernel's ACPI power-off path fails to actually cut power on this board.
When Linux calls `poweroff`, the kernel writes the S5 (soft-off) sleep type
value to the PM1a control register via ACPI. On the ASM100, this call
completes without error but the hardware does not respond — the system enters
a zombie state where the CPU has halted but the power supply remains energized.

The ACPI tables (FADT/DSDT) contain multiple resource conflicts visible in
`dmesg`:

```
ACPI Warning: SystemIO range 0x1828-0x182F conflicts with OpRegion 0x1800-0x187F (\PMIO)
ACPI: OSL: Resource conflict; ACPI support missing from driver?
ACPI Warning: SystemIO range 0x1C40-0x1C4F conflicts with OpRegion 0x1C00-0x1FFF (\GPR)
ACPI Warning: SystemIO range 0x1C30-0x1C3F conflicts with OpRegion 0x1C00-0x1C3F (\GPRL)
ACPI Warning: SystemIO range 0x1C00-0x1C2F conflicts with OpRegion 0x1C00-0x1C3F (\GPRL)
```

These conflicts suggest the BIOS's ACPI implementation has bugs in its
resource declarations, which may cause the kernel's ACPI layer to fail
silently when attempting to write to the power management registers.

## The Investigation

The following approaches were tested and **did not work**:

### Kernel Parameters
- **`acpi=force`** — Caused the system to hang on a green screen during
  shutdown, making things worse.
- **`acpi_enforce_resources=lax`** — No effect on the power-off behavior.
- **`reboot=efi`** — Tells the kernel to use EFI runtime services for
  reboot/shutdown instead of ACPI. The parameter was accepted but power-off
  still failed.
- **`acpi_osi="Windows 2009"`** — Changes the OS identity reported to the
  BIOS to match Windows 7 (the era of this hardware). This caused fan
  overdrive and a worse hang state.

### Shutdown Sequence Modifications
- **Unloading NVIDIA modules before shutdown** — The GTX 860M's nvidia
  driver holds ~175 references to the GPU during normal operation. A custom
  shutdown script was written that stops EmulationStation, kills the X server,
  and unloads all nvidia kernel modules (`nvidia_drm`, `nvidia_uvm`,
  `nvidia_modeset`, `nvidia`) in order. Logging confirmed all modules
  unloaded successfully with zero remaining references. **Power-off still
  failed**, proving NVIDIA is not the blocker.
- **Disabling ACPI wakeup sources** — All wakeup-capable devices (RP04,
  PXSX, RP06, EHC1, EHC2, XHC, PEG0) were disabled via `/proc/acpi/wakeup`.
  Wake-on-LAN was also disabled via `ethtool -s eth0 wol d`. No effect.
- **SysRq power-off (`echo o > /proc/sysrq-trigger`)** — The kernel
  acknowledged the request ("SysRq: Power Off") but the hardware did not
  power down, confirming the issue is below the kernel in the
  firmware/hardware interface.

### Key Diagnostic Finding

A shutdown log was added to capture every step of the shutdown process:

```
=== SHUTDOWN START ===
Stopping ES...
ES stopped
Killing X...
X killed
nvidia refs before unload:
nvidia_drm             90112  0
nvidia_uvm           1699840  0
nvidia_modeset       1318912  1 nvidia_drm
nvidia              56725504  2 nvidia_uvm,nvidia_modeset
Unloading nvidia_drm...
Unloading nvidia_uvm...
Unloading nvidia_modeset...
Unloading nvidia...
nvidia refs after unload:
(empty — all unloaded)
Syncing...
Calling poweroff -f
```

The log proves the entire software shutdown sequence completes successfully.
Every service is stopped, every module is unloaded, disks are synced, and
`poweroff -f` is called. The failure is entirely in the firmware's response
to the kernel's ACPI power-off request.

### SteamOS 2.0 Forensics

The Alienware Alpha originally shipped with SteamOS, which shut down
correctly. A SteamOS 2.0 VM was booted and examined to determine what
Valve did differently. The findings:

- **Kernel**: `4.16.0-0.steamos2.1-amd64`
- **Kernel parameters**: `root=UUID=... ro fbcon=vc:2-6` — **no ACPI
  parameters whatsoever**
- **GRUB config**: No ACPI-related options
- **Initramfs**: Standard ACPI modules only (`button.ko`, `fan.ko`,
  `video.ko`, `thermal.ko`) — no DSDT override, no custom ACPI tables
- **Kernel config**: No unusual ACPI/power management options

**The critical difference: `acpid`**

SteamOS ran the `acpid` daemon, which caught power button ACPI events
and routed them through a handler chain:

1. `acpid` catches the power button event
2. `/etc/acpi/powerbtn-acpi-support.sh` runs
3. Script sources `/usr/share/acpi-support/policy-funcs`
4. `policy-funcs` checks for power management daemons (upowerd,
   xfce4-power-manager, systemd-logind, etc.)
5. If systemd-logind is available, shutdown is handled via D-Bus call to
   `org.freedesktop.systemd1.Manager` → `shutdown.target`
6. If no PM daemon is found, falls through to `/sbin/shutdown -h -P now`

The key insight is that SteamOS used **systemd's power management
infrastructure** to handle the shutdown, which includes proper ACPI S5
sequencing through logind. Batocera, using BusyBox/sysvinit with no
systemd and no running `acpid` daemon, calls `/sbin/poweroff` directly,
which hits the kernel's broken ACPI power-off code path.

**Conclusion**: This is a Linux kernel regression in the ACPI power-off
path between kernel 4.16 (works) and 6.4 (broken) affecting the
Alienware ASM100 chipset. SteamOS avoided the issue not through any
special configuration but by using systemd's power management stack,
which handles S5 transitions differently than a direct `poweroff` call.
Batocera's simpler init system exposes the kernel bug.

## The Solution

Bypass the kernel's broken ACPI power-off path entirely by writing the S5
sleep type value directly to the PM1a control register via `/dev/port`.

### How It Works

From the machine's ACPI tables:

1. **FADT (Fixed ACPI Description Table)** — The `PM1a_CNT_BLK` field at
   offset 0x48 contains the I/O port address for the power management
   control register: **`0x1804`**

2. **DSDT (Differentiated System Description Table)** — The `_S5_` object
   contains the sleep type value for the S5 (soft-off) state: **`0x07`**

3. The value to write is constructed as:
   `(SLP_TYP << 10) | SLP_EN` = `(7 << 10) | (1 << 13)` = **`0x3C00`**

4. Writing `0x3C00` to port `0x1804` tells the chipset's power management
   controller to enter the S5 state — immediately cutting power.

This is the exact same operation the kernel is supposed to perform via ACPI.
We're just doing it directly, bypassing whatever is broken in the ACPI layer.

### The Fix (6 lines)

```bash
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
```

### Safety

This approach is safe:

- **It's the same operation as a normal ACPI power-off** — we're writing the
  same value to the same register, just bypassing the broken ACPI abstraction
  layer.
- **It's equivalent to a "soft" power button press** — the chipset's power
  management controller handles the actual power sequencing, ensuring an
  orderly shutdown of voltage rails.
- **Data integrity is preserved** — the script calls `sync` before writing
  the register. In practice, all services and filesystems should already be
  stopped/unmounted by the time this script runs.
- **It's safer than the alternative** — holding the physical power button
  (hard power-off) is more aggressive and risks data loss. This fix
  eliminates the need for that.

## Installation on Batocera

Batocera uses a squashfs root filesystem with a tmpfs overlay, so changes to
`/sbin/poweroff` are lost on every reboot. The fix is applied at boot via
`custom.sh`.

### Step 1: Create the power-off script

Copy `asm100_poweroff.sh` to `/userdata/system/jap/` on the Batocera machine
(or any persistent location under `/userdata/`):

```bash
scp asm100_poweroff.sh root@<batocera-host>:/userdata/system/jap/
ssh root@<batocera-host> "chmod +x /userdata/system/jap/asm100_poweroff.sh"
```

### Step 2: Add to custom.sh

Add the following to `/userdata/system/custom.sh` to replace the broken
`poweroff` binary on every boot:

```bash
# ASM100 shutdown fix: replace broken ACPI poweroff with direct PM register write
cp /userdata/system/jap/asm100_poweroff.sh /sbin/poweroff
chmod +x /sbin/poweroff
```

### Step 3: Reboot and test

Reboot the machine, then shut down via the EmulationStation menu. The system
should power off completely — alien head dark, no LEDs, no fans.

## Adapting for Other Distributions

The core fix (writing to the PM register) works on any Linux distribution.
The installation method varies:

### systemd-based (Ubuntu, Fedora, Arch, etc.)

Create a systemd service that runs at shutdown:

```ini
[Unit]
Description=ASM100 Direct Power Off
DefaultDependencies=no
Before=poweroff.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/asm100_poweroff.sh

[Install]
WantedBy=poweroff.target
```

### Generic (any init system)

Replace or wrap `/sbin/poweroff` with the script, or add it to your init
system's shutdown sequence.

## Adapting for Other Hardware

If you have a different machine with the same symptom (shutdown completes but
power doesn't cut), you can adapt this fix:

1. **Find your PM1a_CNT_BLK port address:**
   ```bash
   xxd /sys/firmware/acpi/tables/FACP | head -12
   # Look at offset 0x48 (bytes 0x48-0x4B), read as little-endian 32-bit
   ```

2. **Find your S5 sleep type value:**
   ```python
   python3 -c "
   data = open('/sys/firmware/acpi/tables/DSDT','rb').read()
   idx = data.find(b'_S5_')
   if idx >= 0:
       for i in range(idx, min(idx+30, len(data))):
           if data[i] == 0x12:  # Package opcode
               # SLP_TYP is usually at offset +4 after the package opcode
               print('S5 SLP_TYP:', data[i+3])
               break
   "
   ```

3. **Calculate the register value:**
   ```
   value = (SLP_TYP << 10) | (1 << 13)
   ```

4. **Write it:**
   ```python
   python3 -c "
   import struct, os
   fd = os.open('/dev/port', os.O_WRONLY)
   os.lseek(fd, YOUR_PORT, os.SEEK_SET)
   os.write(fd, struct.pack('<H', YOUR_VALUE))
   os.close(fd)
   "
   ```

## Files

| File | Description |
|------|-------------|
| `asm100_poweroff.sh` | The fix. Drop-in replacement for `/sbin/poweroff`. |
| `install.sh` | Installer script for Batocera systems. |
| `diagnose.sh` | Diagnostic dump — collects ACPI, GPU, USB, and power info. |
| `test_shutdown.sh` | Tests different power-off methods for debugging. |

## Tested On

- Alienware ASM100 (Alpha R1), BIOS A08
- Batocera Linux 39 (kernel 6.4.16)
- NVIDIA GeForce GTX 860M with proprietary driver

## License

MIT
