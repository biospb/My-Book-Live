# Kernel 4.19.325-cip136 for the My Book Live

The `../4.19.325` series rebased onto the CIP SLTS tree (tag `v4.19.325-cip136`,
git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git), which keeps 4.19 alive with
backports from newer stable kernels (cip136 = up to date with 5.10.266, Sept 2026).
About 380 CIP commits touch code built with this config (nfsd, ext4/jbd2, net, mm).

| # | Patch |
|---|-------|
| 0001-0004 | revert the 4 CIP sata_dwc_460ex fixes, so that the APM821xx rework applies unchanged |
| 0005-0015 | the `../4.19.325` series (0001-0011) |
| 0016 | the same 4 CIP sata_dwc fixes ported to the rework (clear only the requested INTPR bit, `__ffs` tag scan, no `num_processed`, enable IRQs after `ata_host_activate`) |
| 0017 | sata_dwc: `ata_std_qc_defer`, reset per-tag state on hardreset |
| 0018 | crypto4xx TRNG: match the `ppc4xx-trng` node of apollo3g.dtb (`/dev/hwrng` = crypto4xx) |
| 0019 | emac: `napi_gro_receive()` instead of `netif_receive_skb()` (as OpenWrt apm821xx 710), SMB write +9% |
| 0020 | dw dmaengine: 8K LLI blocks (a multiple of the burst), needed for PAGE_SIZE > 16K |
| 0021 | sata_dwc: terminate the DMA channel on hardreset, so one DMA timeout cannot wedge all later commands |

NCQ stays off (`libata.force=noncq`): the driver keeps queue depth 1, and ewaldc's experimental
`4.9/sata_dwc_ncq.7z` driver was reviewed and rejected (early completion, wrong-tag DMA
completion, out-of-bounds writes; NCQ disabled in it too).

Kernel release: `4.19.325-cip136-st20-mbl` (CIP adds `localversion-cip`/`localversion-st`).
Config `config/.config.4.19.325-cip136-mbl` is identical to the 4.19.325 one after `olddefconfig`.
Build: `build.sh` (gcc 12).

## Results (Debian sid, Samba 4.25, `libata.force=noncq`)

| | 4.19.325-mbl | 4.19.325-cip136-mbl |
|---|---|---|
| SMB write / read, MB/s | 61.2 / 106.0 | 61.7 / 105.9 (2 of 9 runs dipped shortly after boot) |
| dd write / read, MB/s | 95-115 / 118-120 | 96-108 / 117-123 |
| iperf3 rx / tx, Mbit/s | 919 / 983 | 930 / 985 |

### 0019 GRO (A/B on the same boot with `ethtool -K eth0 gro off|on`, recvfile 16K)

| | GRO off | GRO on |
|---|---|---|
| SMB write / read, MB/s | 61.4 / 106.2 | 67.1 / 106.0 |

During an SMB write the CPU is 100% busy: sys 67%, softirq 30%, user 2.4% (smbd userspace ~2%).
`iperf3 -s -F file` (TCP rx + write() to ext4, no SMB) gives the same 534 Mbit/s = 67 MB/s,
pure iperf3 rx 940 Mbit/s: the limit is the kernel rx + copy + ext4 path, not Samba.
`min receivefile size` 0 vs 16384 makes no difference (67.5 vs 67.1).

### MAL rx interrupt coalescing (`ethtool -C eth0 rx-frames N`, GRO on, 2 runs each)

| rx-frames / rx-usecs | 32 / 500 (default) | 64 / 500 | 128 / 500 | 256 / 500 | 64 / 250 | 64 / 1000 |
|---|---|---|---|---|---|---|
| SMB write, MB/s | 66.2 | 68.8 | 68.3 | 69.0 | 64.8 | 68.2 |

Reads stay at 105-106. rx-frames 64 is set from `/etc/rc.local` (the Kconfig default
`CONFIG_IBM_EMAC_RX_COAL_COUNT=32` is unchanged).

### Rejected: memcpy source prefetch (was 0020)

Adding `dcbt` prefetch to `memcpy()` (as `__copy_tofrom_user()` has) made the splice shim path faster
(64.5 -> 69.5 MB/s, plain Samba unchanged), but it **corrupts data**: a `cp` of a 3.4 MB file under that
kernel had one 32-byte cache line replaced by stale memory contents. The prefetch ran up to
`MAX_COPY_PREFETCH` lines past the end of the source; on the non-coherent 44x such a line can belong to a
buffer that a device is writing by DMA at that moment (the cache is invalidated only when the DMA is
mapped), so the CPU later reads the stale cached line. `__copy_tofrom_user()` stops prefetching before
the end of the source for this reason. Not worth fixing for a gain that only shows with the splice shim.

### Hang protection (config only, release `-wd`, config `config/.config.4.19.325-cip136-mbl-wd`)

`CONFIG_DETECT_HUNG_TASK` with `DEFAULT_HUNG_TASK_TIMEOUT=180` and `BOOTPARAM_HUNG_TASK_PANIC`, plus
`SOFTLOCKUP_DETECTOR` with `BOOTPARAM_SOFTLOCKUP_PANIC`. With `panic=10` from boot.scr a hung boot
reboots and boot.scr switches system after two failed boots; before, a kernel that came up with a hung
disk (e.g. the 64K-page test: endless ata2 DMA timeouts) never reached rc.local, so confirm-ssh never
rebooted it. Only a task stuck in D state without being scheduled for 180 s counts, normal heavy I/O
does not: 3x2 GB SMB write+read gave no warning and the same speed (67.4 / 104.7 MB/s). Tested with
`sysctl kernel.hung_task_timeout_secs=20; fsfreeze -f /DataVolume; touch /DataVolume/x` -> panic after
23 s, reboot, boot confirmed. The Book E hardware watchdog is not used: on 44x its longest period is
2^29 timebase ticks (~0.67 s at 800 MHz), too short for a userspace pinger on a loaded, non-preemptible
kernel.

### 0020/0021 and 64K pages

With 64K pages the block layer raises the SATA `dma_boundary` 0x1fff to PAGE_SIZE-1, sg segments reach
64K and the dw DMA split them into 16380-byte blocks (4095 words, not a multiple of the 64-byte burst):
bursts of the later blocks crossed 8K Data FIS boundaries and every such write timed out. Because EH never
stopped the dw channel, the stuck descriptor then blocked every later command (endless `ata2: hard
resetting link`). ewaldc's 4.9 driver used 8192-byte LLIs.

With 0020/0021 a 64K-page kernel (`-p21-64k`) boots and the disk works: 300 MB urandom write/read/cp on
sda4 and 3.5 GB of reads on sda5 with correct MD5s, no ATA errors. 16K kernel with 0020/0021 (`-p21`):
SMB 67.1 / 104.2 MB/s, dd 118 / 111 MB/s, 2 GB SMB write + local cp MD5 OK, i.e. unchanged.

64K pages are still not usable: after mounting sda5 rw, `/etc/init.d/smbd restart` made the whole system
unresponsive (ping answers, SSH banner does not, nothing on netconsole, no hung task / soft lockup
panic) and it needed a power cycle. Memory was not short right after boot (65 MB used, 182 MB available).
Cause not found.
