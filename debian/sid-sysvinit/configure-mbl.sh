#!/bin/sh
# Optional, device-specific migration after unpacking the generic sid image. Run on the MBL
# from OpenWrt with the new root at $R and old Jessie files at $J. Do not run before packing
# a distributable image: this imports the old root password and SSH host keys.
#
#   R=/mnt/new J=/mnt/data/_mbl/jessie-extract sh configure-mbl.sh
set -e

R=${R:-/mnt/new}
J=${J:-/mnt/data/_mbl/jessie-extract}
IP=${IP:-192.168.7.4/24}
GW=${GW:-192.168.7.1}

[ -x "$R/sbin/init" ] || { echo "no rootfs at $R" >&2; exit 1; }
[ -d "$J/etc" ] || { echo "no Jessie files at $J" >&2; exit 1; }
[ -d "$R/usr/lib/modules/4.19.325-cip136-st20-mbl-p21" ] || { echo "GRO+WD patch-21 kernel modules missing from $R" >&2; exit 1; }
[ -x "$R/usr/sbin/mbl-boot" ] || { echo "mbl-boot missing from $R" >&2; exit 1; }

echo "== fstab (same layout as Jessie)"
cat > "$R/etc/fstab" <<EOF
# <file system>		<mount point>	<type>	<options>						<dump> <pass>
/dev/sda4		/		ext4	defaults,noatime					0 1
/dev/sda3		none		swap	sw							0 0
/dev/sda5		/DataVolume	ext4	rw,noatime,nofail,errors=remount-ro	0 2
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
cat > "$R/etc/rc.local" <<EOF
#!/bin/sh
# Confirm the boot to the multiboot script only once SSH really answers,
# otherwise reboot after 2 minutes (boot.scr switches system after two failed boots)
/usr/sbin/mbl-boot confirm-ssh 120 </dev/null >/dev/null 2>&1 &
exit 0
EOF
chmod 755 "$R/etc/rc.local"

echo "== checks"
ls "$R/etc/rc2.d" | grep -E 'rc.local|ssh|networking' || true
grep -E '^(root|share):' "$R/etc/group"
grep '^root:' "$R/etc/shadow" | cut -c1-12
echo "done"
