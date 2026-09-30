#!/usr/bin/env python3
"""Build a u-boot legacy script image (boot.scr) without mkimage.

Equivalent to: mkimage -A powerpc -O linux -T script -C none -a 0 -e 0 -n 'Execute uImage' -d in.txt out.scr

    python3 mkscr.py boot_multi.txt boot.scr
    python3 mkscr.py --check existing.scr      # verify header and data CRCs, print the script
"""
import struct
import sys
import time
import zlib

MAGIC = 0x27051956
IH_OS_LINUX, IH_ARCH_PPC, IH_TYPE_SCRIPT, IH_COMP_NONE = 5, 7, 6, 0


def build(script: bytes, name: bytes = b'Execute uImage', timestamp=None) -> bytes:
    # Script images are "multi-file": a zero-terminated list of lengths, then the data
    data = struct.pack('>II', len(script), 0) + script
    header = struct.pack('>IIIIIIIBBBB32s', MAGIC, 0, int(timestamp or time.time()), len(data),
                         0, 0, zlib.crc32(data), IH_OS_LINUX, IH_ARCH_PPC, IH_TYPE_SCRIPT,
                         IH_COMP_NONE, name)
    hcrc = zlib.crc32(header)
    return header[:4] + struct.pack('>I', hcrc) + header[8:] + data


def check(image: bytes) -> bytes:
    magic, hcrc, ts, size, load, ep, dcrc, os_, arch, typ, comp, name = \
        struct.unpack('>IIIIIIIBBBB32s', image[:64])
    assert magic == MAGIC, 'bad magic'
    assert zlib.crc32(image[:4] + b'\0' * 4 + image[8:64]) == hcrc, 'bad header crc'
    data = image[64:64 + size]
    assert len(data) == size and zlib.crc32(data) == dcrc, 'bad data crc'
    assert (os_, arch, typ, comp) == (IH_OS_LINUX, IH_ARCH_PPC, IH_TYPE_SCRIPT, IH_COMP_NONE), 'not a ppc script'
    length = struct.unpack('>I', data[:4])[0]
    return data[8:8 + length]


if __name__ == '__main__':
    if sys.argv[1] == '--check':
        sys.stdout.write(check(open(sys.argv[2], 'rb').read()).decode())
    else:
        # u-boot's hush parser wants LF line endings
        text = open(sys.argv[1], 'rb').read().replace(b'\r\n', b'\n')
        open(sys.argv[2], 'wb').write(build(text))
        check(open(sys.argv[2], 'rb').read())
        print(f'{sys.argv[2]}: {len(text)} bytes of script, CRCs ok')
