# batocera-tools

Hardware-specific fixes and diagnostic tools for [Batocera Linux](https://batocera.org/).

## Fixes

### [Alienware ASM100 (Alpha / Steam Machine) Shutdown Fix](alienware-asm100/)
The Alienware Alpha's ACPI power-off implementation is broken under Linux.
The kernel completes the shutdown sequence but the hardware never cuts power
-- LEDs stay on and the machine requires a hard power-off via the power button.

This fix bypasses the broken ACPI path by writing the S5 sleep type value
directly to the PM1a control register, cleanly powering off the hardware.

## Contributing
Found a hardware-specific fix for Batocera? PRs welcome.

## License
MIT
