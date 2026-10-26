# samba-splice: an experimental recvfile path for My Book Live

An LD_PRELOAD replacement for Samba's `sys_recvfile()` (`SMBCONF_0.0.1`). It changes socket → userspace → file into socket → pipe → file. With the tested head_frag RX path, most socket-to-pipe payload is passed by page reference. The pipe-to-ext4-page-cache stage still copies data. The generic skb splice implementation may copy locked/cloned linear heads, so the first stage is not guaranteed to be zero-copy for every driver or packet.

The versioned v2 library is enabled in the NAS's SysV smbd startup. The current p22 kernel includes SATA fixes 0020/0021 and bounded pagecopy 0022, retains perf, and contains no copy-alignment counters. The kernel archive alone does not enable this userspace shim.

## Persistent service startup

The smbd start command in `/etc/init.d/smbd` adds `--startas /usr/local/libexec/smbd-splice`, while retaining `--exec /usr/sbin/smbd` and PIDFILE so stop/status still identify the real daemon. The [wrapper](smbd-splice) runs:

```sh
exec env LD_PRELOAD=/usr/local/lib/samba-splice-1m-v2.so /usr/sbin/smbd "$@"
```

Only this service startup supplies the preload; smbd children inherit it. Other SysV services and `/etc/ld.so.preload` are unchanged.

The [installer](install-persistent.py) checks the tested library's exact SHA256, backs up the original init script, and installs root-owned mode-0755 files through temporary files and rename. The NAS backup and installation record are under `/root/mbl-splice-persistent-20261026/`. These dated scripts describe this NAS setup, not a universal installer. The older `/usr/local/lib/samba-splice.so` is not used by the wrapper.

A normal `env -u LD_PRELOAD /etc/init.d/smbd restart` now **keeps splice enabled**. To disable it, restore the original init script first:

```sh
python3 /root/mbl-splice-persistent-20261026/rollback-persistent.py
env -u LD_PRELOAD /etc/init.d/smbd restart
```

The [rollback](rollback-persistent.py) checks both script hashes and refuses to overwrite a script modified since installation. It leaves the library and wrapper available for diagnosis; the restored startup does not use them. After a Samba package update, check that the local `--startas` change remains in place.

## v2 changes

- Increased pipe capacity from 256 KiB to 1 MiB: 64 slots instead of 16 with 16K pages. In the TCP-to-file test, actual chunks grew from 23,360 to 93,440 bytes and splice-call pairs per GiB fell from 45,967 to 11,494. Pipe capacity is not the same as usable TCP payload capacity when individual RX fragments occupy slots.
- Track socket bytes consumed separately from file bytes written. After a partial output and error, drain `count - consumed`; the old calculation subtracted some progress twice and could consume the next SMB request.
- Return -1 for the first output failure, EOF and other input failures. EAGAIN preserves already written progress.
- Delegate append-marker, O_APPEND and drain-only requests to Samba before consuming their payload. Retry drain polling after EINTR.

One pipe pair is retained per process. The shim assumes serialized calls through smbd's sys_recvfile path; it is not a general thread-safe replacement for arbitrary applications.

## Build and regression checks

[Precompiled library and checksum](precompiled/README.md) are provided for the tested Debian sid PowerPC / Samba 4.25 environment. To cross-build from WSL:

```sh
make CC=powerpc-linux-gnu-gcc-12
powerpc-linux-gnu-gcc-12 -O2 -Wall -Wextra -Werror \
    -D_FILE_OFFSET_BITS=64 -D_TIME_BITS=64 -o test-splice test-splice.c -ldl
powerpc-linux-gnu-gcc-12 -O2 -Wall -Wextra -Werror \
    -D_FILE_OFFSET_BITS=64 -D_TIME_BITS=64 -o test-reuse test-reuse.c -ldl
```

Run the binaries on the NAS. The first five [regression cases](test-splice.c) need only the shim. The two fallback cases also need the real Samba library after the shim in the lookup scope:

```sh
LD_PRELOAD=/usr/local/lib/samba-splice-1m-v2.so:/usr/lib/powerpc-linux-gnu/libsmbconf.so.0 \
    ./test-splice /usr/local/lib/samba-splice-1m-v2.so --fallback
./test-reuse /usr/local/lib/samba-splice-1m-v2.so
```

The seven cases cover data/offset correctness, partial EFBIG with next-request framing, first output error with framing, EAGAIN, EOF after progress, O_APPEND fallback and drain-only fallback. The old revision failed the partial-write framing, first-output-error and EOF checks.

The [reuse test](test-reuse.c) exercises 1,800 calls in one process after warm-up, including errors and pipe reset/recreation after drain failure. Two retained pipe FDs per process are expected; they are not a per-request leak.

Tested v2 SHA256: `76d89bdbe119053c1f3994e509ee8607da3bfe4cd5d647e01366771d40780122`. This is different from the first experimental `samba-splice-1m.so` revision.

## Results and limits

[Persistent-startup and resource validation](../../bench/README.md#splice-resource-and-error-validation) covered 1,454 file round trips, four parallel clients alongside a sustained session, 60 reconnects, 12 forced disconnects, three service restarts and a reboot. Completed files passed SHA256. The sustained worker's RssAnon stayed at 6,416 KiB after warm-up, with bounded FD counts and one stable shim pipe. No accumulating resource use was observed during the bounded test; it was not a day-long soak or sanitizer run. That extended resource test used the preceding pagecopy kernel, not the final p22 rebuild.

[Final p22 measurements](../../bench/README.md#p22-kernel-with-persistent-splice) used three 1 GiB writes/readbacks: median **76.34 MiB/s write and 106.32 MiB/s read**, or **80.1/111.5 MB/s**, with all hashes matching. The final p22 also passed local copy/splice/unaligned checks and all seven shim regression cases.

A loaded library in `/proc/<pid>/maps` alone does not prove interception. Earlier diagnostic builds additionally checked uaccess counters: an 8 MiB SMB payload produced only a few KiB of service copies, including after automatic startup. Those temporary counters have been removed from the published p22 kernel.

Earlier comparisons: [TCP-to-file](../../bench/README.md#copy-loop-experiments), [splice v2 A/B](../../bench/README.md#copy-loop-experiments), and [pagecopy/no-perf A/B/A](../../bench/README.md#pagecopy-and-perf-comparison). The unsafe global memcpy-prefetch experiment that corrupted data is not used.
