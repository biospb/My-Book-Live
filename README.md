# My Book Live: Debian sid and CIP kernel

This fork of [ewaldc/My-Book-Live](https://github.com/ewaldc/My-Book-Live) provides Debian sid images, a custom CIP SLTS PowerPC kernel and multiboot tools for the Western Digital My Book Live (MBL). The setup has been tested on a single-disk 3 TB MBL; My Book Live Duo has not been validated here.

## What is new?

Changes made in this fork (September–October 2026):

- **CIP kernel and precompiled package:** rebased the MBL patch set onto **4.19.325-cip136 (CIP SLTS)**, with audited driver fixes, build configurations and matching modules. The current package is **4.19.325-cip136-st20-mbl-p22-wd-perf**.
- **Kernel fixes and compatibility:** fixed EMAC use-after-free, TSO and SATA error handling; added SECCOMP, socket diagnostics, GPIO LEDs, crypto4xx TRNG and the statx mount-id backport required by current sid tools.
- **GRO and SATA DMA patches:** **0019** enables EMAC GRO; **0020** uses 8K DMA LLI blocks; **0021** terminates the SATA DMA channel on hard reset so a DMA timeout cannot wedge subsequent commands.
- **Bounded pagecopy and Samba splice:** **0022** reuses the existing bounded PPC copy loop for suitable page-to-kernel copies. The tested splice v2 shim uses a 1 MiB pipe, preserves request framing on errors and is loaded through the smbd SysV start path. The new kernel retains perf and removes the temporary copy-alignment counters.
- **Hang recovery:** hung-task and soft-lockup panic settings trigger a reboot and allow multiboot fallback to recover from a stuck boot.
- **Debian sid with sysvinit:** added powerpc rootfs and generic image builders, `opensysusers`, wsdd2 and `C.UTF-8`. The current generic image includes the patch-21 CIP kernel, matching modules and MBL services, without personal host settings or SSH keys.
- **Multiboot and rescue:** added `mbl-boot`, SSH boot confirmation, automatic fallback between Debian and OpenWrt rescue, a test-kernel slot and a Python boot-script image builder.
- **Samba and validation:** added the Samba 4.25 configuration, a fix for the 32-bit `smbstatus` crash, SMB/disk benchmarks, GRO profiling and MAL interrupt-coalescing measurements.

## Latest validated kernel support

**4.19.325-cip136-st20-mbl-p22-wd-perf**, based on the [CIP](https://wiki.linuxfoundation.org/civilinfrastructureplatform/start) SLTS kernel, is the current tested package for Debian sid in this fork.

- 16K pages, EMAC GRO, SATA DMA fixes 0020/0021 and bounded pagecopy patch 0022.
- Hung-task/soft-lockup recovery with panic and reboot settings.
- PERF_EVENTS enabled; the temporary mbl_copy_diag code and proc counters are absent.
- SECCOMP, sock_diag (`ss`), `/proc/config.gz`, GPIO LEDs, POSIX ACLs, crypto4xx TRNG and statx mount-id support.
- Tested with SMB transfers and local copy/hash checks on the single-disk MBL.

Package: [`linux-4.19.325-cip136-st20-mbl-p22-wd-perf.tgz`](kernel/precompiled/linux-4.19.325-cip136-st20-mbl-p22-wd-perf.tgz), containing the exact tested uImage, board device tree, config, System.map and matching modules. [Checksums](kernel/precompiled/SHA256SUMS-p22-perf) and a [separate matching debug vmlinux](kernel/precompiled/vmlinux-4.19.325-cip136-st20-mbl-p22-wd-perf.xz) are provided for perf. The [Samba shim](debian/samba-splice/README.md) is installed separately; the kernel archive does not enable it by itself. See the [CIP patch series](kernel/patches/4.19.325-cip136/README.md) and [patch audit](kernel/patches/4.19/audit).

NCQ is disabled with `libata.force=noncq`; the SATA driver uses queue depth 1. Hang recovery uses kernel panic and reboot settings, not a hardware watchdog.

## Debian sid

The current setup uses **Debian unstable (sid) from debian-ports, architecture `powerpc`, with sysvinit**. systemd >= 258 requires kernel >= 5.4, so it cannot serve as init on the supplied CIP 4.19 kernel. Sid is a rolling unstable distribution; package versions change over time.

The root filesystem is built on an x86 Linux PC or WSL using debootstrap and qemu-user. It includes dropbear, Samba, NFS, chrony, smartmontools and libubootenv-tool. The generic image adds the patch-21 CIP kernel, DHCP networking, Windows network discovery through wsdd2, an LED status service, Samba configuration and `mbl-boot`.

The image contains no personal SSH keys or host keys; dropbear creates host keys on first connection. It uses hostname `mybooklive` and root password `debian`; **change the password before exposing the NAS to the network**.

See [Debian sid build and installation instructions](debian/sid-sysvinit/README.md) for the current image, checksums, build commands and compatibility notes.

## Multiboot and installation

Debian, OpenWrt rescue and a test kernel are selected from the running system with `mbl-boot`. Two unconfirmed boots trigger fallback; hung-task/soft-lockup recovery can reboot a stuck kernel. See [multiboot setup and boot confirmation](uboot/boot_multi/README.md).

Before installing, back up your data and keep a working rescue boot. The documented layout uses Debian on `/dev/sda4`, swap on `/dev/sda3` and data on `/dev/sda5`; adapt it to your disk. Kernel 4.19 cannot mount ext4 filesystems with `orphan_file`, and swap must match the kernel's 16K page size. Follow the installation steps in the sid guide.

Custom firmware replaces the original WD software and web interface. Recovery from a failed installation may require opening the enclosure.

## Samba and performance

The sid setup uses [samba/smb-sid.conf](samba/smb-sid.conf). The fork also provides a [32-bit Samba 4.25 smbstatus fix](debian/samba-fix/install-smbstatus-fix.sh).

The current NAS additionally loads [samba-splice v2](debian/samba-splice/README.md) only through the smbd service, with a versioned precompiled library and a checked rollback. The shim bypasses the userspace payload buffer; pipe-to-ext4 page-cache copying remains and is accelerated by patch 0022. [Extended validation](bench/README.md#splice-resource-and-error-validation) covered 1454 file round trips, independent parallel sessions, 60 reconnects, 12 forced disconnects and 1800 in-process error/reuse cases. No accumulating resource use was observed in the bounded test; this is not a 96-hour or long-term stability certification.

Recorded CIP tests with **GRO and MAL interrupt coalescing reached 69 MiB/s SMB write and 106 MiB/s read** on 1 GbE with a Windows client and a 2 GiB test file. Write speed was 68.8 MiB/s with `rx-frames 64` (the configured setting) and 69.0 MiB/s with `rx-frames 256`, both at `rx-usecs 500`. The patch-21 package separately recorded 66.9–67.3 MiB/s write and 102.8–106.3 MiB/s read, with local copy/hash checks. The old script printed MB/s but actually divided by 1024². See the [kernel notes](kernel/patches/4.19.325-cip136/README.md) and [benchmark summaries](bench/README.md); generated raw captures stay local and are excluded from Git.


### Recorded comparison (September–October 2026)

Measurements on the same single-disk MBL with 1 GbE and a Windows client. The first three rows are historical 2 GiB tests; the fourth row uses three 1 GiB writes and cold NAS readbacks with SHA256, no perf recording. All SMB figures below are MiB/s; disk dd figures are decimal MB/s. Disk and TCP figures were not repeated for the fourth configuration.

| Configuration | SMB write / read (MiB/s) | disk dd write / read (MB/s) | TCP rx / tx |
|---|---|---|---|
| Jessie + 4.19.99 + Samba 4.2 | 58 / 100 | 115 / 121 | 853 / 903 Mbit/s |
| OpenWrt 25.12 (6.12, stock drivers) | 34 / 35 | 68 / 77 | 615 / 527 Mbit/s |
| sid + 4.19.325-cip136-mbl + Samba 4.25 | 69 / 106 | 115 / 123 | 930 / 985 Mbit/s |
| sid + 4.19.325-cip136-p22 + Samba 4.25, pagecopy + splice | **76.3 / 106.3** | not repeated | not repeated |

The fourth row is the median of three transfers on the published `4.19.325-cip136-st20-mbl-p22-wd-perf` binary: **76.34 / 106.32 MiB/s**, with write range 73.99–76.89 MiB/s and all readback hashes matching. See [p22 results](bench/README.md#p22-kernel-with-persistent-splice). Earlier pagecopy builds and the [no-perf A/B/A](bench/README.md#pagecopy-and-perf-comparison) used a different source base and are retained as historical comparisons, not relabelled as p22 measurements. The generic Debian image still contains p21 and does not include the new splice service wrapper.

## Repository layout

| Directory | Current fork contents |
|---|---|
| [debian/sid-sysvinit](debian/sid-sysvinit/README.md) | Debian sid rootfs/image builders, installation notes and MBL services |
| [kernel/patches/4.19.325-cip136](kernel/patches/4.19.325-cip136/README.md) | CIP patch series, configurations, build script and validation notes |
| [kernel/precompiled](kernel/precompiled) | Precompiled CIP kernel package and matching modules |
| [samba](samba) | Samba configuration for sid |
| [uboot/boot_multi](uboot/boot_multi/README.md) | Multiboot, rescue fallback and boot confirmation |
| [bench](bench) | SMB and on-device benchmark scripts and recorded results |
