# My Book Live benchmarks

Raw captures, perf data, per-run logs and generated reports live locally under `bench/results/`, which is excluded from Git. This file keeps the measured summaries and enough methodology to interpret them. The older [SMB CSV](smb-bench.csv) remains available as a compact historical record.

## Units

SMB scripts divide bytes by PowerShell `1MB`, which is 1,048,576 bytes. Their results are **MiB/s**, even though the original script and CSV columns were named MB/s / WriteMBs / ReadMBs. The CSV column names are retained for compatibility. Disk rates from [mbl-bench.sh](mbl-bench.sh) explicitly multiply by 1.048576 and are decimal **MB/s**. iperf rates use **Mbit/s**.

The historical SMB comparison is therefore **69 / 106 MiB/s**, not decimal MB/s. Comparing that with the final **76.34 / 106.32 MiB/s** shows higher write throughput and essentially unchanged read throughput. The series used different file sizes/configurations; this is not a controlled attribution of the entire difference to one patch.

## P22 kernel with persistent splice

26 October 2026, single-disk 3 TB MBL / APM82181, 1 GbE / MTU1500, Windows client and Samba 4.25. Kernel `4.19.325-cip136-st20-mbl-p22-wd-perf` includes SATA fixes 0020/0021 and bounded pagecopy 0022. Perf is available but was not recording; copy-alignment counters are absent. The versioned Samba splice v2 shim uses a 1 MiB pipe. Coalescing: rx-frames=64 / rx-usecs=500.

Three 1 GiB writes with robocopy /J, followed by fsync and per-file FADV_DONTNEED on the NAS, SMB readback and SHA256 on Windows:

| Run | Write MiB/s | Read MiB/s |
|---|---:|---:|
| 1 | 73.99 | 105.84 |
| 2 | 76.34 | 106.32 |
| 3 | 76.89 | 106.45 |
| Median | **76.34** | **106.32** |

All hashes matched. Write timing covers robocopy; the subsequent flush is measured separately, so these are not fully synchronous durable-write latencies. Disk dd and pure TCP were not repeated for this exact build. The generic Debian image still contains p21; the new kernel and splice wrapper are separate installations.

Reproduce with [run-copydiag.ps1](run-copydiag.ps1):

```powershell
./bench/run-copydiag.ps1 -Session mbl-profile-20261026-p22-perf `
    -PersistentSplice -NoProfile -SizeMiB 1024 `
    -ExpectedKernel 4.19.325-cip136-st20-mbl-p22-wd-perf
```

Choose a new session name for each run; the script refuses to overwrite results. It removes its test data after success and leaves persistent splice enabled. Local report: `bench/results/2026-10-26-p22-perf/`. [Kernel build, package and integrity validation](../kernel/diagnostics/p22-perf/README.md).

## Pagecopy and perf comparison

Earlier kernels used the source branch through patch 0019, not the complete p22 stack. Software cpu-clock profiles at 99 Hz found the original splice memcpy at 32.94–35.78% self samples. Bounded pagecopy reduced the corresponding raw-copy hotspot to 24.41–25.55%. The new symbol `__copy_tofrom_user` was called from memcpy_from_page on kernel RAM, not from an SMB userspace payload buffer. These percentages are sampled self time, not independent inclusive costs.

An earlier profiled series measured 68.20 MiB/s splice before pagecopy and 74.59 MiB/s after pagecopy. All six new 1 GiB transfers passed SHA256. Different boot sessions and disk variation limit the comparison.

To test whether perf support/counters should be removed, A/B/A ran without perf recording and with counters disabled or absent throughout:

| Kernel / session | Plain MiB/s | Splice MiB/s |
|---|---:|---:|
| Perf available, A1 | 63.96 | 72.24 |
| No perf or counters, B | 65.76 | 76.95 |
| Original perf kernel restored, A2 | 65.53 | 79.19 |

Each cell is the median of three writes; all 18 readback hashes matched. A2 varied more from A1 than the apparent clean-build gain. Removing perf/counters did not show a reproducible throughput benefit. The final p22 retains perf but removes the temporary counter code entirely. Local reports: `bench/results/2026-10-26-pagecopy-smb/` and `bench/results/2026-10-26-pagecopy-clean/`.

## Splice resource and error validation

The unchanged v2 userspace shim was tested on the preceding pagecopy kernel with 1,454 successful file round trips: a 300-second sustained session, four parallel clients for about 90 seconds each, 60 reconnects, and 12 forced client exits during large writes. A healthy client passed a 1 MiB hash check after every forced exit. Workloads included small/large files, unaligned modifications, append, truncate, zero extension, flush, rename and deletion. Completed data passed SHA256; all partial files were released and removed.

The sustained worker was observed for about 327 seconds. After warm-up, RssAnon stayed at **6,416 KiB**, FDs remained within **31–37**, and the same shim pipe pair was retained. MemAvailable changed from 217,728 to 217,152 KiB after the workload/restarts; swap use remained zero. System file-nr changed from 378 to 405, so this is not a claim of exact system-wide resource equality. No accumulating resource trend, OOM, kernel/ATA errors or Samba core dumps were observed in this bounded window. smaps/PSS was unavailable in that configuration.

