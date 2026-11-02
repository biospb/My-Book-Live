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
| 0022 | lib/iov_iter: bounded PPC pagecopy for aligned, nonoverlapping APM821xx page-to-kernel copies; global memcpy unchanged |
| 0023 | dw dmaengine: zero new descriptors with `memset32()` instead of `dma_pool_zalloc()` (dcbz on cache-inhibited coherent memory raised ~350 alignment exceptions per MiB of disk I/O); backport of 6.18 0005 |
| 0024 | dw dmaengine: only the 7-word LLI stays in uncached coherent memory; descriptor software state (lists, txd, lengths) comes from 192 preallocated slots in cached RAM. IRQ-off time in ata_scsi_queuecmd halved |
| 0025 | emac/MAL: `struct mal_instance` (NAPI, poll state) always in cached RAM; only the descriptor rings go to OCM. Also fixes `kfree()` of an OCM pointer on the probe error path |
| 0026 | dw dmaengine: each of the 192 descriptor slots owns a preallocated coherent LLI (`lli[i]`), no `dma_pool_alloc/free` per LLI; dma_pool + kmem_cache remain as fallback |
| 0027 | math64: `div_u64_rem()`/`div_u64()` `__always_inline`, so constant divisors become multiplies (no effect on the 4.19 binary, removes 11 out-of-line copies in 5.10) |

## Current package: p22 with perf, without counters

`4.19.325-cip136-st20-mbl-p22-wd-perf` contains the full numbered series 0001–0022, including both SATA fixes 0020/0021. The earlier pagecopy measurements used the branch through 0019; those binaries must not be confused with this complete p22 rebuild. The final config is [config/.config.4.19.325-cip136-mbl-p22-wd-perf](config/.config.4.19.325-cip136-mbl-p22-wd-perf). PERF_EVENTS and software hang recovery remain enabled. No mbl_copy_diag files, calls, Makefile entry or proc counters are included.

Patch 0022 changes only `memcpy_from_page` for CONFIG_APM821xx. For copies >=256 bytes with word-aligned, nonoverlapping addresses it reuses the existing raw `__copy_tofrom_user` bounded-prefetch loop on mapped kernel RAM; short/unaligned/overlap copies keep memcpy. A reported incomplete raw copy retries the remainder with memcpy. This is a kernel-to-kernel copy, with no set_fs or userspace buffer. The old unsafe global memcpy prefetch experiment stays rejected.

