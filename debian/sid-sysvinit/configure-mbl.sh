#!/bin/sh
# Configure the unpacked sid rootfs for this My Book Live. Runs on the MBL itself (from OpenWrt),
# with the new root mounted at $R and the needed files from the old Jessie root extracted to $J.
#
#   R=/mnt/new J=/mnt/data/_mbl/jessie-extract sh configure-mbl.sh
set -e

R=${R:-/mnt/new}
J=${J:-/mnt/data/_mbl/jessie-extract}
IP=${IP:-192.168.7.4/24}
GW=${GW:-192.168.7.1}
MBL_BOOT=${MBL_BOOT:-/usr/sbin/mbl-boot}

[ -x "$R/sbin/init" ] || { echo "no rootfs at $R" >&2; exit 1; }
[ -d "$J/etc" ] || { echo "no Jessie files at $J" >&2; exit 1; }

echo "== kernel modules 4.19.99 (tun, loop + indexes; the rest is built into uImage)"
mkdir -p "$R/usr/lib/modules"
cp -a "$J/lib/modules/4.19.99" "$R/usr/lib/modules/"

echo "== fstab (same layout as Jessie)"
cat > "$R/etc/fstab" <<EOF
# <file system>		<mount point>	<type>	<options>						<dump> <pass>
/dev/sda4		/		ext4	defaults,noatime					0 1
/dev/sda3		none		swap	sw							0 0
/dev/sda5		/DataVolume	ext4	rw,noatime,data=writeback,barrier=0,errors=remount-ro	0 2
/DataVolume/cache	/CacheVolume	none	bind							0 0
/DataVolume/shares	/shares		none	bind							0 0
/DataVolume/shares	/nfs		none	bind							0 0
tmpfs			/tmp		tmpfs	rw,size=100M						0 0
EOF
mkdir -p "$R/DataVolume" "$R/CacheVolume" "$R/shares" "$R/nfs"

echo "== network: static $IP via $GW"
mkdir -p "$R/etc/network/interfaces.d"
cat > "$R/etc/network/interfaces.d/eth0" <<EOF
auto eth0
iface eth0 inet static
    address $IP
    gateway $GW
EOF
# The router's DNS answers NXDOMAIN for some Debian hosts
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$R/etc/resolv.conf"

echo "== root password and 'share' group from Jessie"
hash=$(awk -F: '$1 == "root" { print $2 }' "$J/etc/shadow")
if [ -n "$hash" ]; then
	awk -F: -v OFS=: -v h="$hash" '$1 == "root" { $2 = h } { print }' "$R/etc/shadow" > "$R/etc/shadow.new"
	cat "$R/etc/shadow.new" > "$R/etc/shadow" && rm "$R/etc/shadow.new"
fi
grep -q '^share:' "$R/etc/group" || grep '^share:' "$J/etc/group" >> "$R/etc/group"

echo "== ssh (dropbear): keep the Jessie host keys so clients see the same fingerprint"
mkdir -p "$R/tmp/jkeys"
for k in ed25519 rsa ecdsa; do
	[ -f "$J/etc/ssh/ssh_host_${k}_key" ] || continue
	cp "$J/etc/ssh/ssh_host_${k}_key" "$R/tmp/jkeys/"
	rm -f "$R/etc/dropbear/dropbear_${k}_host_key"
	chroot "$R" dropbearconvert openssh dropbear "/tmp/jkeys/ssh_host_${k}_key" "/etc/dropbear/dropbear_${k}_host_key"
done
rm -rf "$R/tmp/jkeys"
chmod 600 "$R"/etc/dropbear/dropbear_*_host_key

echo "== u-boot environment (kernel 4.19: mtd0 = 120K free + 8K env) and multiboot helper"
cat > "$R/etc/fw_env.config" <<EOF
# MTD device	Offset		Env size	Sector size	Sectors
/dev/mtd0	0x1e000		0x1000		0x1000		1
/dev/mtd0	0x1f000		0x1000		0x1000		1
EOF
cp "$MBL_BOOT" "$R/usr/sbin/mbl-boot"
chmod 755 "$R/usr/sbin/mbl-boot"
cat > "$R/etc/rc.local" <<EOF
#!/bin/sh
# Confirm the boot to the multiboot script only once SSH really answers,
# otherwise reboot after 2 minutes (boot.scr switches system after two failed boots)
/usr/sbin/mbl-boot confirm-ssh 120 </dev/null >/dev/null 2>&1 &
exit 0
EOF
chmod 755 "$R/etc/rc.local"

echo "== old Jessie configs for reference in /root/jessie-etc"
mkdir -p "$R/root/jessie-etc"
cp -a "$J/etc/samba" "$J/etc/exports" "$J/etc/crontab" "$R/root/jessie-etc/"

echo "== checks"
ls "$R/etc/rc2.d" | grep -E 'rc.local|ssh|networking' || true
grep -E '^(root|share):' "$R/etc/group"
grep '^root:' "$R/etc/shadow" | cut -c1-12
echo "done"
