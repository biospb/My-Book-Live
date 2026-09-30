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
