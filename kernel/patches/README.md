# Building My-Book-Live kernels

Patch series and build instructions per kernel version live in their own
directories:

| Directory | Status |
|---|---|
| [2.6.32](2.6.32/) | historical vendor-era kernel, the only one that runs the original WD firmware |
| [4.9](4.9/) | historical LTS series (ewaldc), superseded by 4.19 |
| [4.19](4.19/) | first 4.19 patch series (ewaldc), superseded by the CIP rebase |
| [4.19.325-cip136](4.19.325-cip136/README.md) | **current production kernel (p22)**: CIP SLTS 4.19 with the audited APM821xx patch series 0001–0022 |
| [6.18.58](6.18.58/README.md) | **experimental October 2026 port** of Linux 6.18.58 (p40); measured, documented, kept as a candidate |

## Performance context

The historical vendor-era 2.6.32.70/71 kernel with 64K pages remains the
fastest in absolute numbers (Samba up to 118 MB/s write with a tuned
filesystem), but it requires the original WD firmware layout and is not
maintainable today. Within the Debian sid setup used by this fork:

| Kernel | SMB write / read (MiB/s) | measured |
|---|---|---|
| 4.19.325-cip136 **p22** | 76.4 / 106.7 | honest no-perf medians, October 2026 |
| 6.18.58 **p40** | 72.6 / 100.1 | same methodology, same month |

Both are within the practical limits of the 1 GbE + single HDD hardware;
pure iperf3 (940/834 Mbit/s) and local dd (115–123 MB/s) are equal on
both kernels. The remaining 6.18 gap is softirq-heavy NET_RX packet
processing, spread across the stack rather than a single hotspot —
details in [6.18.58/README.md](6.18.58/README.md) and
[6.18.58/audit/](6.18.58/audit/).

## Building

Each series directory contains a `build.sh` (4.19.325-cip136 and 6.18.58)
or documented make invocation, the exact `config/` used for the tested
binary, and per-patch sources. Cross-compile with
`powerpc-linux-gnu-gcc-12` on an x86 host (see
[cross-compilation](../cross-compilation/README.md)).
