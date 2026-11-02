# Building My-Book-Live kernels

Patch series and build instructions per kernel version live in their own
directories:

| Directory | Status |
|---|---|
| [2.6.32](2.6.32/) | historical vendor-era kernel, the only one that runs the original WD firmware |
| [4.9](4.9/) | historical LTS series (ewaldc), superseded by 4.19 |
| [4.19](4.19/) | first 4.19 patch series (ewaldc), superseded by the CIP rebase |
| [4.19.325-cip136](4.19.325-cip136/README.md) | **current production kernel (p31)**: CIP SLTS 4.19 with the audited APM821xx patch series 0001–0029 |
| [5.10.271-cip78](5.10.271-cip78/README.md) | **candidate (510r8)**: the 4.19 series ported to CIP SLTS 5.10, patches 0001–0023 |
| [6.1.189-cip61](6.1.189-cip61/README.md) | **port (61r3)**: the 5.10 series on CIP SLTS 6.1, 8 patches (one per subsystem); same speed as 5.10 |
| [6.18.58](6.18.58/README.md) | **experimental October 2026 port** of Linux 6.18.58 (p40); measured, documented, kept as a candidate |
| [7.3](7.3/README.md) | **mainline 7.3 port (73r1-slim)**: same series rebased on v7.3 plus a slim config; measured equal to p40 on the same day (October 2026) |

## Performance context

The historical vendor-era 2.6.32.70/71 kernel with 64K pages remains the
fastest in absolute numbers (Samba up to 118 MB/s write with a tuned
filesystem), but it requires the original WD firmware layout and is not
maintainable today. Within the Debian sid setup used by this fork:

| Kernel | SMB write / read (MiB/s) | free CPU on SMB read | measured |
|---|---|---|---|
| 4.19.325-cip136 **p22** | 76.4 / 106.7 | — | no-perf medians, new file per run, October 2026 |
| 6.18.58 **p40** | 72.6 / 100.1 | — | same methodology, same month |
| 7.3 **73r1-slim** | 69.2 / 102.1 | — | same-day p40 control: equal within noise |
| 4.19.325-cip136 **p31** (production) | 81.0 / 101.2 | 33 % | fixed-placement bench, November 2026 |
| 5.10.271-cip78 **510r8** (candidate) | 79.0 / 101.8 | 26 % | same methodology, same day |
| 6.1.189-cip61 **61r3** | 79.2 / 101.6 | 23 % | same methodology, same day |

All are within the practical limits of the 1 GbE + single HDD hardware;
pure iperf3 (~940 Mbit/s rx, 900–985 tx) and local dd (115–132 MB/s) are
equal on all kernels. The 73r1-slim SMB figures are pipelined-client (`xcopy /J`)
transfers; sequential clients (Copy-Item) top out at ~70 MiB/s on every
kernel. The remaining 6.18 gap versus p22 is softirq-heavy NET_RX packet
processing, spread across the stack rather than a single hotspot —
details in [6.18.58/README.md](6.18.58/README.md) and
[6.18.58/audit/](6.18.58/audit/).

The October rows write a new file per run, so the disk zone differs between
kernels; they are not directly comparable with the November rows. Since
November 2026 the SMB numbers come from the fixed-placement bench
([bench/fixed-placement-bench.ps1](../../bench/fixed-placement-bench.ps1): same
disk blocks every run, 4 runs, medians, splice v3 shim) and CPU headroom from
a SCHED_IDLE soaker ([bench/soak.c](../../bench/soak.c)) during the SMB read.
Throughput of 4.19, 5.10 and 6.1 is the same within noise; the newer kernels
spend more CPU per packet in the network and block stacks, so 4.19 stays the
production kernel.

## Building

Each series directory contains a `build.sh` (4.19.325-cip136,
5.10.271-cip78, 6.1.189-cip61, 6.18.58, 7.3) or documented make invocation, the exact `config/` used for the
tested binary, and per-patch sources. Cross-compile with
`powerpc-linux-gnu-gcc-12` on an x86 host (see
[cross-compilation](../cross-compilation/README.md)).
