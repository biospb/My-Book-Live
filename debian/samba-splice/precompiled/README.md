# Tested PPC splice v2 library

`samba-splice-1m-v2.so` is the exact tested ELF32 big-endian PowerPC library for the current Debian sid / Samba 4.25 MBL environment. SHA256 is recorded in [SHA256SUMS](SHA256SUMS). It is separate from the kernel package and has not been validated for the original WD userspace or My Book Live Duo.

Source and build flags are in [../samba-splice.c](../samba-splice.c) and [../Makefile](../Makefile). The library exports versioned `sys_recvfile@SMBCONF_0.0.1` and uses the sid 64-bit time/file interfaces. Install it at `/usr/local/lib/samba-splice-1m-v2.so` with root ownership and mode 0755; use the [service wrapper and checked rollback](../README.md), not global /etc/ld.so.preload. The dated installer scripts document the exact NAS setup and backup paths rather than a universal installer.
