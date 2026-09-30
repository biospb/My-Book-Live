set -u
cd /root/k419/wt-cip136
MK="make ARCH=powerpc CROSS_COMPILE=powerpc-linux-gnu- CC=powerpc-linux-gnu-gcc-12 LOCALVERSION= -j8"
OUT=/root/k419/out-cip; mkdir -p $OUT
ls localversion* 2>/dev/null && cat localversion*
cp /root/k419/wt-v4.19.325/.config .config
$MK olddefconfig > $OUT/olddefconfig.log 2>&1
diff <(grep ^CONFIG /root/k419/wt-v4.19.325/.config) <(grep ^CONFIG .config)
echo "==== build started $(date +%T)"
$MK uImage modules > $OUT/build.log 2>&1; rc=$?
echo "==== build finished $(date +%T) rc=$rc"
grep -nE "error:|Error [0-9]|undefined reference" $OUT/build.log | head -20
grep "warning:" $OUT/build.log | grep -v boot/main.c | head
cat include/config/kernel.release
[ $rc = 0 ] || exit $rc
rm -rf /root/k419/stage-cip
$MK INSTALL_MOD_PATH=/root/k419/stage-cip INSTALL_MOD_STRIP=1 modules_install >/dev/null
R=$(cat include/config/kernel.release)
rm -f /root/k419/stage-cip/lib/modules/$R/build /root/k419/stage-cip/lib/modules/$R/source
D=/mnt/c/tmp/k419/deploy-cip; rm -rf $D; mkdir -p $D
cp arch/powerpc/boot/uImage .config System.map $D/
tar -C /root/k419/stage-cip/lib/modules -czf $D/modules-$R.tgz $R
ls -la $D