Build from a clean CIP v4.19.325-cip136 checkout by applying patches 0001–0022 in order, copying the p22 config, and running `make ARCH=powerpc CROSS_COMPILE=powerpc-linux-gnu- CC=powerpc-linux-gnu-gcc-12 LOCALVERSION= olddefconfig uImage modules`. For the exact published build, [build script and source validation](../../diagnostics/p22-perf/README.md) record the p21 base plus 0022, CRCs, config diff, unchanged copy ASM, matching module ABI and package hashes. [Runtime results](../../../bench/README.md#p22-kernel-with-persistent-splice) describe the tested final binary; [precompiled package](../../precompiled/README.md) includes its matching board DTB and modules.

The Samba [splice v2 shim](../../../debian/samba-splice/README.md) is installed separately. It uses a 1 MiB pipe and preserves framing on partial/error paths; the p22 kernel alone does not enable Samba splice. A no-perf trial did not provide a reproducible speedup, so perf remains available. The temporary copy-alignment diagnostic patch is retained only as historical research under kernel/diagnostics and is not part of numbered p22.

NCQ stays off (`libata.force=noncq`): the driver keeps queue depth 1, and ewaldc's experimental
`4.9/sata_dwc_ncq.7z` driver was reviewed and rejected (early completion, wrong-tag DMA
completion, out-of-bounds writes; NCQ disabled in it too).

Kernel release: `4.19.325-cip136-st20-mbl` (CIP adds `localversion-cip`/`localversion-st`).
Config `config/.config.4.19.325-cip136-mbl` is identical to the 4.19.325 one after `olddefconfig`.
Build: `build.sh` (gcc 12).

## Results (Debian sid, Samba 4.25, `libata.force=noncq`)

| | 4.19.325-mbl | 4.19.325-cip136-mbl |
|---|---|---|
| SMB write / read, MiB/s | 61.2 / 106.0 | 61.7 / 105.9 (2 of 9 runs dipped shortly after boot) |
| dd write / read, MB/s | 95-115 / 118-120 | 96-108 / 117-123 |
| iperf3 rx / tx, Mbit/s | 919 / 983 | 930 / 985 |

### 0019 GRO (A/B on the same boot with `ethtool -K eth0 gro off|on`, recvfile 16K)

| | GRO off | GRO on |
|---|---|---|
| SMB write / read, MiB/s | 61.4 / 106.2 | 67.1 / 106.0 |

During an SMB write the CPU is 100% busy: sys 67%, softirq 30%, user 2.4% (smbd userspace ~2%).
`iperf3 -s -F file` (TCP rx + write() to ext4, no SMB) gives 534 Mbit/s (about 66.8 MB/s),
pure iperf3 rx 940 Mbit/s: the kernel rx + copy + ext4 path is the main limit. iperf reports decimal rates; the Windows SMB script reports MiB/s.
`min receivefile size` 0 vs 16384 makes no difference (67.5 vs 67.1).

### MAL rx interrupt coalescing (`ethtool -C eth0 rx-frames N`, GRO on, 2 runs each)

| rx-frames / rx-usecs | 32 / 500 (default) | 64 / 500 | 128 / 500 | 256 / 500 | 64 / 250 | 64 / 1000 |
|---|---|---|---|---|---|---|
| SMB write, MiB/s | 66.2 | 68.8 | 68.3 | 69.0 | 64.8 | 68.2 |

Reads stay at 105-106. rx-frames 64 is set from `/etc/rc.local` (the Kconfig default
`CONFIG_IBM_EMAC_RX_COAL_COUNT=32` is unchanged).

### Rejected: memcpy source prefetch (was 0020)

Adding `dcbt` prefetch to `memcpy()` (as `__copy_tofrom_user()` has) made the splice shim path faster
(64.5 -> 69.5 MiB/s, plain Samba unchanged), but it **corrupts data**: a `cp` of a 3.4 MB file under that
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
does not: 3x2 GB SMB write+read gave no warning and the same speed (67.4 / 104.7 MiB/s). Tested with
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
SMB 67.1 / 104.2 MiB/s, dd 118 / 111 MB/s, 2 GB SMB write + local cp MD5 OK, i.e. unchanged.

64K pages are still not usable: after mounting sda5 rw, `/etc/init.d/smbd restart` made the whole system
unresponsive (ping answers, SSH banner does not, nothing on netconsole, no hung task / soft lockup
panic) and it needed a power cycle. Memory was not short right after boot (65 MB used, 182 MB available).
Cause not found.

## p24: p23 + slim config (2026-11-02)

[config/.config.4.19.325-cip136-mbl-p24-wd-perf](config/.config.4.19.325-cip136-mbl-p24-wd-perf): the 7.3 slim
approach on 4.19. Modules (not loaded in normal use): NFSD/SUNRPC/LOCKD, F2FS, overlay, MD/DM, VLAN, inet diag,
brd. Off: suspend/PM sleep, rfkill, BPF JIT, initrd, watchdog drivers, I2C, DEBUG_FS, SCSI proc fs, staging,
uevent helper, /dev/port, GPIO sysfs. Kept built in: LEDS_GPIO + GPIO_74XX_MMIO (mbl-led does not modprobe),
MTD_PHYSMAP_OF + JEDECPROBE (u-boot env), PERF_EVENTS. vmlinux 7.62 -> 6.22 MB, uImage 2.79 MB.

Quick bench (iperf3, steady runs): NAS rx 941-952 Mbit idle 18-19 %, NAS tx 982-985 idle 36-48 %;
alignment faults 0. `-Os` (p24s, vmlinux text -21 %) costs CPU: rx idle 14.8 % (softirq 27 vs 21 %),
tx idle 28-33 % — so -O2 stays.

## p25: p24 + 0024 (2026-11-02)

1 GiB dd read of sda5, perf cpu-clock 2000 Hz, self samples in `ata_scsi_queuecmd` (= IRQ-off time of the
command issue, which builds the DW LLI chain) / `dwc_descriptor_complete`:

| Kernel | O_DIRECT | buffered |
|---|---|---|
| p22 (no 0023) | 943 / 148 | 1038 / 172 |
| 5.10 510r4 (with 0023) | 724 / 161 | 831 / 173 |
| p25o: state in OCM (uncached SRAM) | 778 / 105 | 859 / 119 |
| **p25: state in cached RAM** | **477 / 37** | **620 / 94** |

~2-2.5 % CPU less at 120 MB/s and about half the IRQ-off time per command. OCM is barely faster than uncached
DDR for this access pattern, so 0024 uses cached RAM (`DW_META_OCM` 0). Integrity: md5 of 1 GiB raw read
(direct and buffered) and a 1.6 GB file copy after drop_caches match the reference taken on another kernel.
Config: [config/.config.4.19.325-cip136-mbl-p25-wd-perf](config/.config.4.19.325-cip136-mbl-p25-wd-perf).

## p26: p25 + 0025-0027 (2026-11-02)

Same day, same disk temperature (66-67 C), 3 runs per kernel after >= 4 min uptime. iperf3 at a fixed
600 Mbit/s with perf (cpu-clock 2000 Hz, 10 s); dd 1 GiB of sda5, self samples in `ata_scsi_queuecmd`.

| Kernel | dd O_DIRECT | dd buffered | rx: CPU busy at 600 Mbit / `mal_poll` | tx: `mal_poll` |
|---|---|---|---|---|
| p25 | 466-475 | 587-617 | ~69.7 % / 675-712 | 274-312 |
| **p26** | **431-453** | **537-569** | ~67.7 % / 699-788 | 289-322 |
| p26r: MAL rings in coherent DDR (`MAL_RINGS_OCM` 0) | 450-471 | 541-556 | ~69.5 % / 851-964 | 428-455 |

- 0026 takes another 6-8 % off the IRQ-off time of the SATA command issue.
- 0025: no measurable change (within the iperf client noise), kept because the instance is CPU-only data.
- Rings in uncached DDR instead of OCM cost ~20 % more in `mal_poll` (rx and tx), so the rings stay in OCM.
- 0027 does not change the 4.19 binary (same text size): the TCP divisions per ACK here have variable divisors.

Integrity (1 GiB raw read direct + buffered, 1.6 GB file copy) matches the reference, alignment faults 0.
Config: [config/.config.4.19.325-cip136-mbl-p26-wd-perf](config/.config.4.19.325-cip136-mbl-p26-wd-perf).
5.10 port of 0023-0027: [../5.10.271-cip78](../5.10.271-cip78/README.md).

### Tried after p26, not in the series

- 6.18 0012 tx batching (`xmit_more`): not ported. TSO is on and the driver has no BQL, so the qdisc never
  dequeues in bulk and `skb->xmit_more` is practically never set on 4.19.
- 6.18 0013 `napi_consume_skb()` in poll_tx (p27): CPU at a fixed 600 Mbit rx ~66.9 % vs p26 ~67.6 %, tx 60.2 vs
  59.7 % — no measurable change.
- `STACKPROTECTOR_STRONG` off (p27s, text -3.2 %): rx unchanged, tx ~57.6 vs ~60 %, at the noise limit. Kept on.

## 0028: exact TX descriptor count (2026-11-02)

`emac_start_xmit_sg()` estimated descriptors as `len >> 12`, but MAL chunks are 4080 bytes (a 16K fragment
takes 5, not 4), and `emac_xmit_finish()` stopped the queue only on `tx_cnt == NUM_TX_BUFF`. Near a full ring
this overwrote descriptors not sent yet. On 5.10 it hung TX under SMB reads (`mal0: TX descriptor error`, ~2.5 min
until the netdev watchdog); details in [../5.10.271-cip78](../5.10.271-cip78/README.md) (0021 there).
On 4.19 it was latent: the ring never got close to full (`tx_undo` 0 after 4 SMB runs, 597 on 5.10).
0028 counts the exact chunks before touching the ring and stops the queue on `>=`.

p28 = p26 + 0028 (p27 not included). SMB fixed-placement bench, 4 runs, disk 66-67 C: write median 77.5,
read 99.7 MiB/s (p26: 78.2 / 99.8 over 8 runs, p22: 74.4 / 99.6). Alignment faults 0, no MAL errors.

### Tried after p28, not in the series: BQL and xmit_more

- p29 = p28 + BQL in the EMAC driver (`netdev_sent_queue()` before the TMR0 kick, `netdev_completed_queue()`
  in poll_tx, `netdev_reset_queue()` on ring clean / open). The limit settles at 130-195 KB.
- p30 = p29 + one TMR0 kick per `xmit_more` batch (always kicked when the queue is stopped).
- SMB (4 runs, medians write/read): p28 82.3/95.4, p29 78.1/99.8, p30 79.7/100.2 — within the run-to-run noise.
  iperf at 600 Mbit: CPU idle and `mal_poll`/`tcp_ack`/`__dma_sync` samples unchanged.
- Ping under a full NAS TX load (iperf3 -R, 890-913 Mbit): 2.1 ms average with and without BQL. TCP small
  queues already keep the in-flight data per socket at ~256 KB, so BQL has nothing to cut; the qdisc never
  builds a backlog (requeues 0), so `xmit_more` is rarely set.
- No errors, tx_undo 0. Not adopted (no measurable gain); the change is small if it is needed later.

## 0029: no NAPI re-poll for a waiting RX packet, lighter TX lock (2026-11-02)

Same driver change as 5.10 0023 (details and measurements in [../5.10.271-cip78](../5.10.271-cip78/README.md)).
On 4.19 NAPI did not get stuck re-polling, so the gain is only the NET_TX softirq per poll (~3500/s) that
`netif_tx_lock_bh()` raised. Free CPU during the SMB read (SCHED_IDLE soaker): p28 33.6 %, p31 (p28 + 0029) 33.1 %,
within noise. SMB, same session, no keep-rpcd cron: p28 write 77.1-80.8 / read 100.5-102.1, p31 78.1-83.6 /
99.9-104.5 MiB/s. Kept for a common driver with 5.10. p31 is not the main kernel (main stays p28).