An additional in-process [reuse test](../debian/samba-splice/test-reuse.c) ran 1,800 calls after warm-up, including EFBIG, output errors, EAGAIN, EOF and drain failures. FDs stayed at baseline or baseline+2; the pipe was closed/recreated correctly. RSS increased by an initial 64 KiB and then remained at 4,048 KiB. This is not a day-long soak, sanitizer run or general thread-safety certification.

Three ordinary service restarts and a NAS reboot retained splice. Separate 8 MiB hash probes produced only a few KiB of service uaccess copies, confirming payload bypass on the earlier diagnostic kernel. The final p22 has no such counters and separately passed local cp/splice/unaligned tests, the seven shim regression cases and the three 1 GiB SMB readbacks above. Local report: `bench/results/2026-10-26-splice-persistent/`. [Installation and rollback](../debian/samba-splice/README.md).

## Copy-loop experiments

Exact PPC loop tests measured roughly 206 MiB/s for cold memcpy versus 318 MiB/s for the existing bounded-prefetch loop; hot-source controls were about 537 versus 698 MiB/s. These are RAM microbenchmarks, not Samba throughput. Helper tests covered 470 cases, including 104 injected incomplete copies; a bounds model checked 1,032,256 combinations. Global memcpy and its assembler remain unchanged.

Increasing the pipe from 256 KiB to 1 MiB reduced TCP-to-file splice-call pairs per GiB from 45,967 to 11,494. Nominal pipe capacity differs from payload capacity when RX fragments consume separate slots. The unsafe global prefetch experiment that read beyond its source and corrupted DMA-owned data is not used.

Local reports include `2026-10-25-wd-perf`, `2026-10-26-copydiag`, `2026-10-26-tcp-splice`, `2026-10-26-null-copy`, `2026-10-26-prefetch-distance` and `2026-10-26-smb-splice-v2` under `bench/results/`. Scripts and benchmark source are retained in Git; generated captures are not.

## Linux 6.18.58 comparison

The same run-copydiag methodology was applied to the 6.18.58 port (p28–p42
variants, honest no-perf medians of three 1 GiB transfers):

| Kernel | Write MiB/s | Read MiB/s | dd write / read (MB/s) | iperf3 rx / tx |
|---|---:|---:|---|---|
| 4.19.325-cip136 p22 (reference) | 76.4 | 106.7 | 104–117 / 113–123 | 941 / 834 Mbit/s |
| 6.18.58 p40 (final variant) | 72.6 | 100.1 | 102–116 / 117–122 | 937 / 824 Mbit/s |

Local disk and pure TCP are equal on both kernels; the SMB gap comes from
softirq CPU in NET_RX packet processing (+4.7 percentage points) and
iowait (+5.9), not from a single hotspot. The iperf3 client is WSL with a
bridged network; single-stream TX tops at ~834 Mbit/s, 4-8 parallel
streams reach 939. The historical 985 Mbit/s tx figure predates the
current WSL network setup. Per-variant reports, softirq/IRQ diagnostics
and the guarded trial tooling are documented in
[../kernel/patches/6.18.58/README.md](../kernel/patches/6.18.58/README.md).
The production NAS remains on p22.

## Linux 7.3 comparison (73r1-slim, October 2026)

The 7.3 port ([kernel/patches/7.3](../kernel/patches/7.3/README.md)) was
measured on 28 October 2026 on the same NAS, same splice shim, same
Windows client, same methods. Sequential-client tools (Copy-Item,
robocopy `/J`) issue one SMB2 READ at a time and top out at ~70 MiB/s on
every kernel; pipelined tools (`xcopy /J`, Explorer) reach higher
figures. strace on smbd confirms the identical kernel path in both
cases: 1 MiB `sendfile64` calls, so the difference is client-side
pipeline depth, not the kernel.

| Kernel (same-day measurements) | SMB write (xcopy) | SMB read (xcopy, contiguous file) | SMB read (Copy-Item) | dd write / read (MB/s) | iperf3 rx / tx |
|---|---:|---:|---:|---|---|
| 6.18.58-mbl-p40 (control re-run) | 68.9–70.2 | 101.7 | 69.6–71.6 | 91–108 / 108–120 | 859 / 940 Mbit/s |
| 7.3.0-mbl-73r1-slim | 66.7–69.2 | 102.1 | 70.5–72.3 | 107–109 / 113–119 | 859 / 940 Mbit/s |

Notes from the same-day diagnostics:

* The reference-file placement matters: a file written with
  `posix_fallocate` (32 extents with gaps up to 442 MB) reads at
  ~71 MiB/s while a contiguously written file reads at ~101 MiB/s.
  Both figures are seek-bound client physics, not kernel differences.
* The 7.3 block layer inflates `read_ahead_kb` to 8192 for rotational
  disks without `io_opt` (2 × `max_sectors`); the series caps it back to
  the 128 KiB default (patch 0017) and rc.local sets it explicitly.
* No hardware PMU exists for 44x in upstream; profiling used
  `cpu-clock` sampling. Per-kernel `__copy_tofrom_user` cost during
  buffered dd read is ~54% of CPU samples but the wall time is disk-bound
  (direct I/O 118 MB/s on both kernels).

