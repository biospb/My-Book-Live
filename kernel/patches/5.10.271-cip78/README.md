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
| 0022 | EMAC: direct streaming DMA mapping (no `dma_map_page_attrs()` dispatch per packet) | — |
| 0023 | EMAC/MAL: no NAPI re-poll for a waiting RX packet, TX queue lock instead of `netif_tx_lock` | 0029 |

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

## 0022: direct streaming DMA mapping (510r7), 2026-11-02

On 5.10 every `dma_map_single()` / `skb_frag_dma_map()` goes through the out-of-line `dma_map_page_attrs()`
before the cache sync (4.19 reaches `dma_nommu_map_page` directly). 0022 maps with
`arch_sync_dma_for_device()` + the physical address in the RX refill/recycle and TX paths; `emac_probe()`
checks once that the DMA API returns the same address (boot log: `emac: direct streaming DMA mapping`).

iperf3 at a fixed 600 Mbit/s, 3 runs: `dma_map_page_attrs` (510r5: 126-154 samples rx, 65-98 tx of 20000)
is gone, `__dma_sync` rises by ~90 rx (the sync itself stays); CPU idle rx 25-29 -> 30-32 %, tx within noise.
SMB 510r7: write 74.6-80.4, read 97.9-102.8 (one 77.7 outlier, as on every kernel). Integrity check OK.
A 4.19 counterpart is not needed: 4.19 calls `dma_nommu_map_page` without the extra dispatch.

## 0023: no NAPI re-poll for a waiting RX packet, lighter TX lock (510r8), 2026-11-02

The "CPU idle during read ~5 % vs ~22 %" above is partly an accounting effect and partly real.
`/proc/stat` mixes exact NO_HZ idle/iowait time with 100 Hz tick samples for user/sys/softirq, and
`perf record` at 1 kHz eats idle time itself. A SCHED_IDLE busy loop that counts iterations
([bench/soak.c](../../../bench/soak.c); free CPU = rate under load / rate on an idle system) avoids both. Free CPU during the SMB read, 3 runs each:

| Kernel | free CPU | NET_RX softirqs/s | NET_TX softirqs/s |
|---|---|---|---|
| 4.19 p28 | 32.8-34.8 % (33.6) | 2600 | 2600 |
| 4.19 p31 (p28 + 0029) | 32.5-33.7 % (33.1) | 2450 | 0 |
| 510r7 | 21.1-23.6 % (22.1) | 6600 | 6400 |
| 510r8 (510r7 + 0023) | 24.3-27.1 % (26.1) | 2300 | ~10 |

The gap is real (~11 points), not an accounting artifact. Tracepoints (`irq:softirq_raise` with stack
trace triggers, `napi:napi_poll`; FTRACE + EVENT_TRACING without the function tracer) showed where part of it goes:

- After `napi_complete_done()` the "rotting packet" check in `mal_poll()` re-scheduled NAPI whenever another
  frame was already in the ring. On 5.10 this kept NAPI re-polling itself from ksoftirqd, 2-3 packets per poll
  (4800 polls/s, 87 % of them in ksoftirqd; 4.19: 3600/s, 6 %). The RX coalescing interrupt still fires for
  that frame, so 0023 re-polls only for the RX-stopped case.
- `poll_tx()` took `netif_tx_lock_bh()`; its unlock reschedules the qdisc and raised NET_TX on every poll.
  0023 takes only the TX queue lock. This one is in 4.19 too (0029 there).

Checks: SMB 510r8 write 76.7-82.2, read 100.0-102.8 MiB/s; iperf3 916-950 Mbit; ping idle 0.87 ms,
under NAS TX 2.4 ms, under NAS RX 7.8 ms (same on all kernels); adaptive ping 4 x 20000 x 1400 B
shows no stuck RX packet beyond the rare 0.7-1.8 s stall that every kernel shows from the WSL client
(none in 160 000 pings from the NAS to Windows, so it is in the WSL network path). Integrity check OK.

The other ~7 points are spread over the 5.10 stack (perf, same load, 2 runs each, samples p28 -> 510r8):
blk-mq completion with interrupts off (`dma_dwc_xfer_done` 77 -> 442, attribution skew), list RX with the
route hint (`ip_list_rcv`, `ip_route_use_hint`, `fib_validate_source`, ~+500), softirq entry (+318),
slab and page cache changes. `gro_normal_batch=1` and a locked qdisc (`pfifo`) changed nothing.

