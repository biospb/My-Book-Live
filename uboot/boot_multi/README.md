# Multiboot with automatic fallback

u-boot 2009.08 on the MBL runs `/boot/boot.scr` from the first partition. This script picks one of
several systems from the u-boot variable `bootsel` and falls back to another system when a boot
is not confirmed.

## Disk layout used

| Partition | Content |
|---|---|
| sda1 12M ext2 | `/boot/boot.scr`, kernels in `/boot/debian`, `/boot/owrt`, `/boot/debian-test` (uImage + apollo3g.dtb each) |
| sda2 | OpenWrt 25.12 (rescue system) |
| sda3 | swap |
| sda4 | Debian sid (root of both `debian` and `debian-test`) |
| sda5 | data |

sda1 has no journal: u-boot reads it as ext2, and three kernels only fit without it.

## Slots

| bootsel | osdir | root |
|---|---|---|
| 0 | debian | sda4 (4.19.325-cip136-mbl) |
| 1 | owrt | sda2 |
| 2 | debian-test | sda4 with another kernel; falls back to 0 |

## Fallback

`boot_count` is incremented on every boot and reset by the booted system once it is usable.
After two unconfirmed boots the script switches with `flip_<bootsel>` (0 -> 1, 1 -> 0, 2 -> 0).
If a kernel cannot be loaded it switches immediately.

Both systems start `mbl-boot confirm-ssh 120` from rc.local.
- If the local SSH server sends its banner, `boot_count` is set to 0.
- Otherwise the system reboots.
- While `/etc/mbl-boot.noconfirm` exists, the count is not reset, which is useful while a system is being set up.

u-boot and kernel messages go to netconsole: u-boot to UDP 6666 and the kernel to UDP 6664 on 192.168.7.36. Adjust `ipaddr`, `ncip` and `ncmac` in the script.

## Files

- `boot_multi.txt`: the script source; build it with `python3 ../mkscr.py boot_multi.txt boot.scr`. [../mkscr.py](../mkscr.py) makes u-boot legacy script images without mkimage; use `--check file` to verify one.
- `mbl-boot`: goes in `/usr/sbin` on every system. It needs `fw_printenv`/`fw_setenv`: libubootenv-tool on Debian, with `/etc/fw_env.config` set to `/dev/mtd0 0x1e000 0x1000` and `/dev/mtd0 0x1f000 0x1000` on 4.19.

      mbl-boot                    show bootsel / boot_count
      mbl-boot debian|owrt|test   select the next system (add "now" to reboot)
      mbl-boot confirm-ssh [sec]  confirm the boot once SSH answers, else reboot
      mbl-boot ok                 confirm without checking

  `mbl-boot` refuses to write when the environment cannot be read. A wrong `fw_env.config` would otherwise make `fw_setenv` replace the whole u-boot environment with its defaults.
