# Kernel 6.1.189-cip61 for the My Book Live (61r3)

The 5.10-cip series ported to the CIP SLTS 6.1 tree (tag `v6.1.189-cip61`). The port takes the final 5.10
series files and merges them three-way onto the 6.1 base, so related 5.10 patches are folded into one patch per
subsystem. Boots in the test slot, `mbl-boot` confirm works, integrity checks pass, no warnings in `dmesg`.

| # | Patch | 5.10 counterpart |
|---|-------|---|
| 0001 | apollo3g board, OCM allocator, APM821xx Kconfig; CPU flags via the 6.1 `CONFIG_464_CPU` (`-mcpu=464`) | 0005, 0012 |
| 0002 | sata_dwc_460ex APM821xx rework, whole 5.10 driver (6.1 base changes are cleanups only) | 0001-0004, 0006-0009, 0011 |
| 0003 | crypto4xx: match the `ppc4xx-trng` node of the MBL dtb | 0010 |
| 0004 | dw-dma APM821xx rework (4.19 layout, 8K LLIs, word-store zeroing, cached descriptor state, preallocated LLIs) | 0013, 0016, 0017, 0019 |
| 0005 | EMAC/MAL rework (coalescing, TAH TSO, OCM rings, GRO, exact TX count, direct DMA mapping, no NAPI re-poll) | 0014, 0018, 0021-0023 |
| 0006 | lib/iov_iter: bounded copy for kernel-mapped sources | 0015 |
| 0007 | math64: `div_u64_rem()` / `div_u64()` always inline | 0020 |
| 0008 | dma-direct: zero remapped coherent buffers through the cached alias | new |

6.1 API changes in 0005: `netif_napi_add_weight()`, `eth_hw_addr_set()`, `of_get_ethdev_address()`,
`platform_device_put()`, ethtool ringparam / coalesce callbacks with `kernel_*` and `extack`, no `GRO_DROP`,
fortify-safe `memcpy()` of the TAH tables, `dcr_unmap()` in `mal_remove()`. In 0002: no `ata_get_cmd_descript()`.

Kernel `dcbz` on uncached memory: 6.1 emulates it in `fix_alignment()` with `WARN_ON_ONCE(!user_mode(regs))`,
so the first trap prints a call trace at boot. Two boot-time sources: `dma_direct_alloc()` cleared the uncached
remap with `memset()` (0008 zeroes the cached alias before `arch_dma_prep_coherent()`), and `emac_probe()`
cleared the OCM descriptor rings with `memset()` (0005 uses `memset_io()`). The same traps exist on 4.19/5.10
without the warning; they happen only at probe time, `perf stat -e alignment-faults` during I/O shows 0.

Config: [config/.config.6.1.189-cip61-mbl-61r3](config/.config.6.1.189-cip61-mbl-61r3) (from 510r8 + olddefconfig,
`464_CPU`, MTD trap as on 5.10: `MTD_PHYSMAP=y`, `MTD_PHYSMAP_OF=y`, `MTD_JEDECPROBE`). Build: `build.sh` (gcc 12),
release `6.1.189-cip61-mbl-61r3`.

## Results (2026-11-02, disk 65-66 C)

SMB fixed-placement bench ([bench/fixed-placement-bench.ps1](../../../bench/fixed-placement-bench.ps1)), smbd with
the splice-v3 shim, 4 runs, medians MiB/s. Free CPU during the SMB read = SCHED_IDLE soaker
([bench/soak.c](../../../bench/soak.c)), 3 runs.

| Kernel | write | read | free CPU on read |
|---|---|---|---|
| 4.19 p31 | 81.0 | 101.2 | 33.1 % |
| 5.10 510r8 | 79.0 | 101.8 | 26.1 % |
| **6.1 61r3** | **79.2** | **101.6** | **22.8 %** (21.7-24.3) |

iperf3 (quick check, 61r2): NAS rx 910-943 Mbit (idle ~19 %), NAS tx 897-985 Mbit (idle ~35 %).
dd O_DIRECT sda5: 132 / 98-120 / 116 MB/s at 2 / 36 / 600 GB. Integrity (raw 1 GiB md5, file copy md5) OK.

6.1 matches 5.10 in throughput and uses ~3 points more CPU on the SMB read; 4.19 stays the lightest.
