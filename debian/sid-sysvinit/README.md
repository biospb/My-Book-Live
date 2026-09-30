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

## Generic image

    WORK=/root/mbl-generic ./build-rootfs.sh     # no ssh key argument
    WORK=/root/mbl-generic ./make-image.sh       # -> mbl-sid-sysvinit-<date>.tar.xz

`make-image.sh` adds the following to the plain rootfs:
- kernel 4.19.325-cip136-mbl in `/boot` (uImage + apollo3g.dtb, from `kernel/precompiled`) and its modules;
- `mbl-led`, `wsdd2`, `mbl-boot` and `fw_env.config`;
- the Samba config from `samba/smb-sid.conf`.

It removes all personal state: no ssh keys, no host keys (dropbear `-R` creates them on the first connection), an empty machine-id and empty logs.

| Setting | Value |
|---|---|
| hostname | `mybooklive` |
| network | DHCP |
| root password | `debian` (change it) |
| fstab | root `/dev/sda4`, swap `/dev/sda3`, data `/dev/sda5` on `/DataVolume` (`nofail`), as in `uboot/boot_multi` |

To use it:
1. Unpack onto the root partition: `tar -xJpf mbl-sid-sysvinit-<date>.tar.xz -C /mnt/new`.
2. Copy `boot/uImage_*` and `boot/apollo3g.dtb` to wherever u-boot loads them from (`/boot/debian/uImage` on sda1 with `boot_multi`).
3. Run `mkswap` on the swap partition once: the page size is 16K.

## Install on the author's box

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
