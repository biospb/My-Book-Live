#!/bin/bash
# Build 6.18.58-mbl-p40-perf from the pinned source plus the numbered series.
# Run in WSL Ubuntu as root; requires powerpc-linux-gnu-gcc-12, flex, bison,
# libssl-dev, libelf-dev and a clean checkout of 2926d88bb7fc (v6.18.58).
set -euo pipefail

repo=/mnt/c/GitHub/My-Book-Live/kernel/patches/6.18.58
tree=/root/k419/wt-6.18.58-p40-build
base=2926d88bb7fc4608fd942453d929c39e4e5ec006
release=6.18.58-mbl-p40-perf

if test -d "$tree"; then
    echo "worktree $tree already exists" >&2
    exit 1
fi
git -C /root/k419/linux worktree add --detach "$tree" "$base"

for patch in 0001-powerpc-apollo3g-ocm \
             0002-emac-tso-coalescing-gro-ocm \
             0003-lib-iov_iter-bounded-pagecopy \
             0004-crypto-crypto4xx-trng-dtb-match \
             0005-dma-dw-apm821xx-descriptor-word-zeroing \
             0006-ata-sata_dwc-err-mask \
             0007-ata-sata_dwc-hardreset-terminate \
             0008-ata-sata_dwc-probe-activate-error \
             0009-dma-dw-apm821xx-channel-init-cache \
             0010-dma-dw-complete-all-held-lock \
             0011-skbuff-splice-inline \
             0012-emac-tx-batching-core \
             0012-emac-tx-batching-header \
             0013-emac-tx-napi-consume-skb \
             0014-block-inline-plug-header \
             0014-block-inline-plug-core \
             0015-tcp-nagle-inline \
             0016-powerpc-csum-partial-dcbt-prefetch; do
    git -C "$tree" apply "$repo/patches/$patch.patch"
done

cp "$repo/config/.config.6.18.58-mbl-p40-perf" "$tree/.config"

mk=(make -C "$tree" ARCH=powerpc CROSS_COMPILE=powerpc-linux-gnu-
    CC=powerpc-linux-gnu-gcc-12 LOCALVERSION= -j4)
"${mk[@]}" olddefconfig
"${mk[@]}" uImage modules

stage=/root/k419/stage-p40-pkg
rm -rf "$stage"
"${mk[@]}" INSTALL_MOD_PATH="$stage" INSTALL_MOD_STRIP=1 modules_install
for link in build source; do
    test ! -L "$stage/lib/modules/$release/$link" || unlink "$stage/lib/modules/$release/$link"
done

deploy=/root/k419/deploy-p40-pkg
rm -rf "$deploy"
mkdir -p "$deploy"
cp "$tree/arch/powerpc/boot/uImage" "$tree/vmlinux" "$tree/System.map" "$tree/.config" "$deploy/"
# The board DTB is the verified original apollo3g.dtb (SHA256 in README):
cp /root/k419/deploy-6.18.58-mbl-p40/apollo3g.dtb "$deploy/apollo3g.dtb"
tar -C "$stage/lib/modules" -czf "$deploy/modules-$release.tgz" "$release"
(cd "$deploy" && sha256sum uImage vmlinux System.map .config apollo3g.dtb "modules-$release.tgz" > SHA256SUMS)
cat "$deploy/SHA256SUMS"

# Precompiled archive in the standard boot/+lib/ layout (see kernel/precompiled):
pkg=/root/k419/precompiled-p40
rm -rf "$pkg"
mkdir -p "$pkg/boot" "$pkg/lib/modules"
cp "$deploy/uImage" "$pkg/boot/uImage_$release"
cp "$deploy/apollo3g.dtb" "$pkg/boot/apollo3g.dtb"
cp "$deploy/.config" "$pkg/boot/config-$release"
cp "$deploy/System.map" "$pkg/boot/System.map-$release"
tar -C "$stage/lib/modules" -cf "$pkg/lib/modules/modules.tar" "$release"
(cd "$pkg/lib/modules" && tar -xf modules.tar && rm modules.tar)
tar -C "$pkg" -czf /mnt/c/GitHub/My-Book-Live/kernel/precompiled/linux-6.18.58-mbl-p40-perf.tgz \
    boot lib
echo "precompiled archive refreshed"
echo "done: $deploy"


