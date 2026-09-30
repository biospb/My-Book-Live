# samba-splice (experiment, not in use)

LD_PRELOAD replacement for Samba's `sys_recvfile()` (libsmbconf, `SMBCONF_0.0.1`) that uses
splice(2) socket -> pipe -> file. Samba ships the splice variant disabled
(`try_splice_call = false` in source3/lib/recvfile.c, still so in master 2026), so
`min receivefile size` does read(2) + write(2).

    make CC=powerpc-linux-gnu-gcc-12
    LD_PRELOAD=/usr/local/lib/samba-splice.so /usr/sbin/smbd -D

Result on 4.19.325-cip136-mbl-gro, Samba 4.25, 2 GB robocopy write (MD5 verified):
64.5 MB/s vs 67 MB/s with plain read/write. The socket -> user copy disappears, but the
remaining pipe -> page cache `memcpy` grows from ~20% to ~33% CPU: it now reads the
freshly DMA'd skb data from DRAM (cache misses), which the read/write path paid in the
first copy. The copy cost is memory bound, removing one copy of cache-hot data gains nothing.
