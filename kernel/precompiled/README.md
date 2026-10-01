# Installing My-Book-Live pre-compiled kernels

## Before you install a different kernel ##
First, read up on how to enable a recovery kernel __[here](https://github.com/ewaldc/My-Book-Live/tree/master/uboot)__. A safe or recovery kernel allows for fail-back to a known, good kernel in case something goes wrong. 

## Which kernel to take ? ##

All kernels listed below here have survived a 96-hours torture test.  Other kernels posted versions are not fully validated (yet).  Anyhow, none of them are officially supported, so this is __always at your own risk__.
The only kernel that can be used with original WD software is 2.6.32.70.

## Validated kernels for use with OEM/original firmware ##
The only tested, pre-compiled kernel which is supported by Debian Lenny as included with the original firmware is 2.6.32.70.<br>
Install as follows (for MBL):
```
cd /
tar -xzf /tmp/kernel-2.6.32.70-ncq.tgz
mv /boot/uImage /boot/uImage.safe
cp /boot/uImage.2.6.32.70.64K_NCQ /boot/uImage
```

For MBL Duo use uImage.2.6.32.70.64K_NCQ_DUO.
There are no custom /boot/apollo3g.dtb files, the 2.6.32.70 kernel will use the original device tree files for ease of installation, both for duo and solo.
You will need to update `/etc/network/if-up.d/tuneperf` to use Jumbo packets or alternatively just delete it to use regular MTU of 1500.


## Validated kernels for use with custom images based on Debian Jessie ##
* 4.9.77: this kernel is part of the posted Debian Jessie 8.11 image and extremely stable
* 4.9.99: with netconsole
* 4.9.119_hdd_led: first kernel to include hard disk activity led patch, with netconsole. First 4.9.1xx kernel to have survived the 96 hour torture test due to a defect that was introduced probably in 4.9.10[1234]. 
* 4.9.135: streamlined config (e.g. less performance counters, more functions pushed to modules) resulting in smaller size kernel
* 4.9.149: comes in three configurations : optimized for space, optimized for performance which is ~400K larger and a version of the latter which includes IO accounting (allows to run `iotop`).  In practical use though there is not much performance difference...
* 4.19.99: high performance kernel released with patches

## Kernels for Debian sid (2026) ##
Built with gcc 12 from the series in [../patches/4.19.325-cip136](../patches/4.19.325-cip136/README.md) and [../patches/4.19.325](../patches/4.19.325/README.md) (16K pages, like 4.19.99). Validated on a single-disk MBL with Debian sid + sysvinit, booted with `libata.force=noncq rng_core.default_quality=700`.
* __linux-4.19.325-cip136-st20-mbl-p21.tgz__ (latest): GRO and the `-wd` hang/soft-lockup protection below, plus SATA DMA fixes 0020/0021. The 16K-page patch-21 kernel was tested with SMB and local copy/hash checks. This package uses the matching NAS modules and the generic apollo3g device tree.
* __linux-4.19.325-cip136-st20-mbl-wd.tgz__: the -gro kernel below with hang protection: a task blocked in D state for 180 s (`hung_task_panic`) or a soft lockup panics, and `panic=10` reboots, so the multiboot fallback also covers a boot that hangs before SSH.
* __linux-4.19.325-cip136-st20-mbl-gro.tgz__: the cip136 kernel below plus patch 0019 (emac GRO), SMB write 61 -> 67 MB/s.
* __linux-4.19.325-cip136-st20-mbl.tgz__: CIP SLTS base with the audit fixes, SECCOMP, sock_diag, `/proc/config.gz`, gpio LEDs, POSIX ACLs, crypto4xx TRNG, statx mount-id backport.
* __linux-4.19.325-mbl.tgz__: the same on the last kernel.org 4.19 release, without the CIP fixes and without patches 0017/0018 of the CIP series.

Each archive contains `boot/uImage_<release>`, `boot/apollo3g.dtb` (= `../dts/apollo3g.dtb`), `boot/config-<release>` and `lib/modules/<release>`. Use `tar -xzf` from `/` and point u-boot at the uImage (see [../../uboot/boot_multi](../../uboot/boot_multi/README.md)).

## Installing pre-build kernels on Debian Jessie ##
All posted kernels are compressed tar archives with [7zip](https://www.7-zip.org/) and contain:
* /boot/apollo3g.dtb:  compiled device tree compatible with kernel
* /boot/uImage_4.9.xx: compiled/compressed kernel
* /lib/modules/4.9.xx: compiled kernel modules

First, __make sure you have a backup__ of your current `/boot/apollo3g.dtb` and kernel `/boot/uImage`.<br>
Or, better, enable recovery kernels and move your working kernel and dtb file to `/boot/uImage.safe` and `/boot/apollo3g.safe.dtb` (or `/boot/apollo3g_duo.safe.dtb` for MBL DUO).
Copy the uncompressed tar file to `/tmp` of My Book Live, extract the archive, enable the new kernel and reboot:<br>
```
cd /
tar -xzf /tmp/linux-4.9.135.tgz
cp /boot/uImage_4.9.135 /boot/uImage
systemctl reboot
```

Please note that the __swap space must match the kernel block size__. So, if the new kernel has a different page size than the previous one, you need to re-initialize swap space.  Assuming the standard MBL disk layout, swap space is on `/dev/sda3`.  The `mkswap` command will read the kernel page size, so no need to pass the `--pagesize` option.  Since 4.9.x and 4.19.x have different page sizes (for now), 64K and 16K respectively, this issue will arise as you swap kernels.

```
mkswap /dev/sda3
```
