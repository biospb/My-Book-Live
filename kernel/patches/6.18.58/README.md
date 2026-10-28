# Kernel 6.18.58 for the My Book Live

Experimental port of Linux 6.18.58 to the APM82181 / Apollo3G board,
tested on a single-disk MBL in October 2026. Base: stable
`v6.18.58`, commit `2926d88bb7fc4608fd942453d929c39e4e5ec006`.

## Patch series (final, p40)

The `patches/` directory contains the complete numbered series of the
**p40** build — the measured best 6.18 variant:

| # | Patch | Purpose |
|---|---|---|
| 0001 | powerpc-apollo3g-ocm | Apollo3G board support, OCM allocator, 16K pages |
| 0002 | emac-tso-coalescing-gro-ocm | minimal upstream-EMAC feature patch: TAH IPv4 TSO, APM821xx coalescing, GRO, MAL/rings in OCM |
| 0003 | lib-iov_iter-bounded-pagecopy | bounded PPC pagecopy for aligned kernel-RAM copies (same as 4.19 patch 0022) |
| 0004 | crypto-crypto4xx-trng-dtb-match | match the `ppc4xx-trng` node of apollo3g.dtb |
| 0005 | dma-dw-apm821xx-descriptor-word-zeroing | replace `dma_pool_zalloc` dcbz with word stores on cache-inhibited coherent memory: removes 180 384 alignment traps per 512 MiB read |
| 0006-0008 | ata-sata_dwc (3 patches) | correctness fixes ported from the 4.19 series: `err_mask` on ATA_ERR, DW terminate + per-tag reset on hardreset, propagate `ata_host_activate` failure |
| 0009-0010 | dma-dw (2 patches) | cache the channel initialization (one `DW_DMA_IS_INITIALIZED` flag) and pass the held lock into `dwc_complete_all` (removes an unlock/relock pair on every DMA completion) |
| 0011-0013 | emac-tx-opt (3 patches) | inline splice fill helpers, `netdev_xmit_more()` batching with a pending-kick invariant, `napi_consume_skb()` in poll_tx |
| 0014-0015 | block/tcp inline | inline `blk_start_plug` (header) with `__blk_plug_init` in blk-core, inline `tcp_nagle_check`/`tcp_minshall_check` |
| 0016 | powerpc-csum-partial-dcbt-prefetch | prefetch ahead in `__csum_partial` (Rosen Penev's v3, October 2026) |

The configuration is [config/.config.6.18.58-mbl-p40-perf](config/.config.6.18.58-mbl-p40-perf):
16K pages, `PREEMPT_NONE`, `HZ_100`, `PERF_EVENTS=y`, `MTD_PHYSMAP=y` +
`MTD_PHYSMAP_OF=y` (so `fw_printenv` can read the U-Boot environment from
the running system), `MQ_IOSCHED_DEADLINE` not set (`none` scheduler),
no `PAGE_POOL`, `TASK_DELAY_ACCT=y` with runtime `task_delayacct=0`.
NCQ stays off through the boot argument `libata.force=noncq`.

Build: [build.sh](build.sh) creates a fresh worktree at the pinned base,
applies 0001–0016 in order, copies the config and runs the usual
`make ARCH=powerpc CROSS_COMPILE=powerpc-linux-gnu- CC=powerpc-linux-gnu-gcc-12`
uImage/modules build.

## Measured results (single-disk MBL, Windows client, honest no-perf medians)

All SMB numbers are MiB/s, three 1 GiB robocopy `/J` transfers with the
persistent [Samba splice v2 shim](../../../debian/samba-splice/README.md),
SHA256 after every cold readback, readahead 128 KiB:

| Kernel | SMB write | SMB read | notes |
|---|---:|---:|---|
| 4.19.325-cip136 p22 | 76.4 | 106.7 | reference |
| 6.18.58 p28 upstream-EMAC base | — | 66.9 | before the fixes below |
| 6.18.58 p31 + 0005 zeroing | 69.7 | 97.9 | main read gain |
| 6.18.58 p35 + 0009/0010 DW opt | 73.2 | 98.1 | main write gain |
| 6.18.58 p37 + 0011-0015 | 73.2 | 99.5 | |
| **6.18.58 p40 + 0016** | **72.6** | **100.1** | **final** |

Local disk rates are equal on both kernels (dd buffered 117/115 MiB/s,
direct 121/122 MB/s on p22/p40), pure iperf3 is 940/834 Mbit/s on both.
The remaining −5% write / −6% read gap against p22 traces to softirq
CPU (+4.7 percentage points) and iowait (+5.9) — spread across
NET_RX packet processing in 6.18, not to a single hotspot.

Runtime knobs measured with no reproducible effect:
`net.core.gro_normal_batch` (1/8/32), DW `memory_burst` (1/4/8/16),
8K LLI blocks (patch 0019, kept out of the final series),
`mq-deadline` vs `none` scheduler (p33/p39), OCM MAL placement (p29),
cached MAL_CFG (p32 — read −4.8%, rejected), `can_queue` widening (p38 —
unsafe, rejected). 

## Precompiled package

[Precompiled p40 archive](../../precompiled/linux-6.18.58-mbl-p40-perf.tgz)
contains the tested uImage, board DTB, config, System.map and the two
matching modules (loop, tun), plus a
[debug vmlinux](../../precompiled/vmlinux-6.18.58-mbl-p40-perf.xz) for
perf and [checksums](../../precompiled/SHA256SUMS-p40-perf).

Note on sizes: the p40 uImage is 4.7 MB (gzip) versus 3.45 MB for p22 —
Linux 6.18 carries five more years of core code (folio layer, io_uring,
blk-mq, extended security hooks), text+data grow from 7.2 MB to 9.7 MB
(+34%). The shipped `vmlinux-…-p40.xz` is **without** DWARF debug info
(`CONFIG_DEBUG_INFO_NONE`); for perf symbolization `System.map` is
sufficient, a debug build can be reproduced from this directory with
`CONFIG_DEBUG_INFO=y`.
