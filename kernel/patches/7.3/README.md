# Kernel 7.3.0 for the My Book Live — 73r1-slim

First working 7.3 port, booted 28 Oct 2026 (trial slot `debian-test`).
Base: mainline `v7.3` (`091b06388b117fefdcb63336ac09956a4914b961`),
release `7.3.0-mbl-73r1-slim`.

## Series (patches/)

Port of the 6.18.58 p40 series (see ../6.18.58/README.md). Two chunkeey
patches shipped for 7.3-rc3 turned out to be already upstream in v7.3:
the netops fix (`7c9f391ec89c`) and GRO-Rx/MAL-desc-clear in emac —
so only his board patch is needed. Applied: his
`9999-powerpc-apm82181-add-WD-MyBook-Live-NAS.patch` + our 0001–0016.
Conflicts vs 6.18.58:

* 0001: 7.3 moved PPC4xx GPIO to drivers/gpio (`GPIO_PPC44X`); Kconfig/
  Makefile conflicts resolved to keep only `PPC4xx_OCM`.
* 0002/0013: upstream already has `emac_clear_mal_desc` + GRO in
  `emac_poll_rx` (via net-next); 3-way merge kept our TSO/coalescing
  additions on top. The empty-line conflict in core.c resolved to upstream.
* 0014-header: plug API moved from blkdev.h to include/linux/blk_plug.h
  in 7.3; the inline `blk_start_plug` hack lives there now, core part
  unchanged.
* 0016: upstream checksum_32.S still has no dcbt prefetch (verified
  `git diff v6.18.58..v7.3` — zero sata_dwc commits, dw-dma cosmetic
  only; emac got devm rewrite but our hunks applied).

The final tree is emitted as per-patch diffs between index-tree
snapshots (git write-tree after each step); all 13 patch files apply
cleanly in sequence on pristine v7.3 (seqcheck verified).

## Config (config/.config.7.3-mbl-73r1-slim)

Started from the p40 config, merged a slim fragment:

* **Fixes for 7.3 Kconfig changes:** `PREEMPT_NONE` now requires
  `ARCH_NO_PREEMPT` (not available on powerpc) — olddefconfig silently
  picked full `PREEMPT`; set `PREEMPT_LAZY=y` explicitly, which also
  restores `TINY_RCU` (p40 had tiny RCU, the silent default was TREE+PREEMPT_RCU).
  `BOOTPARAM_*_PANIC` became int-typed: `=1` keeps the p40 panic behavior.
* **Modules (never loaded):** NFSD/SUNRPC/GSS/KRB5, F2FS, overlay, MD/DM,
  VLAN, inet diag, GPIO_PPC44X + leds-gpio + gpio-74xx (LED service loads
  them), loop, tun.
* **Off:** suspend/PM, rfkill, BPF JIT, initrd, watchdog drivers, I2C
  (both nodes `disabled` in DTB), DEBUG_FS (ocm debugfs viewer becomes
  a no-op stub, as in 4.19), SCSI proc fs, 93cx6, legacy block autoload.
* **Kept y:** MTD JEDECPROBE + CFI_INTELEXT — the flash chip probes as
  `SST 39LF040`; without JEDECPROBE physmap falls back to map_rom and
  `fw_printenv` breaks (first boot learned this the hard way: mbl-boot
  could not reset boot_count).

PHYLIB_LEDS is `def_bool OF` and stays y (~2 KB, phy LEDs are hardware
wired on MBL).

## Results

uImage (gzip): **3.74 MiB** vs 4.7 MiB for 6.18 p40, 3.45 MiB for the
4.19 p22 reference. Config file: 70 KB vs 81 KB (p40).

## Measured results (28 October 2026, same NAS/client/methods as p40)

Measured the same day back-to-back with the p40 control (see
[bench/README.md](../../bench/README.md#linux-73-comparison-73r1-slim-october-2026)
for the full table). Sequential-client tools (Copy-Item, robocopy `/J`)
top out at ~70 MiB/s read on every kernel — strace confirms the same
1 MiB `sendfile64` kernel path, the gap is client-side pipeline depth.
Pipelined tools (`xcopy /J`, Explorer) measure the real difference:

| Kernel | SMB write (xcopy) | SMB read (xcopy, contiguous) | dd write / read (MB/s) | iperf3 rx / tx |
|---|---:|---:|---|---|
| 6.18.58 p40 (control) | 68.9–70.2 | 101.7 | 91–108 / 108–120 | 859 / 940 |
| **7.3.0-mbl-73r1-slim** | **66.7–69.2** | **102.1** | **107–109 / 113–119** | **859 / 940** |

Equal within noise on every metric. The boot-time `read_ahead_kb` is
set to 128 by patch 0017 (see below) and again in rc.local; without it
the 7.3 block layer starts at 8192 KiB for rotational disks.

## Patch 0017: read-ahead cap

7.3 `blk_apply_bdi_limits()` inflates read-ahead to `2 × max_sectors`
for rotational disks that do not report `io_opt`. On sata_dwc
(`max_sectors` 8192, 16K pages) that is an 8 MiB window — wasteful on a
256 MiB NAS and different from the 128 KiB default the p22/p40 numbers
were measured with. The patch drops the fallback so the kernel starts
at the standard 128 KiB; rc.local sets it explicitly as a belt-and-
braces measure.

## Smoke test (28 Oct, trial boot on the NAS)

* boots via bootsel=2, sshd answers, `mbl-boot confirm-ssh` resets
  boot_count=0 (after the JEDECPROBE fix)
* eth0 up at gigabit link, netconsole parameters accepted
* OCM: 32 KiB enabled non-cached (MAL descriptors live there again)
* EMAC coalescing via ethtool: RX 64/500us TX 40/0us restored from
  rc.local
* ext4 root+data rw, swap on sda3, smbd 4.25 serving
* perf: software events only (cpu-clock/task-clock/cs/page-faults);
  no hardware PMU on 44x in upstream (same as p22/p40, not a regression)
* modules install via kmod (had to `apt-get install kmod` on the NAS —
  the rootfs predates it)

## Deploy package

`/root/deploy-73r1-slim-pkg/` on the WSL build host (uImage, vmlinux,
System.map, .config, apollo3g.dtb, modules tgz + SHA256SUMS). The NAS
copy is `/root/mbl-73-20261028/p43/`; installed as the trial kernel,
p22 image kept as `uImage.p22-20261028` in the same slot, retired
`uImage.before-clean/before-p22` archived under `/root/mbl-73-20261028/retired/`
(hash-verified before unlink).

Build: worktree `/root/k419/wt-7.3-port` at v7.3, series applied in
order (see export6.sh history), config merge with
`scripts/kconfig/merge_config.sh`, `make -j8 ARCH=powerpc
CROSS_COMPILE=powerpc-linux-gnu- CC=powerpc-linux-gnu-gcc-12
LOCALVERSION= uImage modules`.
