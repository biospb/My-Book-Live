# My-Book-Live kernels

## Tree structure ##

- __dts__: Device Tree Structure files compatible with posted kernels/patch sources and how to build them
- __patches__: per-version patch series and build instructions —
  [4.19.325-cip136](patches/4.19.325-cip136/README.md) is the current
  production kernel (p22), [6.18.58](patches/6.18.58/README.md) is the
  experimental October 2026 port (p40)
- __precompiled__: install pre-compiled kernels — the easy way...
- __diagnostics__: kernel-side diagnostic experiments (pagecopy, OCM, ext4 writeback, sata-sg, p22 build validation)
- __cross-compilation__: compiling a MBL (powerpc 32-bit) kernel on a x86 64-bit Intel/AMD Linux system

DO NOT TEST THIS WITHOUT ABILITY TO TAKE YOUR DRIVE OUT AND HOOK TO A LINUX SYSTEM
