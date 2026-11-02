# My Book Live: Debian sid and CIP kernel

This fork of [ewaldc/My-Book-Live](https://github.com/ewaldc/My-Book-Live) provides Debian sid images, a custom CIP SLTS PowerPC kernel and multiboot tools for the Western Digital My Book Live (MBL). The setup has been tested on a single-disk 3 TB MBL; My Book Live Duo has not been validated here.

## What is new?

Changes made in this fork (September–November 2026):

- **CIP kernel and precompiled package:** rebased the MBL patch set onto **4.19.325-cip136 (CIP SLTS)**, with audited driver fixes, build configurations and matching modules. The current package is **4.19.325-cip136-st20-mbl-p22-wd-perf**.
- **Kernel fixes and compatibility:** fixed EMAC use-after-free, TSO and SATA error handling; added SECCOMP, socket diagnostics, GPIO LEDs, crypto4xx TRNG and the statx mount-id backport required by current sid tools.
- **GRO and SATA DMA patches:** **0019** enables EMAC GRO; **0020** uses 8K DMA LLI blocks; **0021** terminates the SATA DMA channel on hard reset so a DMA timeout cannot wedge subsequent commands.
- **Bounded pagecopy and Samba splice:** **0022** reuses the existing bounded PPC copy loop for suitable page-to-kernel copies. The tested splice v2 shim uses a 1 MiB pipe, preserves request framing on errors and is loaded through the smbd SysV start path. The new kernel retains perf and removes the temporary copy-alignment counters.
- **November 2026 series 0023–0029 (p31):** no dcbz alignment traps in DW-DMA descriptor zeroing, descriptor state and MAL instance in cached RAM, preallocated LLIs, inline `div_u64`, a fix for an EMAC TX ring overflow that could hang TX for ~2.5 min, and no NAPI re-poll per waiting RX packet.
- **5.10 and 6.1 CIP ports:** the series ported to **5.10.271-cip78** (510r8, candidate) and **6.1.189-cip61** (61r3); same SMB speed as 4.19, slightly more CPU.
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

The source series has since grown to 0029: **p31** (`4.19.325-cip136-st20-mbl-p31-wd-perf`) is the kernel running on the test MBL since November 2026. Package: [`linux-4.19.325-cip136-st20-mbl-p31-wd-perf.tgz`](kernel/precompiled/linux-4.19.325-cip136-st20-mbl-p31-wd-perf.tgz) ([checksums](kernel/precompiled/SHA256SUMS-p31-perf), [debug vmlinux](kernel/precompiled/vmlinux-4.19.325-cip136-st20-mbl-p31-wd-perf.xz)); the 5.10 (510r8) and 6.1 (61r3) packages are listed in [kernel/precompiled](kernel/precompiled/README.md).

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


### Recorded comparison (September–November 2026)

Measurements on the same single-disk MBL with 1 GbE and a Windows client. The first three rows are historical 2 GiB tests; the fourth and fifth rows use three 1 GiB writes and cold NAS readbacks with SHA256, no perf recording. All SMB figures below are MiB/s; disk dd figures are decimal MB/s. The disk dd and TCP figures for rows 4–5 were measured on 28 October 2026 with the same client, same file and same WSL iperf3 setup (single-stream TX tops at ~834 Mbit/s with the current WSL bridged network; 4–8 parallel streams reach 939).

| Configuration | SMB write / read (MiB/s) | disk dd write / read (MB/s) | TCP rx / tx |
|---|---|---|---|
| Jessie + 4.19.99 + Samba 4.2 | 58 / 100 | 115 / 121 | 853 / 903 Mbit/s |
| OpenWrt 25.12 (6.12, stock drivers) | 34 / 35 | 68 / 77 | 615 / 527 Mbit/s |
| sid + 4.19.325-cip136-mbl + Samba 4.25 | 69 / 106 | 115 / 123 | 930 / 985 Mbit/s |
| sid + 6.18.58-mbl-p40 + Samba 4.25, splice v2 | **72.6 / 100.1** | 116 / 122 | 860 / 956 Mbit/s |
| sid + 7.3.0-mbl-73r1-slim + Samba 4.25, splice v2 | **69.2 / 102.1** | 107–109 / 113–119 | 859 / 940 Mbit/s |
| sid + 4.19.325-cip136-p22 + Samba 4.25, splice v2 | **76.3 / 106.3** | 117 / 123 | 938 / 958 Mbit/s |
| sid + 4.19.325-cip136-p31 + Samba 4.25, splice v3 ¹ | **81.0 / 101.2** | — / 119–128 | 941 / 907 Mbit/s |
| sid + 5.10.271-cip78-510r8 + Samba 4.25, splice v3 ¹ | **79.0 / 101.8** | — / 116–132 | 940 / 944 Mbit/s |
| sid + 6.1.189-cip61-61r3 + Samba 4.25, splice v3 ¹ | **79.2 / 101.6** | — / 120–132 | 939 / 940 Mbit/s |

¹ November 2026 rows: SMB from the fixed-placement bench (same disk blocks every run, 4 runs, medians; see below), so they are not directly comparable with rows 4–6. Disk: O_DIRECT raw read of `/dev/sda5` at 2 / 36 / 600 GB. TCP: medians of 4 single-stream iperf3 runs per direction; single-stream TX from the WSL client varies between 893 and 985 Mbit/s on every kernel.

**Fixed-placement re-measurement (2 November 2026).** Rows 4–6 used a new file per run, and the kernels placed it differently: 4.19 files landed 2–17 GB into the data partition (outer zone, raw direct read 119–131 MB/s), 6.18 files 1387–1573 GB in (98–106 MB/s). To remove that bias, all kernels were re-measured on the same physical blocks (36–41 GB in): writes into one zero-ranged file (`fallocate -z` keeps the blocks in place), reads from one unmodified 2 GiB file, 8 × 1 MiB unbuffered requests in flight from the Windows client, medians of runs 2–4, A/B/A order:

| Kernel (boot state), same file and blocks | SMB write / read (MiB/s) | CPU idle during read |
|---|---|---|
| 4.19 p22 (4 days uptime) | 74.0 / 102.7 | 22% |
| 6.18.58 p40 (fresh boot) | 71.2 / 100.2 | 5% |
| 7.3 73r1-slim (fresh boot) | 65.9 / 101.5 | 4% |
| 4.19 p22 (fresh boot, control) | 70.0 / 99.8–103 | 21% |

With placement controlled, p40 writes as fast as a freshly booted p22, and reads are disk-bound on every kernel. The new kernels use almost all CPU while reading where 4.19 leaves ~20% idle. Overwriting existing file data over SMB with the splice shim is slow (~34 MiB/s, synchronous read-modify-write of partially covered blocks); new files and Explorer's truncating copies are not affected.

**4.19 vs 5.10 vs 6.1 (2 November 2026, later session).** Same fixed-placement bench ([bench/fixed-placement-bench.ps1](bench/fixed-placement-bench.ps1), 4 runs, medians), smbd with the splice v3 shim. Free CPU during the read is measured with a SCHED_IDLE soaker ([bench/soak.c](bench/soak.c)); `/proc/stat` idle exaggerates the difference between kernels.

| Kernel | SMB write / read (MiB/s) | free CPU during read |
|---|---|---|
| 4.19.325-cip136 p31 | 81.0 / 101.2 | 33% |
| 5.10.271-cip78 510r8 | 79.0 / 101.8 | 26% |
| 6.1.189-cip61 61r3 | 79.2 / 101.6 | 23% |

Throughput is equal within noise; the remaining CPU gap is spread over the newer network and block stacks. Details in [kernel/patches/5.10.271-cip78](kernel/patches/5.10.271-cip78/README.md) and [kernel/patches/6.1.189-cip61](kernel/patches/6.1.189-cip61/README.md).

The fourth row is the median of three transfers on the published `4.19.325-cip136-st20-mbl-p22-wd-perf` binary: **76.34 / 106.32 MiB/s**, with write range 73.99–76.89 MiB/s and all readback hashes matching. See [p22 results](bench/README.md#p22-kernel-with-persistent-splice). Earlier pagecopy builds and the [no-perf A/B/A](bench/README.md#pagecopy-and-perf-comparison) used a different source base and are retained as historical comparisons, not relabelled as p22 measurements. The generic Debian image still contains p21 and does not include the new splice service wrapper. The fifth row is the 6.18.58 p40 build — see [kernel/patches/6.18.58](kernel/patches/6.18.58/README.md).

The sixth row is the mainline **Linux 7.3** port (73r1-slim), measured on
28 October 2026 with the same splice shim, RA128 and the same Windows
client. SMB figures are `xcopy /J` (pipelined, Explorer-like) transfers
of a contiguous 1 GiB file; sequential-client tools (Copy-Item,
robocopy) reach about 70 MiB/s read on any kernel because the client
itself sends one request at a time. Kernel-side profiling shows the
same 1 MiB `sendfile64` path on all kernels; the disk-level dd and
iperf3 numbers match p40 within noise. The 7.3 port carries the same
0001–0016 series (0016 since removed) plus a read-ahead cap and a slim config (3.74 MiB
uImage vs 4.7 MiB for p40) — see
[kernel/patches/7.3](kernel/patches/7.3/README.md).

### Linux 6.18.58 experiments (October 2026)

A full port of Linux 6.18.58 to the APM82181 was built and measured against
p22 with the same honest methodology (three 1 GiB robocopy `/J` transfers,
persistent Samba splice v2, SHA256 readbacks, no perf recording).

Most of the original gap came from where the test files were placed on
disk (see the fixed-placement table above); with the same blocks, p40
writes as fast as a freshly booted p22, and reads are disk-bound but cost
more CPU on 6.18. Local disk dd and pure iperf3 are equal on both kernels.
Patch 0016 (csum prefetch) was later removed as a data-integrity risk. The largest single win inside the
port was fixing dcbz alignment traps on noncoherent coherent-memory
(+39% read); the rest came from DW-DMA hot-path cleanup, EMAC TX batching
and inline patches ported from the 4.19 series plus one upstream
PowerPC patch. Sixteen numbered patches, guarded trial/rollback tooling,
full per-variant measurement reports, and a precompiled p40 package
([checksums](kernel/precompiled/SHA256SUMS-p40-perf)) are in
[kernel/patches/6.18.58](kernel/patches/6.18.58/README.md);

## Repository layout

| Directory | Current fork contents |
|---|---|
| [debian/sid-sysvinit](debian/sid-sysvinit/README.md) | Debian sid rootfs/image builders, installation notes and MBL services |
| [kernel/patches/4.19.325-cip136](kernel/patches/4.19.325-cip136/README.md) | CIP patch series, configurations, build script and validation notes |
| [kernel/patches/5.10.271-cip78](kernel/patches/5.10.271-cip78/README.md) | CIP 5.10 port of the 4.19 series (510r8): patches, config, build script, measurements |
| [kernel/patches/6.1.189-cip61](kernel/patches/6.1.189-cip61/README.md) | CIP 6.1 port (61r3): 8 patches, config, build script, measurements |
| [kernel/patches/6.18.58](kernel/patches/6.18.58/README.md) | Linux 6.18.58 port: numbered patch series, config, audit reports and trial tooling |
| [kernel/patches/7.3](kernel/patches/7.3/README.md) | Linux 7.3 port (73r1-slim): series rebased on mainline v7.3, slim config, build script |
| [kernel/precompiled](kernel/precompiled) | Precompiled kernel packages and matching modules (4.19 p31/p22, 5.10 510r8, 6.1 61r3, 6.18.58 p40, 7.3 73r1) |
| [samba](samba) | Samba configuration for sid |
| [uboot/boot_multi](uboot/boot_multi/README.md) | Multiboot, rescue fallback and boot confirmation |
| [bench](bench) | SMB and on-device benchmark scripts and recorded results |
