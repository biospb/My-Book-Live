# usage: fixed-placement-switch-kernel.sh <uImage> <md5>  - install into the test slot (bootsel=2) of mbl-boot
set -e
SRC="${1:?uImage}"; WANT="${2:?md5}"
mount /dev/sda1 /mnt/bootro
cd /mnt/bootro/boot/debian-test
[ "$(md5sum < "$SRC" | cut -c1-32)" = "$WANT" ] || { echo "src md5 bad"; cd /; umount /mnt/bootro; exit 1; }
cp "$SRC" uImage.new && sync && mv uImage.new uImage && sync
md5sum uImage
cd /; umount /mnt/bootro
fw_setenv boot_count 0; fw_setenv bootsel 2; fw_printenv bootsel boot_count
