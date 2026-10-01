#!/bin/bash
# Turn the rootfs from build-rootfs.sh into a generic, ready-to-boot My Book Live image:
# kernel 4.19.325-cip136-mbl-p21 (GRO + hang recovery) and modules, MBL tools,
# Samba config, DHCP, no personal keys. Run as root after build-rootfs.sh (without a key):
#
#   sudo WORK=/root/mbl-generic ./build-rootfs.sh
#   sudo WORK=/root/mbl-generic ./make-image.sh
#
# Optional environment:
#   KERNEL_TGZ=../../kernel/precompiled/linux-4.19.325-cip136-st20-mbl-p21.tgz
#   HOSTNAME_MBL=mybooklive  ROOT_PASSWORD=debian  OUT=/path/to/image.tar.xz
#
# Result: $WORK/mbl-sid-sysvinit-<date>-gro-wd-p21.tar.xz, unpack onto the root partition
# (sda4 in uboot/boot_multi) with: tar -xJpf "$OUT" -C /mnt/new

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-/root/mbl-generic}
SRC=$WORK/rootfs
TARGET=$WORK/image
KERNEL_TGZ=${KERNEL_TGZ:-$REPO/kernel/precompiled/linux-4.19.325-cip136-st20-mbl-p21.tgz}
HOSTNAME_MBL=${HOSTNAME_MBL:-mybooklive}
ROOT_PASSWORD=${ROOT_PASSWORD:-debian}
OUT=${OUT:-$WORK/mbl-sid-sysvinit-$(date +%Y%m%d)-gro-wd-p21.tar.xz}

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -x "$SRC/sbin/init" ] || die "no rootfs at $SRC (run build-rootfs.sh first)"
[ -r "$KERNEL_TGZ" ] || die "kernel archive $KERNEL_TGZ not found"
grep -q enabled /proc/sys/fs/binfmt_misc/qemu-ppc 2>/dev/null || die "qemu-ppc binfmt not enabled (see build-rootfs.sh)"

cleanup() {
	for m in dev/pts dev sys proc; do
		mountpoint -q "$TARGET/$m" && umount -l "$TARGET/$m" || true
	done
}
trap 'rc=$?; cleanup; exit $rc' EXIT

echo "==== copy $SRC -> $TARGET"
cleanup
rm -rf "$TARGET"
cp -a "$SRC" "$TARGET"

