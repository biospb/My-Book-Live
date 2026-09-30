#!/bin/bash
# Build a Debian sid (debian-ports, powerpc) root filesystem for the WD My Book Live
# that boots with sysvinit instead of systemd, for use with the ewaldc 4.19.99 kernel
# (systemd >= 258 requires kernel >= 5.4 and no longer supports cgroup v1).
#
# Run as root on a disposable x86 Debian/Ubuntu system (e.g. a spare WSL distro):
#   sudo ./build-rootfs.sh [path/to/ssh-public-key]
#
# Optional environment:
#   WORK=/root/mbl-build   build directory (must be on a Linux filesystem, not /mnt/c)
#   HOSTNAME_MBL=wd        hostname
#   ROOT_PASSWORD=debian   root password
#   NET_ADDR=192.168.1.10/24 NET_GW=192.168.1.1 NET_DNS=192.168.1.1   static IP (default: DHCP)
#
# Result: $WORK/rootfs-sid-sysv-<date>.tgz, to be unpacked onto the new root partition.

set -euo pipefail

WORK=${WORK:-/root/mbl-build}
TARGET=$WORK/rootfs
MIRROR=${MIRROR:-http://deb.debian.org/debian-ports}
SUITE=unstable
HOSTNAME_MBL=${HOSTNAME_MBL:-wd}
ROOT_PASSWORD=${ROOT_PASSWORD:-debian}
PUBKEY=${1:-}
OUT=$WORK/rootfs-sid-sysv-$(date +%Y%m%d).tgz
KEYRING=/usr/share/keyrings/debian-ports-archive-keyring.gpg

# No udev: the 4.19 kernel has DEVTMPFS_MOUNT. No IPv6: disabled in the 4.19 config.
# No openssh-server: OpenSSH >= 10 requires seccomp for its preauth sandbox and the 4.19 kernel
# is built without CONFIG_SECCOMP, so every login fails; dropbear does not need it.
PACKAGES="sysvinit-core sysv-rc initscripts orphan-sysvinit-scripts \
	systemd-standalone-sysusers systemd-standalone-tmpfiles \
	ifupdown dhcpcd-base iproute2 iputils-ping netbase \
	dropbear openssh-sftp-server openssh-client samba nfs-kernel-server rpcbind \
	smartmontools hdparm e2fsprogs cron chrony rsyslog logrotate \
	less vim-tiny htop procps psmisc ethtool iperf3 wget ca-certificates \
	u-boot-tools libubootenv-tool debian-ports-archive-keyring"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
case "$WORK" in /mnt/*) die "WORK must be on a Linux filesystem, not $WORK";; esac
[ -z "$PUBKEY" ] || [ -r "$PUBKEY" ] || die "cannot read ssh public key $PUBKEY"

echo "==== Host tools"
apt-get update
apt-get install -y debootstrap qemu-user-static binfmt-support wget
apt-get install -y debian-ports-archive-keyring || true
# Distribution keyrings lag behind the debian-ports signing key: take the newest one from Debian
KEYRING_POOL=http://deb.debian.org/debian/pool/main/d/debian-ports-archive-keyring
KEYRING_DEB=$(wget -qO- "$KEYRING_POOL/" |
	grep -o 'debian-ports-archive-keyring_[0-9.]*_all\.deb' | sort -uV | tail -1) || true
if [ -n "$KEYRING_DEB" ] && wget -qO "/tmp/$KEYRING_DEB" "$KEYRING_POOL/$KEYRING_DEB"; then
	dpkg -i "/tmp/$KEYRING_DEB"
else
	echo "WARNING: could not fetch the latest debian-ports keyring"
fi

# WSL usually runs without systemd-binfmt, so register qemu-ppc by hand if needed.
# Note: binfmt_misc is shared by all WSL distros until 'wsl --shutdown'.
[ -d /proc/sys/fs/binfmt_misc ] || die "binfmt_misc not available"
mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-ppc ]; then
	update-binfmts --enable qemu-ppc 2>/dev/null || true
fi
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-ppc ]; then
	QEMU_PPC=$(command -v qemu-ppc-static || true)
	[ -n "$QEMU_PPC" ] || die "qemu-ppc-static not found"
	echo ":qemu-ppc:M::\x7fELF\x01\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x14:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:$QEMU_PPC:F" \
		> /proc/sys/fs/binfmt_misc/register
fi
grep -q enabled /proc/sys/fs/binfmt_misc/qemu-ppc || die "qemu-ppc binfmt is not enabled"

cleanup() {
	for m in dev/pts dev sys proc; do
		mountpoint -q "$TARGET/$m" && umount -l "$TARGET/$m" || true
	done
}
trap 'rc=$?; cleanup; exit $rc' EXIT

echo "==== debootstrap $SUITE (powerpc) into $TARGET"
cleanup
rm -rf "$TARGET"
mkdir -p "$TARGET"
if [ -r "$KEYRING" ]; then
	GPG_OPT="--keyring=$KEYRING"
else
	echo "WARNING: debian-ports keyring not found on host, skipping signature check"
	GPG_OPT="--no-check-gpg"
fi
# minbase leaves out the 'init' package, so systemd-sysv never gets pulled in
debootstrap --arch=powerpc --variant=minbase $GPG_OPT \
	--include=ca-certificates,debian-ports-archive-keyring \
	"$SUITE" "$TARGET" "$MIRROR"

mount -t proc proc "$TARGET/proc"
mount -t sysfs sys "$TARGET/sys"
mount --bind /dev "$TARGET/dev"
mount --bind /dev/pts "$TARGET/dev/pts"

echo "==== apt configuration"
cat > "$TARGET/etc/apt/sources.list" <<-EOF
	deb $MIRROR unstable main
	deb $MIRROR unreleased main
EOF
cat > "$TARGET/etc/apt/preferences.d/00-no-systemd-init" <<-EOF
	# PID 1 must stay sysvinit: systemd >= 258 does not run on kernel 4.19.
	# systemd itself is not needed either (sysusers/tmpfiles come from the standalone packages).
	Package: systemd systemd-sysv
	Pin: release *
	Pin-Priority: -1
EOF
cat > "$TARGET/etc/apt/apt.conf.d/90-mbl" <<-EOF
	APT::Install-Recommends "false";
	Acquire::Languages "none";
EOF
# Do not start services inside the chroot
printf '#!/bin/sh\nexit 101\n' > "$TARGET/usr/sbin/policy-rc.d"
chmod 755 "$TARGET/usr/sbin/policy-rc.d"

echo "==== install packages"
chroot "$TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 \
	sh -c "apt-get update && apt-get install -y $PACKAGES"

echo "==== system configuration"
echo "$HOSTNAME_MBL" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<-EOF
	127.0.0.1	localhost
	127.0.1.1	$HOSTNAME_MBL
EOF

cat > "$TARGET/etc/fstab" <<-EOF
	# <file system>	<mount point>	<type>	<options>		<dump>	<pass>
	/dev/sda4	/		ext4	defaults,noatime	0	1
	/dev/sda5	/nfs		ext4	defaults,noatime	0	2
	/dev/sda3	none		swap	sw			0	0
	tmpfs		/tmp		tmpfs	defaults,size=100M	0	0
EOF
mkdir -p "$TARGET/nfs"

mkdir -p "$TARGET/etc/network/interfaces.d"
cat > "$TARGET/etc/network/interfaces" <<-EOF
	source /etc/network/interfaces.d/*
	auto lo
	iface lo inet loopback
EOF
if [ -n "${NET_ADDR:-}" ]; then
	cat > "$TARGET/etc/network/interfaces.d/eth0" <<-EOF
		auto eth0
		iface eth0 inet static
		    address $NET_ADDR
		    gateway ${NET_GW:?NET_GW is required with NET_ADDR}
	EOF
	echo "nameserver ${NET_DNS:-$NET_GW}" > "$TARGET/etc/resolv.conf"
else
	cat > "$TARGET/etc/network/interfaces.d/eth0" <<-EOF
		auto eth0
		iface eth0 inet dhcp
	EOF
	echo "ipv4only" >> "$TARGET/etc/dhcpcd.conf"
fi

# chrony's default seccomp filter (-F 1) is fatal on the 4.19 kernel without CONFIG_SECCOMP
sed -i 's/^DAEMON_OPTS="-F 1"/DAEMON_OPTS="-F 0"/' "$TARGET/etc/default/chrony"

# No virtual consoles on the MBL: replace tty getty's with a serial one
sed -i -E 's/^([1-6]:[0-9]+:respawn:)/#\1/' "$TARGET/etc/inittab"
grep -q '^T0:' "$TARGET/etc/inittab" ||
	echo 'T0:23:respawn:/sbin/getty -L ttyS0 115200 vt100' >> "$TARGET/etc/inittab"

# SSH (dropbear): key login if a key was given; root password login stays allowed
if [ -n "$PUBKEY" ]; then
	install -d -m 700 "$TARGET/root/.ssh"
	install -m 600 "$PUBKEY" "$TARGET/root/.ssh/authorized_keys"
fi
echo "root:$ROOT_PASSWORD" | chroot "$TARGET" chpasswd

echo "==== cleanup"
rm -f "$TARGET/usr/sbin/policy-rc.d"
chroot "$TARGET" apt-get clean
rm -rf "$TARGET"/var/lib/apt/lists/* "$TARGET"/tmp/* "$TARGET"/var/tmp/*
cleanup

echo "==== sanity check"
[ -L "$TARGET/sbin/init" ] || [ -x "$TARGET/sbin/init" ] || die "no /sbin/init"
readlink -f "$TARGET/sbin/init"
chroot "$TARGET" dpkg-query -W -f='${Package} ${Version}\n' sysvinit-core samba dropbear libc6 2>/dev/null || true
for p in systemd systemd-sysv; do
	if chroot "$TARGET" dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed'; then
		die "$p got installed"
	fi
done

echo "==== pack $OUT"
tar --numeric-owner --xattrs -C "$TARGET" -czpf "$OUT" .
ls -lh "$OUT"
