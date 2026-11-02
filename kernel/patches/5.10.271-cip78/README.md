# Kernel 5.10.271-cip78 for the My Book Live (510r5)

The 4.19.325-cip136 series ported to the CIP SLTS 5.10 tree (tag `v5.10.271-cip78`). The EMAC/MAL and dw-dma
drivers are the APM821xx rework of the 4.19 p22 series, adapted to the 5.10 APIs; mainline 5.10 versions are
replaced. Boots in the test slot, `mbl-boot` confirm works, integrity checks pass.

| # | Patch | 4.19 counterpart |
|---|-------|---|
| 0001-0004 | revert the 4 CIP sata_dwc_460ex fixes, so that the APM821xx rework applies unchanged | 0001-0004 |
| 0005 | apollo3g (WD My Book Live) board support | 0007 |
| 0006-0009 | sata_dwc_460ex APM821xx rework + bug fixes + CIP fixes ported + qc_defer | 0010, 0014, 0016, 0017 |
| 0010 | crypto4xx: match the `ppc4xx-trng` node of the MBL dtb | 0018 |
| 0011 | sata_dwc: terminate the DMA channel on hardreset | 0021 |
| 0012 | OCM allocator (from the 6.18 series, `ioremap_prot`) and `-mcpu=464fp` | 0005, 0006 |
| 0013 | dw-dma APM821xx rework incl. 8K blocks, adapted to the 5.10 dw headers | 0009, 0020 |
| 0014 | EMAC/MAL rework (coalescing, TAH TSO, OCM rings, GRO); 5.10 frag/phylib/tx_timeout/ethtool API | 0011-0013, 0019 |
| 0015 | lib/iov_iter: bounded PPC pagecopy | 0022 |
| 0016 | dw: zero descriptors with word stores (no dcbz alignment traps) | 0023 |
| 0017 | dw: descriptor software state in cached RAM | 0024 |
| 0018 | MAL instance in cached RAM, rings in OCM | 0025 |
| 0019 | dw: preallocated LLI per descriptor slot | 0026 |
| 0020 | math64: `div_u64_rem()`/`div_u64()` always inline | 0027 |
| 0021 | EMAC: count TX descriptors exactly before filling the ring (TX hang fix) | 0028 |

Config: [config/.config.5.10.271-cip78-mbl-510r5](config/.config.5.10.271-cip78-mbl-510r5) (slim, -O2, perf on).
Config trap: `olddefconfig` drops `MTD_PHYSMAP_OF`; it needs `MTD_PHYSMAP=y`, `MTD_PHYSMAP_OF=y` and
`MTD_JEDECPROBE`, otherwise `fw_printenv` and the boot confirm fail. Build: `build.sh` (gcc 12),
release `5.10.271-cip78-mbl-510r5`.

## Results (2026-11-02, disk 66-67 C, 3 runs per kernel)

Self samples (perf cpu-clock 2000 Hz) in `ata_scsi_queuecmd` for a 1 GiB dd read, and in `__div64_32` during
iperf3 NAS tx at a fixed 600 Mbit/s (10 s):

| Kernel | dd O_DIRECT | dd buffered | `__div64_32` tx | rx `mal_poll` |
|---|---|---|---|---|
| 510r4 (0001-0016) | 708-755 | 805-830 | 365-388 | 803-897 |
| 510r5n (+0017-0019) | 438-482 | 561-567 | 370-392 | 707-772 |
| **510r5 (+0020)** | **435-456** | **589-661** | **90-133** | 750-837 |
| 4.19 p26, same day | 431-453 | 537-569 | 105-106 | 699-788 |

- 0017+0019 cut the IRQ-off time of the SATA command issue by ~40 % (5.10 had no 0024 before).
- 0020 removes the 11 out-of-line `div_u64_rem` copies; `tcp_clock_us()` / `tcp_skb_timestamp_us()` per ACK
  now multiply, `__div64_32` on tx drops to the 4.19 level (~1.4 % CPU less). The CPU load at 600 Mbit stays
  within the iperf client noise.
- 5.10 still uses a few % more CPU than 4.19 at the same network rate (softirq 25-30 % vs 15-18 % on rx).

## 0021: TX ring overflow (SMB read hang), 2026-11-02

510r5 under the fixed-placement SMB bench ([bench/fixed-placement-bench.ps1](../../../bench/fixed-placement-bench.ps1)) hung twice in two boots,
both times in the second read run: `mal0: TX descriptor error (TXDEIR = 0x80000000)`, then no TX for ~2.5 min
until `NETDEV WATCHDOG ... transmit queue 0 timed out` reset the EMAC. The NAS did not reboot.

Cause, in `emac_start_xmit_sg()` (same code in the 4.19 driver): the descriptor estimate was `len >> 12`, but
MAL splits buffers into 4080-byte chunks, so a 16K fragment takes 5 descriptors, not 4. Near a full ring
`tx_cnt` reached 257, and `emac_xmit_finish()` stopped the queue only on `tx_cnt == 256`: the next frames
overwrote descriptors MAL had not sent yet. 0021 counts the exact chunks of the head and every fragment
before touching the ring (undo path removed) and stops the queue on `>=`.

A diagnostic build (510r6) logged 36 frames in 8 SMB runs where the old check would have overflowed the
ring (e.g. `tx_cnt 236, need 21`); with the fix all 8 runs passed. 5.10 hits it and 4.19 did not, most likely
because TX completion is slower on 5.10 (softirq ~38 % vs ~20 % at the same rate) and the ring runs fuller.
The 6.18 and 7.3 series use the upstream driver, which counts with `mal_tx_chunks()` per fragment and is not affected.

SMB fixed-placement bench, medians write / read MiB/s, smbd with the splice-v3 shim, disk 64-68 C:

| Kernel | runs | write | read | CPU idle during read |
|---|---|---|---|---|
| 4.19 p22 | 8 | 74.4 | 99.6 | ~22 % |
| 4.19 p26 | 8 | 78.2 | 99.8 | ~22 % |
| 510r4 | 4 | 71.6 | 97.0 | ~5 % |
| 510r5 (hangs) | 6 | 74.0 | 98.1 | ~5 % |
| 510r6 (0021 + diag) | 8 | 77.5 | 98.6 | ~5 % |
| 4.19 p28 (p26 + 0028) | 4 | 77.5 | 99.7 | ~21 % |
