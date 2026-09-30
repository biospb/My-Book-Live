#!/bin/bash
# Configure and build the MBL 4.19.325 kernel (uImage + modules) with gcc-12
set -u
cd /root/k419/wt-v4.19.325
MK="make ARCH=powerpc CROSS_COMPILE=powerpc-linux-gnu- CC=powerpc-linux-gnu-gcc-12 LOCALVERSION= -j8"
OUT=/root/k419/out
mkdir -p $OUT

if [ "${1:-}" != "--no-config" ]; then
	cp /mnt/c/GitHub/My-Book-Live/kernel/patches/4.19/config/.config.4.19 .config
	C=scripts/config
	$C --enable SECCOMP --enable SECCOMP_FILTER
	$C --enable INET_DIAG --enable INET_TCP_DIAG --enable INET_UDP_DIAG --enable UNIX_DIAG
	$C --enable IKCONFIG --enable IKCONFIG_PROC
	$C --enable NEW_LEDS --enable LEDS_CLASS --enable LEDS_GPIO --enable LEDS_TRIGGERS
	$C --enable EXT4_FS_POSIX_ACL --enable EXT4_FS_SECURITY --enable TMPFS_POSIX_ACL --enable TMPFS_XATTR
	$C --module TUN
	$C --enable PPC_DISABLE_WERROR --disable BPF_SYSCALL
	$C --set-str LOCALVERSION "-mbl" --disable LOCALVERSION_AUTO
	$C --set-str UEVENT_HELPER_PATH ""
	$MK olddefconfig > $OUT/olddefconfig.log 2>&1
	grep -E "^(# )?CONFIG_(SECCOMP|SECCOMP_FILTER|INET_DIAG|UNIX_DIAG|IKCONFIG_PROC|LEDS_GPIO|EXT4_FS_POSIX_ACL|TUN|PPC_WERROR|BPF_SYSCALL|PPC_16K_PAGES|SATA_DWC|IBM_EMAC|NETCONSOLE|LOCALVERSION)[ =]" .config
fi

echo "==== build started $(date +%T)"
$MK uImage modules > $OUT/build.log 2>&1
rc=$?
echo "==== build finished $(date +%T) rc=$rc"
grep -nE "error:|Error [0-9]|undefined reference|No rule to make" $OUT/build.log | head -40
grep -c "warning:" $OUT/build.log
ls -la arch/powerpc/boot/uImage 2>/dev/null
exit $rc
