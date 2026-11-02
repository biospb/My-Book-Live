set -u
# Build from a clean CIP v5.10.271-cip78 checkout with patches/0001-0020 applied (git am patches/*.patch).
cd /root/k419/wt-510series
MK="make ARCH=powerpc CROSS_COMPILE=powerpc-linux-gnu- CC=powerpc-linux-gnu-gcc-12 LOCALVERSION= -j8"
echo "-mbl-510r5" > localversion-mbl
cp /mnt/c/GitHub/My-Book-Live/kernel/patches/5.10.271-cip78/config/.config.5.10.271-cip78-mbl-510r5 .config
$MK olddefconfig >/dev/null
$MK uImage modules > /root/k419/out-510series.log 2>&1 || { grep -nE "error:|Error [0-9]" /root/k419/out-510series.log | head; exit 1; }
R=$(cat include/config/kernel.release); echo "$R"
rm -rf /root/k419/stage-510series
$MK INSTALL_MOD_PATH=/root/k419/stage-510series INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f /root/k419/stage-510series/lib/modules/$R/build /root/k419/stage-510series/lib/modules/$R/source
D=/mnt/c/tmp/k419/deploy-510series; rm -rf $D; mkdir -p $D
cp arch/powerpc/boot/uImage .config System.map $D/
tar -C /root/k419/stage-510series/lib/modules -czf $D/modules-$R.tgz $R
md5sum $D/uImage
