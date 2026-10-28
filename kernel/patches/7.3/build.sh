#!/bin/bash
# Build 7.3.0-mbl-73r1-slim from the v7.3 tree plus the numbered series.
# Run in WSL Ubuntu as root; requires powerpc-linux-gnu-gcc-12, flex, bison,
# libssl-dev, libelf-dev and the wt-7.3-port worktree of /root/k419/linux.
set -euo pipefail

repo=/mnt/c/GitHub/My-Book-Live/kernel/patches/7.3
tree=/root/k419/wt-7.3-port
base=091b06388b117fefdcb63336ac09956a4914b961  # v7.3
release=7.3.0-mbl-73r1-slim

cd "$tree"
git reset --hard -q "$base"
git clean -fdq

# git apply tolerates both git-style and quilt-style patches; the 73r1
# series applies cleanly in sequence (see README).
for patch in "$repo"/patches/0*.patch; do
    git apply "$patch"
done

cp "$repo/config/.config.7.3-mbl-73r1-slim" "$tree/.config"

mk=(make -C "$tree" ARCH=powerpc CROSS_COMPILE=powerpc-linux-gnu-
    CC=powerpc-linux-gnu-gcc-12 LOCALVERSION= -j8)
"${mk[@]}" olddefconfig
"${mk[@]}" uImage modules

stage=/root/stage-73r1
rm -rf "$stage"
"${mk[@]}" INSTALL_MOD_PATH="$stage" INSTALL_MOD_STRIP=1 modules_install
for link in build source; do
    test ! -L "$stage/lib/modules/$release/$link" || unlink "$stage/lib/modules/$release/$link"
done

deploy=/root/deploy-73r1-slim-pkg
rm -rf "$deploy"
mkdir -p "$deploy"
cp "$tree/arch/powerpc/boot/uImage" "$tree/vmlinux" "$tree/System.map" "$tree/.config" "$deploy/"
cp /root/k419/deploy-6.18.58-mbl-p40/apollo3g.dtb "$deploy/apollo3g.dtb"
tar -C "$stage/lib/modules" -czf "$deploy/modules-$release.tgz" "$release"
(cd "$deploy" && sha256sum uImage vmlinux System.map .config apollo3g.dtb "modules-$release.tgz" > SHA256SUMS)
cat "$deploy/SHA256SUMS"
echo "done: $deploy"
