# batocera-tools

Hardware fixes and diagnostic tools for [Batocera Linux](https://batocera.org/)
and Linux in general.

## Fixes

### [Universal ACPI Power-Off Fix](acpi-poweroff-fix/)
For any x86 Linux machine where shutdown completes but the hardware never
cuts power. Automatically reads the correct PM register address and sleep
type from the machine's ACPI tables at runtime — no hardcoded values,
works on any affected hardware.

### [Alienware ASM100 (Alpha / Steam Machine) Shutdown Fix](alienware-asm100/)
The original investigation that led to the universal fix. Full writeup of
the debugging process, every approach tested, SteamOS 2.0 forensic analysis
revealing the root cause (kernel ACPI regression between 4.16 and 6.x),
and Batocera-specific installation instructions.

## Contributing
Found a hardware-specific fix for Batocera? PRs welcome.

## License
MIT
