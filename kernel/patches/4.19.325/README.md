# Kernel 4.19.325 for the My Book Live

ewaldc's 4.19.99 patch set rebased onto the last 4.19 stable release (v4.19.325), reduced
to what is still needed and with the bugs from the audit fixed (see `../4.19/audit/`).

| # | Patch | Origin |
|---|-------|--------|
| 0001 | OCM debugfs check | 4.19/002 |
| 0002 | `-mcpu=464fp` | 4.19/009 |
| 0003 | apollo3g board | 4.19/201 (Kconfig + ppc44x_simple only) |
| 0004 | dma-buf without debugfs | 4.19/904 |
| 0005 | dw_dma tweaks | 4.19/997 |
| 0006 | sata_dwc_460ex rework | 4.19/996 |
| 0007 | EMAC/MAL rework | 4.19/992 |
| 0008 | mal: wrong goto | upstream 4bd7823cacb2 |
| 0009 | EMAC fixes: use-after-free in rx_sg_append, NULL deref in mal_poll, peek_rx_sg stepping, RXI wait precedence, 5 s watchdog, TSO only when gso_size matches the TAH segment size | new |
| 0010 | sata_dwc fixes: propagate ATA errors, NEWFP tag, polling qc, IRQ return value, hsdev out of OCM | new |
| 0011 | statx `STATX_MNT_ID` + `STATX_ATTR_MOUNT_ROOT`: systemd >= 262 tools (tmpfiles/sysusers, run by dpkg) fail without it | backport of 5.8 fa2fcf4f1df1, 80340fe3605c |

See `../4.19.325-cip136` for the same series on the CIP SLTS tree (preferred).

Dropped from 4.19.99: 140, 201 extras, 202, 204, 207, 301, 321, 702, 801-804, 901, 902, 990, 991, 993, 994, 995.
The OOB write CVE-2022-49073 in sata_dwc is fixed upstream in v4.19.325.

The dtb is the prebuilt `kernel/dts/apollo3g.dtb`.

## Config

`config/.config.4.19.325-mbl` = `4.19/config/.config.4.19` plus SECCOMP(+FILTER), INET/UNIX_DIAG,
IKCONFIG_PROC, LEDS_GPIO, EXT4/TMPFS POSIX ACL, PPC_DISABLE_WERROR, no BPF_SYSCALL,
LOCALVERSION `-mbl`.

## Build

gcc 12 (`gcc-12-powerpc-linux-gnu`), see `build.sh`:

    git worktree add wt v4.19.325 && cd wt && git am ../patches/*.patch
    cp .../config/.config.4.19.325-mbl .config
    make ARCH=powerpc CROSS_COMPILE=powerpc-linux-gnu- CC=powerpc-linux-gnu-gcc-12 LOCALVERSION= olddefconfig uImage modules

## Results (Debian sid, Samba 4.25, `libata.force=noncq`)

| | 4.19.99 ewaldc | 4.19.325-mbl |
|---|---|---|
| SMB write / read, MB/s | 62.2 / 105.9 | 61.2 / 106.0 |
| dd write / read, MB/s | 117-118 / 117-122 | 95-115 / 118-120 |
| iperf3 rx / tx, Mbit/s | 853 / 903 | 919 / 983 |
