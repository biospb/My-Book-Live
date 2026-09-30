#!/bin/sh
# On-device benchmark for the My Book Live: system info, SMB server settings, raw disk speed.
# POSIX sh, works on Debian (Jessie/sid) and OpenWrt busybox.
#
#   sh mbl-bench.sh [test-dir] [size-MiB]      e.g.  sh mbl-bench.sh /nfs 1024
#
# The test dir must be on the DATA partition (sda5); a temporary file is created and removed.

DIR=${1:-/nfs}
SIZE=${2:-1024}
TST="$DIR/_mblbench.dd"

uptime_cs() { awk '{ printf "%d", $1 * 100 }' /proc/uptime; }
drop_caches() { sync; echo 3 > /proc/sys/vm/drop_caches; }
rate() { awk -v mb="$1" -v cs="$2" 'BEGIN { printf "%.1f MB/s (%.1f s)", mb * 1.048576 / (cs / 100), cs / 100 }'; }

echo "==== system"
uname -a
grep -m1 -iE 'cpu|model' /proc/cpuinfo
echo "page size: $(getconf PAGESIZE 2>/dev/null)"
free 2>/dev/null | head -3
[ -r /etc/openwrt_release ] && grep DESCRIPTION /etc/openwrt_release
[ -r /etc/debian_version ] && echo "debian: $(cat /etc/debian_version)"

echo "==== network"
ip -o link show eth0 2>/dev/null | sed 's/link\/.*//'
command -v ethtool >/dev/null && ethtool eth0 2>/dev/null | grep -E 'Speed|Duplex'
command -v ethtool >/dev/null && ethtool -k eth0 2>/dev/null | grep -E 'segmentation|checksumming' | grep -v fixed
command -v ethtool >/dev/null && ethtool -c eth0 2>/dev/null | grep -E 'rx-usecs|rx-frames|tx-frames' | grep -v ': 0$'

echo "==== smb server"
command -v smbd >/dev/null && smbd -V
command -v testparm >/dev/null && testparm -s 2>/dev/null |
	grep -iE 'signing|encrypt|sendfile|aio |socket options|min protocol|max protocol|max xmit|strict sync|sync always'
lsmod 2>/dev/null | grep -q ksmbd && echo "ksmbd loaded" && cat /etc/ksmbd/ksmbd.conf 2>/dev/null | grep -vE '^\s*(;|#|$)'

echo "==== disk ($TST, $SIZE MiB)"
mount | grep " $(df -P "$DIR" | awk 'NR==2 { print $6 }') "
command -v hdparm >/dev/null && hdparm -t /dev/sda 2>/dev/null | grep -i timing

drop_caches
t0=$(uptime_cs)
dd if=/dev/zero of="$TST" bs=1M count="$SIZE" conv=fsync 2>/dev/null
t1=$(uptime_cs)
echo "write: $(rate "$SIZE" $((t1 - t0)))"

drop_caches
t0=$(uptime_cs)
dd if="$TST" of=/dev/null bs=1M 2>/dev/null
t1=$(uptime_cs)
echo "read:  $(rate "$SIZE" $((t1 - t0)))"
rm -f "$TST"

echo "==== done"
echo "Next: run 'iperf3 -s' here, and 'vmstat 1' in a second session while the SMB test runs."