echo "==== kernel $(basename "$KERNEL_TGZ")"
tmp=$(mktemp -d)
tar -xzf "$KERNEL_TGZ" -C "$tmp"
mkdir -p "$TARGET/boot" "$TARGET/usr/lib/modules"
cp "$tmp"/boot/* "$TARGET/boot/"
cp -a "$tmp"/lib/modules/* "$TARGET/usr/lib/modules/"
rm -rf "$tmp"

echo "==== system configuration"
echo "$HOSTNAME_MBL" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<-EOF
	127.0.0.1	localhost
	127.0.1.1	$HOSTNAME_MBL
EOF

cat > "$TARGET/etc/fstab" <<-'EOF'
	# <file system>	<mount point>	<type>	<options>		<dump>	<pass>
	# Layout of uboot/boot_multi: sda4 = this root, sda3 = swap (made with mkswap by a
	# 16K-page kernel), sda5 = data. Adjust to your disk.
	/dev/sda4	/		ext4	defaults,noatime	0	1
	/dev/sda3	none		swap	sw			0	0
	/dev/sda5	/DataVolume	ext4	rw,noatime,nofail,errors=remount-ro	0	2
	tmpfs		/tmp		tmpfs	defaults,size=100M	0	0
EOF
mkdir -p "$TARGET/DataVolume"

# UTF-8 without the locales package: C.UTF-8 is built into glibc (otherwise mc/ls show ???)
echo 'LANG=C.UTF-8' > "$TARGET/etc/default/locale"
echo 'export LANG=C.UTF-8' > "$TARGET/etc/profile.d/locale.sh"

# DHCP on eth0 (from build-rootfs.sh); resolv.conf is written by dhcpcd
: > "$TARGET/etc/resolv.conf"

# u-boot environment as seen by the 4.19 kernel (mtd0 = 120K free + 2 x 4K env)
cat > "$TARGET/etc/fw_env.config" <<-'EOF'
	# MTD device	Offset		Env size	Sector size	Sectors
	/dev/mtd0	0x1e000		0x1000		0x1000		1
	/dev/mtd0	0x1f000		0x1000		0x1000		1
EOF

# This kernel panics on a hung task or soft lockup. The multiboot bootargs already
# set panic=10; keep the reboot timeout here too for other boot scripts.
mkdir -p "$TARGET/etc/sysctl.d"
cat > "$TARGET/etc/sysctl.d/90-mbl-hang-recovery.conf" <<-'EOF'
	kernel.hung_task_timeout_secs = 180
	kernel.hung_task_panic = 1
	kernel.softlockup_panic = 1
	kernel.panic = 10
EOF

# Host keys are removed below; dropbear -R creates unique ones on the first connection
if grep -q '^DROPBEAR_EXTRA_ARGS=' "$TARGET/etc/default/dropbear" 2>/dev/null; then
	sed -i 's/^DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS="-R"/' "$TARGET/etc/default/dropbear"
else
	echo 'DROPBEAR_EXTRA_ARGS="-R"' >> "$TARGET/etc/default/dropbear"
fi

install -m 755 "$REPO/uboot/boot_multi/mbl-boot" "$TARGET/usr/sbin/mbl-boot"
cat > "$TARGET/etc/rc.local" <<-'EOF'
	#!/bin/sh
	# With uboot/boot_multi: confirm the boot only once SSH answers, otherwise reboot after
	# 2 minutes (boot.scr switches system after two failed boots). Uncomment to enable.
	#/usr/sbin/mbl-boot confirm-ssh 120 </dev/null >/dev/null 2>&1 &
	exit 0
EOF
chmod 755 "$TARGET/etc/rc.local"

install -m 755 "$HERE/mbl-led" "$TARGET/usr/local/sbin/mbl-led"
install -m 755 "$HERE/mbl-led.init" "$TARGET/etc/init.d/mbl-led"
install -m 755 "$HERE/wsdd2.init" "$TARGET/etc/init.d/wsdd2"

cp "$TARGET/etc/samba/smb.conf" "$TARGET/etc/samba/smb.conf.debian-default"
install -m 644 "$REPO/samba/smb-sid.conf" "$TARGET/etc/samba/smb.conf"

echo "==== services and root password"
mount -t proc proc "$TARGET/proc"
mount -t sysfs sys "$TARGET/sys"
mount --bind /dev "$TARGET/dev"
mount --bind /dev/pts "$TARGET/dev/pts"
for s in mbl-led wsdd2 rc.local; do
	chroot "$TARGET" update-rc.d "$s" defaults >/dev/null
done
echo "root:$ROOT_PASSWORD" | chroot "$TARGET" chpasswd
chroot "$TARGET" depmod -a "$(ls "$TARGET/usr/lib/modules" | head -1)" 2>/dev/null || true
cleanup

echo "==== remove personal and generated state"
rm -rf "$TARGET/root/.ssh" "$TARGET"/root/.*_history "$TARGET"/etc/dropbear/dropbear_*_host_key*
rm -f "$TARGET"/etc/ssh/ssh_host_*
: > "$TARGET/etc/machine-id"
rm -f "$TARGET/var/lib/dbus/machine-id"
find "$TARGET/var/log" -type f -exec truncate -s 0 {} +
rm -rf "$TARGET"/var/lib/apt/lists/* "$TARGET"/var/cache/apt/*.bin "$TARGET"/tmp/* "$TARGET"/var/tmp/*

echo "==== checks"
[ -z "$(ls "$TARGET/etc/dropbear/"*host_key* 2>/dev/null)" ] || die "host keys left"
[ ! -e "$TARGET/root/.ssh" ] || die "/root/.ssh left"
grep -q '^DROPBEAR_EXTRA_ARGS="-R"' "$TARGET/etc/default/dropbear" || die "dropbear -R not set"
ls "$TARGET/etc/rc2.d" | tr '\n' ' '; echo

echo "==== pack $OUT"
tar --numeric-owner --xattrs -C "$TARGET" -cpf - . | xz -T0 -6 > "$OUT"
ls -lh "$OUT"
