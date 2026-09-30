# Debian sid (sysvinit) for the 4.19 kernel

Debian unstable from debian-ports (powerpc), built on a PC and copied to the MBL. It uses sysvinit
because systemd >= 258 requires kernel >= 5.4.

## Build (x86 Linux / WSL, as root)

    apt install debootstrap qemu-user-static binfmt-support
    ./build-rootfs.sh            # -> rootfs directory + rootfs-sid-sysv-<date>.tgz

The script does the following:
- runs a minbase debootstrap with the current debian-ports keyring;
- pins `systemd`/`systemd-sysv` out;
- installs sysvinit, ifupdown, dropbear, Samba, NFS, chrony, smartmontools and libubootenv-tool.

## Install

Install from the OpenWrt rescue system:
1. Format the root partition with `mkfs.ext4 -O ^orphan_file` (4.19 cannot mount orphan_file).
2. Unpack the tarball onto it.
3. Run `configure-mbl.sh`. It does the following:
   - writes fstab, the static network setup, `fw_env.config` and the `mbl-boot` rc.local hook;
   - takes the root password and dropbear host keys from the previous system.

## Notes for the 4.19 kernel

- **dropbear instead of openssh-server.** OpenSSH >= 10 needs seccomp; kernel 4.19.325-mbl has it, but dropbear is enough (ed25519 keys) and lighter.
- **chrony runs with `-F 0`.** This avoids depending on seccomp.
- **statx mount-id backport required.** systemd 262 tools (tmpfiles/sysusers, called by dpkg) need `STATX_MNT_ID`. Kernel 4.19.325-mbl has the backport (patch 0011/0015). `opensysusers` replaces `systemd-standalone-sysusers`.
- **fw_printenv/fw_setenv are in `libubootenv-tool`.**

## Services

- `wsdd2.init`: makes the NAS visible in the Windows network neighbourhood (package `wsdd2`, `-4 -i eth0`).
- `mbl-led` + `mbl-led.init`: status on the red front LED. It checks:
  - SMART every 30 min;
  - that /DataVolume is mounted read-write;
  - that SSH answers.

  | LED | Meaning |
  |---|---|
  | off | OK |
  | short flash every 5 s | warning (reallocated/pending sectors) |
  | fast blink | error |
  | on | service stopped |
