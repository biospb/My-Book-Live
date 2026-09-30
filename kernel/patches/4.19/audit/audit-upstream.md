# Аудит: 4.19.99 → 4.19.325 для WD My Book Live (APM82181 / PPC464, 16K pages, sata_dwc + dw_dmac, EMAC4, Debian sid)

Дата: 2026-09-30. Входные данные: `log-{storage,net,powerpc,ext4}.txt`, `apply-v4.19.{99,325}.txt`, исходники в `C:\tmp\k419\*`, патчи ewaldc (`C:\GitHub\My-Book-Live\kernel\patches\4.19\patches`), конфиг `.config.4.19` (сгенерирован для 4.19.34, `CONFIG_GCC_VERSION=80300`).
Патчи хранилища (994–997, 002) и сети (990–993) в деталях разбирают другие агенты. Здесь о них только то, что касается upstream-коммитов, с которыми они пересекаются.

---

## 0. Коротко

* **Переходить на 4.19.325 стоит.** Между .99 и .325 около 225 стабильных релизов. В них много исправлений ext4/jbd2 (включая metadata_csum и повреждение журнала), исправление OOB-записи прямо в `sata_dwc_460ex`, удалённо эксплуатируемые исправления TCP и совместимость с новыми gcc/binutils/make. Перенести (rebase) 5 падающих патчей проще и надёжнее, чем вручную бэкпортировать 30–60 коммитов в 4.19.99.
* Из пяти падающих патчей `201-extra_optimization` чинится одной строкой. У 990/992/994/996 конфликтуют по 1–3 hunk'а, и конфликты ожидаемые: upstream сам изменил те же места (например, прототип `qc_prep`, `SATA_DWC_QCMD_MAX`).
* Мелкие OpenWrt-патчи: ~7 из них для MBL бесполезны (WNDR4700, xhci, tc654, GPIO-export, phy update_link), их лучше **выбросить**. Патчи под размер модулей (202/204/207/321) тоже лучше выбросить: 321 потенциально опасен при сборке новым gcc.
* В конфиге есть реальные функциональные дыры для Samba/NFS: **нет `EXT4_FS_POSIX_ACL`** (Samba не может отобразить NT ACL в POSIX ACL, `NFSD_V3_ACL` бесполезен), нет `EXT4_FS_SECURITY`, нет `SECCOMP` (под вопросом chrony `-F 1`), нет `INET_DIAG`/`UNIX_DIAG`. Кроме того, `PROC_STRIPPED` из патча 902 выключает все SNMP-счётчики и `/proc/net/{snmp,netstat,sockstat}`.
* Тулчейн: 4.19.325 заметно дружелюбнее к gcc 12–14 и binutils 2.39+, чем .99. В обоих случаях нужно выключить `CONFIG_PPC_WERROR`. Самый безопасный вариант — gcc 12 (cross из Debian bookworm) или bootlin `powerpc-440fp`. gcc 14 для 4.19 никем официально не тестировался (не проверено).
* Стратегически: 4.19 — EOL. Чтобы и дальше получать исправления, базой после .325 можно взять **CIP SLTS `linux-4.19.y-cip`** (поддержка до ~2029 г.). Альтернатива — mainline/LTS 6.x по пути chunkeey (`c:\GitHub\mbl-debian-chunkeey`), но без perf-патчей ewaldc.

---

## 1. Ограничения материала (важно)

1. Логи отфильтрованы по путям. **В них нет** `fs/nfsd`, `net/sunrpc`, `fs/lockd`, `mm/` (кроме memory_hotplug), общего VFS (`fs/*.c`), `kernel/`, `crypto/`, `drivers/char/random.c`, `net/ipv4` вне TCP (udp/icmp/igmp/ip_fragment), `net/unix`, `net/packet`, `drivers/mtd/*` (кроме maps), `drivers/dma/dw` (кроме Kconfig). Поэтому пункты про NFS-сервер, random и VFS ниже основаны на общем знании, **без хешей**, и помечены как требующие проверки.
2. Номера версий 4.19.x для коммитов — **приблизительные**. Я оценивал их по позиции в логе и по памяти. Точный номер даёт `git describe --contains <hash>` в дереве linux-stable.
3. Хеши ниже взяты только из предоставленных логов.

Команда для закрытия пробелов (выполнить в linux-stable):
```sh
git log --oneline v4.19.99..v4.19.325 -- fs/nfsd net/sunrpc fs/lockd fs/nfs_common \
    mm fs/*.c fs/proc kernel/fork.c kernel/signal.c kernel/futex* drivers/char/random.c \
    net/ipv4 net/core net/unix net/packet drivers/crypto/amcc drivers/char/hw_random \
    drivers/mtd drivers/dma/dw drivers/net/ethernet/ibm/emac drivers/leds lib
```

---

## 2. Upstream-коммиты 4.19.99..4.19.325: что важно для MBL

Контекст использования: UP, PREEMPT_NONE, 256 МБ RAM (ENOMEM-пути реальны), 16K страниц при блоке ext4 4K (subpage-пути), SATA HDD без discard, ext4 с metadata_csum на 2.7 ТБ, Samba (много xattr `user.DOSATTRIB`), NFS-сервер, только IPv4, без netfilter/BPF-пользователей, SCSI идёт по legacy request path (`SCSI_MQ_DEFAULT` не задан), IO-планировщик deadline (не mq).

### 2.1 Must-have (потеря или повреждение данных, падение, удалённый вектор)

**Хранилище / драйверы этого железа**

| hash | subject | почему | ~когда |
|---|---|---|---|
| 596c7efd69aa | ata: sata_dwc_460ex: Fix crash due to OOB write | Прямо наш SATA-контроллер: OOB-запись в `sata_dwc_device_port` при тегах ≥ 32 (внутренние команды libata). Меняет `SATA_DWC_QCMD_MAX` на `ATA_MAX_QUEUE + 1`. **Пересекается с 996** (см. `diff-drivers-99-325.diff`) | ~конец 2022 (≈4.19.26x, не проверено) |
| c9a512f8fa91 + a34e3ce81dc8 | ata: make qc_prep return ata_completion_errors / ata: define AC_ERR_OK | Меняют прототип `->qc_prep`. Реализация `qc_prep` в `sata_dwc` (патч 996) обязана совпадать, иначе ошибка сборки или некорректная сигнатура | ≈2020 |
| 533ea843ed3c | block: only update parent bi_status when bio fail | Успешный дочерний bio мог затереть ошибку родителя, и ошибка ввода-вывода терялась молча | ≈2021 |
| e2b7e0a9b430 | ata: libata-eh: do not clear ATA_PFLAG_EH_PENDING in ata_eh_reset() | Гонка в EH: запрос EH мог потеряться, итог — зависание порта после ошибки диска | ≈2023 |
| 6a139c9ec508 | block: Fix fsync always failed if once failed | Корректность errseq для fsync блочного устройства | ≈2022 |

**ext4 / jbd2** (Samba/NFS-хранилище, metadata_csum)

| hash | subject | почему |
|---|---|---|
| bda71c14e115 | ext4: fix checksum errors with indexed dirs | **metadata_csum + htree**: ложные или реальные ошибки контрольных сумм каталогов → fs уходит в RO. Прямо наш случай (≈4.19.10x) |
| 6ffa768fe5cf | ext4: fix potential htree index checksum corruption | metadata_csum, повреждение индекса каталога |
| 7b97149296ef | ext4: fix invalid inode checksum | metadata_csum |
| 279520072427 | jbd2: fix potential data lost in recovering journal raced with synchronizing fs bdev | Потеря данных при replay журнала (после сбоя питания это реально) (≈2023) |
| 8d8a471188d1 | jbd2: clear JBD2_ABORT flag before journal_reset to update log tail info when load journal | Корректность загрузки журнала |
| 2a3cf3553ead, 056c7c22fcda | jbd2: do not clear the BH_Mapped flag when forgetting a metadata buffer / move the clearing of b_modified flag… | Классическая пара: возможное повреждение метаданных при checkpoint (≈4.19.10x) |
| 8eed535dada2 | jbd2: abort journal if free a async write error metadata buffer | Без неё после ошибки записи метаданных возможна тихая порча |
| 3b1a4ea0028a, 6073389db83b | jbd2: make sure jh have b_transaction set… / fix assertion 'jh->b_frozen_data == NULL'… | BUG_ON/падение при abort журнала |
| c9fc93e7a96c | ext4: do not zeroout extents beyond i_disksize | Некорректная размерность файла или утечка данных при zeroout |
| 98953044b3cd, efaa0ca678f5 | ext4: fix race when reusing xattr blocks / fix deadlock due to mbcache entry corruption | Samba активно пишет xattr: разделяемые xattr-блоки и mbcache. Порча xattr-блока или deadlock (≈4.19.27x) |
| 9ad75e78747b | ext4: fix mb_cache_entry's e_refcnt leak in ext4_xattr_block_cache_find() | Утечка (исправляет регрессию той же серии), важна для xattr-нагрузки |
| 30e7160bb4a9 | ext4: add reclaim checks to xattr code | Deadlock в reclaim: при 256 МБ это реальный сценарий |
| a0c3b0d44802, eea5a4e7fe44 | ext4: avoid ext4_error()'s caused by ENOMEM in the truncate path / fix inode tree inconsistency caused by ENOMEM | При нехватке памяти ФС уходила в ошибку/RO. Для 256 МБ актуально (≈2024) |
| d4574bda6390, e17ebe4fdd76, 393a46f60ea4, ec0c0beb9b77 | ext4: fix double brelse()… / avoid use-after-free in ext4_ext_insert_extent() / fix slab-use-after-free in ext4_split_extent_at() / update orig_path in ext4_find_extent() | UAF в путях split/insert extent (часть CVE 2024 г.). Срабатывают на ошибках и ENOMEM (≈4.19.32x) |
| 93fd249f197e, 330ecdae721e, 801a35dfef69 | ext4/jbd2: incorrect tid assumption… / stop waiting for space when jbd2_cleanup_journal_tail() returns error | Зависания при переполнении tid или ошибке журнала |
| 7f801a1593cb, 9d4b68c2c91b | ext4: fix use-after-free in ext4_orphan_cleanup / do not set SB_ACTIVE in ext4_orphan_cleanup() | Orphan cleanup после некорректного выключения |
| 6a6e04ce3baf, 1373f884a081 | ext4: eliminate bogus error in ext4_data_block_valid_rcu() / don't allow overlapping system zones | Ложные ошибки block_validity → ФС в RO |

Замечание про `orphan_file`: 4.19 эту фичу **не поддерживает** (появилась в 5.15). Это COMPAT-флаг, поэтому 4.19 молча монтирует ФС RW и использует старый orphan-список в суперблоке. RO_COMPAT `orphan_present` ставит только новое ядро. Значит, на 4.19 это безопасно, но фича просто не работает. Если ФС когда-либо монтировалась новым ядром и не была корректно размонтирована, 4.19 откажется монтировать её RW, пока не прогнать `e2fsck` (e2fsprogs 1.47 это умеет).

**TCP/IP (удалённые векторы; LAN-only снижает приоритет, но не обнуляет)**

| hash | subject | почему |
|---|---|---|
| 9bbde0825846 | tcp: do not leave dangling pointers in tp->highest_sack | UAF при обработке SACK, удалённо (≈4.19.10x) |
| 458f07ffeccd | tcp: do not accept ACK of bytes we never sent | Защита от blind in-window атак (≈4.19.30x) |
| 669c0b5782fb, 66fb76f3a8d7 | net: avoid 32 x truesize under-estimation for tiny skbs / skbuff: back tiny skbs with kmalloc()… | Недоучёт памяти для мелких пакетов → удалённое исчерпание памяти. При 256 МБ важно. **Может пересекаться с 991_skbuff_perf** (зона сетевого агента) |
| 633da7b30b24, 4d941fdf910b | tcp: fix indefinite deferral of RTO with SACK reneging / fix early ETIMEDOUT after spurious non-SACK RTO | Зависания или обрывы соединений по поведению пира |

Критичные сетевые CVE до .99 уже закрыты: **SACK Panic / SACK Slowness (CVE-2019-11477/11478/11479)** исправлены в ~4.19.52–4.19.54, FragmentSmack/SegmentSmack (2018) ещё раньше. В 4.19.99 их уже нет.

### 2.2 Nice-to-have

**powerpc (32-bit / 44x):**
* e2e9ffef0333 powerpc: Don't clobber f0/vs0 during fp|altivec register save. Затрагивает все ppc с FPU (`PPC_FPU=y`, Debian powerpc — hard-float). Upstream-триггер был io_uring. В 4.19 путь `save_fpu` без `giveup` вызывается в основном из fork (`flush_all_to_thread`), где f0 по ABI volatile. Поэтому практический риск в 4.19 **низкий (не проверено)**, но исправление маленькое и безопасное (≈4.19.30x).
* a0e38a2808ea powerpc/32: Fix overread/overwrite of thread_struct via ptrace. Локальная порча памяти ядра через PTRACE_PEEKUSR/POKEUSR на ppc32 с FPU. Локальная уязвимость (≈2022).
* 7d5de91a9ae5 exit: Add and use make_task_dead. Часть серии hardening «oops limit» (≈4.19.27x), локально.
* 473575d518b1 powerpc: Make setjmp/longjmp signature standard. Нужен для **gcc ≥ 10 при `PPC_WERROR=y`** (builtin-declaration-mismatch). См. раздел 5.
* 50aabfa4d88d powerpc/4xx: Don't unmap NULL mbase. Путь ошибки PCIe 4xx.
* 87f7ca041152 powerpc/4xx/cpm: Fix return value of __setup() handler. Косметика cmdline.
* 21e45a7b08d7 powerpc/mm: Fix null-pointer dereference in pgtable_cache_add. Только при ENOMEM на загрузке.
* c50ac26d5055 powerpc/32: add stack protector support. В .325 можно включить `STACKPROTECTOR_STRONG` на ppc32 (TLS guard в r2). Hardening. Зачем это бэкпортировали в 4.19.y, не проверял.
* Тулчейн-коммиты: e7e70b55af86 powerpc/dcr: Use cmplwi instead of 3-argument cmpli (DCR_NATIVE используется на 44x; нужен для новых ассемблеров, скорее всего в первую очередь LLVM IAS, не проверено), 7ad4e05c5e60 powerpc/32: Include .branch_lt in data section (orphan-секция в новых ld), 801ff5f45e76 powerpc: Remove linker flag from KBUILD_AFLAGS, 8dc842cd56b5 powerpc: Fix build error due to is_valid_bugaddr(), 4baa21a46e32 powerpc/mm: Switch obsolete dssall to .long (на 44x без ALTIVEC не компилируется, но безвредно).

**crypto4xx** (f848132a406b crypto: crypto4xx - Call dma_unmap_page when done; 1e6754c4b020 … Replace bitwise OR with logical OR in crypto4xx_build_pd). Полезны, но на MBL у crypto4xx практически нет пользователей в ядре: нет IPsec, dm-crypt, AF_ALG. Samba шифрует в userspace через GnuTLS. При этом в конфиге `CRYPTO_MANAGER_DISABLE_TESTS=y`: если драйвер сломан, никто этого не заметит. Разумный вариант — выключить `CRYPTO_DEV_PPC4XX` и оставить только `HW_RANDOM_PPC4XX` (TRNG).

**libata / block:**
* 61295b8cadb6 libata: if T_LENGTH is zero, dma direction should be DMA_NONE. Касается ATA passthrough (smartctl/hdparm через SG_IO) при DMA через dw_dmac.
* 11e6b688936b ata/libata: Fix usage of page address by page_address in ata_scsi_mode_select_xlat. Касается `sdparm --set WCE` и подобного.
* bf18a04bd0c5 libata: fix read log timeout value; 30ac5bf460d4 libata: fix checking of DMA state; 0dfadcf9e9e4 libata: fix ata_host_start(); 15402e0e8433 ata: libata: Fix sata_down_spd_limit() when no link speed is reported.
* 18243d8479fd block-map: add __GFP_ZERO flag for alloc_page in function bio_copy_kern. Инфо-утечка через SG_IO (CVE-2022-0494).
* 4c26ed04be9e ata: sata_dwc_460ex: No need to call phy_exit() befre phy_init(). Мелочь, пересекается с 996.
* 3d13ebbd0669, b0393aadc2d2, cc019421d037. Пересканирование разделов.

**ext4 (второй эшелон):** 38884609b8b5 и a5c03b93e7b5 (cond_resched: у нас PREEMPT_NONE, большие каталоги → soft lockup), 52e38a2d3e81 (punch_hole; Samba использует PUNCH_HOLE для sparse-файлов), 0d3a6926f7e8 (don't BUG if someone dirty pages without asking ext4 first), b61c29e397e7 (фрагментация extent_status, т.е. память), 9ed3a3d3a8d2 и 282e8d4e9d33 (запись неинициализированной памяти ядра на диск), 4816177c9f15, b3ad9ff6f06c, 78398c2b2cc1 (защита от повреждённых каталогов), 64b72f5e7574, c3ecf16b410f, 50c3bf3865da (xattr), aa0962310814 (DIO read error), **80c85deccd17 ext4: apply umask if ACL support is disabled** (у нас ACL выключены: umask игнорировался для O_TMPFILE), 75cc31c2e719 (порча при online resize; важно, только если делать `resize2fs` на смонтированной ФС).

**Сеть:** 9f313bcb3b3d net: disable netpoll on fresh napis (у нас netconsole), 4bd7823cacb2 net: ibm: emac: mal: fix wrong goto (путь ошибки probe MAL), 0d3ffbbf8631 net: prevent mss overflow in skb_segment(), d94d95ae0dd0 gro: ensure frag0 meets IP header alignment, 6145a82d87ea, 55c73db29958, 12f99f07a5f4, 5d55a6a46a7f, 2d59f0ca153e, а также большая серия «Fix a data-race around sysctl_tcp_*» (на UP почти не важна).

### 2.3 Нерелевантно для MBL

* **powerpc 64/Book3S/e500/8xx/pseries/powernv:** всё про 64s/radix, L1D flush (31ebc2fe02df, f69bb4e51f41 — Spectre-mitigation только для 64s), TM (c14e3ade0126, 72e2df70fb52), xive/xics/eeh/rtas/tau/pkeys/fsl/t208x dts, kprobes (KPROBES выключены), memory_hotplug, ftrace (0d2c629858e1, efe775c71423; FTRACE выключен), ebd918f806bc (recordmcount + binutils 2.37, только при FTRACE), b11ac8328081 (signal frame 4224 байт касается 64-bit TM; 32-bit кадр меньше).
* **KUAP** в 4.19 для 44x отсутствует вообще (для 44x он появился в 6.x). **Spectre/Meltdown** для 44x/464 в ядре не мигрируются ни в одной версии (barrier_nospec есть только для e500 и Book3S64). Переход на .325 здесь ничего не меняет.
* **bfq, blk-cgroup, blk-throttle, blk-iolatency, blk-wbt** выключены. **blk-mq** (9525b38180e2, 3e62d49f597f, 77064570e4c3) не используется, пока SCSI на legacy-пути; важно только при `scsi_mod.use_blk_mq=1`. **integrity** выключен. f387897cf5b8 (32-bit overflow в discard) не нужен: у HDD нет discard. ace51abe0f3a (compat ioctl) не нужен.
* **AHCI, pata_*, sata_mv/sil/nv/fsl/rcar/gemini, ASMedia/Samsung horkage, LPM** — не наше железо.
* **mtd:** в логе только pxa2xx/ap_flash/versatile maps. Для physmap-of/CFI у MBL в логе ничего нет (сам лог mtd неполный).
* **dw dma:** 5ec87f6958d7 (Kconfig HAS_IOMEM) только про сборку.
* **Сеть:** ibmvnic/ibmveth/ehea, IPv6 (выключен), TCP-MD5 (выключен), DECnet, can, phy-мелочи (EMAC использует свой phy.c, не phylib).
* **ext4:** trim/discard (6f44db60f9c4, 96b38975a04d и др.; HDD), encryption/fscrypt (выключено), bigalloc, inline_data, quota, DAX, fsmap, online resize (если не используется).

### 2.4 Известные крупные security-вехи вне логов (проверить командой из раздела 1)

| Что | Релевантность для MBL | Где исправлено (по памяти, **не проверено**) |
|---|---|---|
| NFSD: переполнение буфера ответа RPC через «мусорный» хвост TCP-сообщения (CVE-2022-43945, серия «NFSD: Protect against send buffer overflow in NFSv2/NFSv3 READ/READDIR») | **Удалённо от любого NFS-клиента в LAN** — главный кандидат в must-have вне логов | Upstream осень 2022. Был ли бэкпорт в 4.19.y, проверить |
| SUNRPC/NFSD UAF и гонки (svc_tcp, nfsd4 state) | Удалённо (NFS) | Разные версии в 2020–2024, проверить |
| Ранний CRNG / rework `random.c` (Jason Donenfeld, 2022) | getrandom() на headless NAS больше не зависает долго при загрузке. glibc ≥ 2.36 (arc4random) и Samba зовут getrandom | ≈4.19.24x–25x |
| CVE-2021-33909 (seq_file, «Sequoia») | Локальный root. На 32-bit/256 МБ трудно эксплуатировать | ≈4.19.198 |
| CVE-2020-14386 (af_packet) | Нужен CAP_NET_RAW, userns выключены, т.е. только root | ≈4.19.14x |
| CVE-2021-0920 (unix GC UAF) | Локально | ≈4.19.2xx |
| Отслеживание устройств по IP-ID/порту/prandom (CVE-2019-10638, CVE-2020-16166, CVE-2022-32296), SADDNS (CVE-2020-25705) | Приватность, в LAN низкая | 4.19.5x…4.19.25x |
| Dirty Pipe, fsconfig CVE-2022-0185, nf_tables, overlayfs CVE-2023-0386, StackRot | **4.19 не затронут** или netfilter выключен | — |

---

## 3. Мелкие патчи: keep / drop / update

| Патч | Что делает | Вердикт | На 4.19.325 |
|---|---|---|---|
| **009_ppc464_makefile** | `cpu-as-$(CONFIG_4xx) += -mcpu=464fp -Wa,-m464` вместо `-Wa,-m405` | **Keep.** Разумный тюнинг под PPC464 с FPU. `-mcpu=464fp` поддерживается и в gcc 13/14, `-m464` — в gas. Флаг попадает в CFLAGS после `-mcpu=powerpc` и побеждает его. Ядро собирается с `-msoft-float`, так что FPU-инструкции в ядро не попадут | fuzz (строка E200 удалена в 57ac40ee09ce), применяется корректно |
| **047 / 048 mtd** (orig_flags, абсолютные границы разделов) | Upstream v5.0, важны только для вложенных (sub-)разделов MTD | **Можно дропнуть.** В DT MBL разделы плоские (`partition@…` под `nor_flash@0,0`). Если оставить, вреда нет | 047 fuzz, 048 ok |
| **140-GPIO named exports** | Узлы DT `compatible = "gpio-export"` | **Drop.** В `apollo3g.dtb` строки `gpio-export` нет (проверено по строкам dtb). Код мёртвый | fuzz |
| **201-add-amcc-apollo3g-support** | Добавляет `"amcc,apollo3g"` в список плат `ppc44x_simple` и Kconfig APOLLO3G | **Keep (обязателен).** Корень DTB MBL — `amcc,apollo3g`: без этого патча машина не распознаётся | fuzz |
| **201-extra_optimization** | `-O2 -fno-reorder-blocks -fno-tree-ch $(EXTRA_OPTIMIZATION)` | **Update или drop.** Это OpenWrt-флаги ради размера на MIPS, выигрыш на PPC464 не доказан (не проверено). На .325 блок упрощён (`-Os`/`-O2` без веток PROFILE_ALL_BRANCHES), rebase — одна строка: `KBUILD_CFLAGS += -O2 -fno-reorder-blocks -fno-tree-ch $(EXTRA_OPTIMIZATION)` в ветке `else`. Рекомендую drop и сравнить бенчмарком | **FAIL** (hunk в Makefile:657) |
| **202-add-netgear-wndr4700-support** | Kconfig WNDR4700 + `obj-$(CONFIG_WNDR4700) += wndr4700.o` | **Drop.** Не MBL. Файла `wndr4700.c` патч не добавляет, так что при включении опции сборка сломается | fuzz |
| **202-reduce_module_size** | `ld -s` для модулей | **Drop** (или безразлично). Модуль ровно один, `loop` | fuzz |
| **204-module_strip** (`CONFIG_MODULE_STRIPPED=y`) | Убирает vermagic, alias, device tables, описания параметров | **Drop и выключить опцию.** Без vermagic ядро без предупреждений загрузит модуль от другой сборки. Без `MODULE_DEVICE_TABLE` не работает автозагрузка модулей через udev/kmod. На 3 ТБ NAS экономия ничтожна | fuzz. Трогает `modpost.c`, `module.c` — при обновлениях зона риска |
| **207-disable-modorder** | Не генерировать `modules.order` | **Drop.** Современный kmod/depmod использует `modules.order` для порядка. На .325 в `Makefile.build` появился механизм `need-modorder`, патч применяется с fuzz, но это лишняя зона риска | fuzz |
| **301-fix-memory-map-wndr4700** | Меняет PIM0LAH/PIM1LAH (inbound window PCIe) на 0x8/0xc для **всех** APM821xx-портов PCIe | **Drop.** Специфично для WNDR4700 (wifi на PCIe). На MBL PCIe-устройств нет, но патч меняет общий код | fuzz |
| **321-powerpc_crtsavres_prereq** | Не линковать `crtsavres.o` в модули | **Drop (важно).** Патч рассчитан на OpenWrt-gcc, пропатченный против out-of-line `_savegpr_*/_restgpr_*`. Стоковый gcc (Ubuntu/Debian/bootlin) выдаёт такие вызовы для «холодных» функций (`__cold`, `__init`, unlikely-пути), даже при `-O2`. Итог — `Unknown symbol _restgpr_29_x` при загрузке модуля. Сейчас сходит с рук, потому что модуль только `loop` (скорее всего). С новым gcc риск растёт | fuzz |
| **702-phy_add_aneg_done_function** | Хук `phy_driver->update_link` | **Drop.** Ни один патч и драйвер его не использует (grep по всем патчам: только сам 702). EMAC использует собственный `phy.c`, не phylib | fuzz |
| **801/802 xhci uPD720201** | Загрузчик прошивки Renesas xHCI, форс MSI | **Drop.** `CONFIG_USB` не задан, у MBL нет USB-хоста | fuzz |
| **803/804 hwmon tc654** | Датчик вентилятора TC654 (WNDR4700) | **Drop.** `HWMON`/`THERMAL` выключены, в MBL нет TC654 | ok |
| **901-debloat_sock_diag** | Делает `sock_diag.o` опциональным (`CONFIG_SOCK_DIAG`, выбирается `INET_DIAG`/`UNIX_DIAG`/`PACKET_DIAG`/`NETLINK_DIAG`), переносит `sock_gen_cookie()` в `sock.c` | **Keep или drop — неважно.** Сам патч ничего не ломает: `ss` ломает конфиг (`INET_DIAG` не задан). Рекомендация: **drop** (меньше diff'а) и включить `INET_DIAG`+`INET_TCP_DIAG`+`UNIX_DIAG`. Если keep, на .325 проверить, что нет новых вызовов `sock_diag_*` из общего кода (сборкой) | fuzz |
| **902-debloat_proc** (`PROC_STRIPPED=y`) | Убирает `/proc/{locks,consoles,tty/*,sysvipc/*,execdomains,timer_list,vmallocinfo,buddyinfo,pagetypeinfo,zoneinfo}`, `/proc/irq` (на UP), `/proc/net/{softnet_stat,ptype,fib_trie,fib_triestat,protocols,rt_cache,snmp,netstat,sockstat,vlan}` и **превращает все SNMP MIB-счётчики в no-op** | **Drop (рекомендую) или хотя бы выключить `PROC_STRIPPED`.** Подробности ниже | fuzz |
| **904-debloat_dma_buf** | dma-buf как модуль/опционально + `EXPORT_SYMBOL_GPL(wake_up_state)` | **Keep или drop — безвредно.** Пользователей dma-buf (DRM/V4L) нет. Дубля экспорта `wake_up_state` в .325 нет (проверено) | fuzz |

**Что из userland Debian sid задевает 902:**
* `ss -s` читает `/proc/net/sockstat` → **сломан**. `ss` без `INET_DIAG` откатывается на `/proc/net/tcp`/`unix`: работает, но без `-i/-m/-K` и медленнее (по памяти о fallback в iproute2, не проверено).
* `netstat -s` (net-tools), `nstat`/`ip -s` (iproute2), `snmpd`, мониторинг (collectd/telegraf/netdata) — `/proc/net/snmp`/`netstat` отсутствуют, а счётчики ядра не ведутся вообще. Для диагностики сети NAS (retrans, drops) это существенная потеря.
* `lslocks` (util-linux) и `lsof` (информация о блокировках) используют `/proc/locks` → сломаны. Samba, nfs-utils, rsyslog, chrony **не зависят** от `/proc/locks`.
* `ipcs` (util-linux) читает `/proc/sysvipc/*`, но при их отсутствии откатывается на `*ctl(IPC_INFO/…_STAT)`: работает (не проверено для всех опций).
* `/proc/consoles` используют `sulogin` и `agetty` (util-linux), а также bootlogd в sysvinit 3.x для определения консолей. У них есть fallback (`/sys/class/tty/console/active`, `/dev/console`), но в режиме single-user/`sulogin` на серийной консоли возможны сюрпризы (не проверено).
* procps-ng 4.x (`ps`, `top`, `free`, `vmstat`, `uptime`, `w`, `sysctl`, `pgrep`) использует `/proc/stat`, `meminfo`, `vmstat`, `loadavg`, `uptime`, `/proc/<pid>/*`. Всё это **остаётся**. `pmap -X` требует `PROC_PAGE_MONITOR` (выключен в конфиге, 902 тут ни при чём).
* nfs-utils (`/proc/fs/nfsd`, `/proc/net/rpc/*`), Samba 4.25, rsyslog (`/proc/kmsg`), chrony — затронутых файлов не используют.
* `/proc/net/route`, `/proc/net/dev`, `/proc/net/tcp`, `/proc/net/unix`, `/proc/interrupts` остаются: `ifconfig`, `route`, `netstat -tan` работают.

Экономия от 902 — единицы килобайт кода и копейки CPU на per-cpu инкрементах (на UP почти ноль). Потеря диагностики несоразмерна.

---

## 4. Ревью конфига `.config.4.19` под Debian sid + sysvinit

Сначала главное: userland сейчас на 4.19.99 **реально работает** (glibc 2.43 и Samba 4.25 запускаются), значит минимальные требования соблюдены. glibc для 32-bit ppc откатывается с time64/clone3/close_range/faccessat2 на старые syscalls. `RSEQ=y`, `MEMFD_CREATE=y`, `FHANDLE`, `EPOLL`, `SIGNALFD`, `TIMERFD`, `EVENTFD`, `INOTIFY_USER`, `FANOTIFY`, `AIO`, `FUTEX_PI`, `FILE_LOCKING`, `TMPFS_XATTR`, `DEVTMPFS(_MOUNT)` на месте, `getrandom` есть с 3.17.

### 4.1 Добавить (функциональные дыры)

| Опция | Зачем |
|---|---|
| `EXT4_FS_POSIX_ACL=y` | **Главное.** Samba (vfs_default/posixacl) маппит NT ACL из Windows в POSIX ACL. Без этого смена прав из проводника и наследование ACL не работают. Сейчас `NFSD_V3_ACL=y` включён без поддержки ACL в ФС и потому бесполезен |
| `EXT4_FS_SECURITY=y` | `security.*` xattr: file capabilities (`setcap` в postinst: iputils-ping и др. откатываются на setuid), `security.NTACL` для `vfs_acl_xattr`, если он понадобится |
| `TMPFS_POSIX_ACL=y` | Мелочь, для консистентности |
| `SECCOMP=y` (+ `SECCOMP_FILTER`, для ppc32 доступен) | chrony в Debian по умолчанию запускается с `-F 1`. Без seccomp chronyd, **вероятно**, завершается фатально (libseccomp → EINVAL; не проверено на 4.19). Альтернатива — `DAEMON_OPTS="-F 0"`. OpenSSH 10: провал `PR_SET_SECCOMP` в sandbox, по памяти, **не фатален** (debug-сообщение). К тому же у вас dropbear, которому seccomp не нужен. Включение стоит копейки |
| `INET_DIAG=y`, `INET_TCP_DIAG=y`, `INET_UDP_DIAG=y`, `UNIX_DIAG=y` (`PACKET_DIAG`/`NETLINK_DIAG` по желанию) | `ss` в полном режиме |
| `IKCONFIG=y`, `IKCONFIG_PROC=y` | `/proc/config.gz`: трассируемость сборок, ~15–30 КБ |
| `BOOKE_WDT=y` (по желанию) | Аппаратный watchdog PPC4xx для автономного NAS. Сейчас `WATCHDOG=y` включён без драйвера. Прежде чем полагаться, проверить поведение u-boot |
| `DETECT_HUNG_TASK`, `SOFTLOCKUP_DETECTOR` (по желанию) | При `PANIC_TIMEOUT=1` вместе с `hung_task_panic` дают автоперезагрузку при зависании IO |

### 4.2 Выключить или поправить (вредное либо лишнее)

| Опция | Почему |
|---|---|
| `PROC_STRIPPED=y` → **n** | См. раздел 3 (SNMP-счётчики, `/proc/net/sockstat`, `/proc/locks`, …) |
| `MODULE_STRIPPED=y` → **n** | vermagic и modalias (раздел 3) |
| `PPC_WERROR=y` → **n** | С любым gcc новее 8 сломает сборку `arch/powerpc` (раздел 5) |
| `UEVENT_HELPER=y`, `UEVENT_HELPER_PATH="/sbin/hotplug"` → **путь пустой** (или опцию выключить) | При udev helper не нужен: на каждый uevent ядро пытается exec несуществующего `/sbin/hotplug` |
| `CRYPTO_MANAGER_DISABLE_TESTS=y` вместе с `CRYPTO_DEV_PPC4XX=y` | Либо включить self-tests, либо убрать crypto4xx (пользователей нет). `HW_RANDOM_PPC4XX` оставить |
| `BPF_SYSCALL=y` | Непривилегированный eBPF в 4.19 — источник многих LPE. Выключить (на NAS не нужен) или хотя бы `sysctl kernel.unprivileged_bpf_disabled=1`. `BPF_JIT` (cBPF на ppc32) можно оставить |
| `PM_AUTOSLEEP`, `PM_WAKELOCKS`, `SUSPEND` | Android-наследие, на MBL не нужно (мелочь) |
| `F2FS_FS`, `OVERLAY_FS`, `FSCACHE` | Если не используются, лишние ~сотни КБ RAM ядра при 256 МБ |
| `CGROUPS=y` с одним `CGROUP_SCHED` без `FAIR_GROUP_SCHED` | Бессмысленно для sysvinit. Выключить или оставить — безразлично |

### 4.3 Оставить как есть (осознанно)

* `IPV6` off: rpcbind пишет предупреждения про `udp6`/`tcp6` из `/etc/netconfig`, но работает. Samba, nfs-utils, glibc, dropbear, chrony — без проблем.
* `NAMESPACES` off, `CHECKPOINT_RESTORE`, `CROSS_MEMORY_ATTACH`, `POSIX_MQUEUE`, `KEYS`, `AUDIT`, `SECURITY` off — ничего из стека Samba/NFS-сервер/rsyslog/chrony/dropbear на sysvinit это не требует. NFS-сервер не нуждается в keyring (нужен клиенту для idmap). `unshare`/`nsenter` работать не будут.
* `NETFILTER` off: осознанно, NAS за роутером.
* `LBDAF=y`: обязателен для 2.7 ТБ на 32-bit. На месте.
* `CRYPTO_CRC32C=y` для metadata_csum: на месте.
* `HW_RANDOM=y` + `HW_RANDOM_PPC4XX=y`. Совет: если в `dmesg` `random: crng init done` появляется поздно, добавить в cmdline `rng_core.default_quality=1000`, чтобы TRNG кредитовал энтропию. В 4.19.99 это особенно актуально, в .325 random.c уже переработан (quality у ppc4xx-rng по умолчанию, скорее всего, 0; не проверено).

### 4.4 Замечание про udev

Если используется `udev` из Debian sid (собирается из systemd), новые версии systemd официально требуют ядро ≥ 5.4 (по памяти о NEWS systemd 257/258, **не проверено**). Сейчас udev работает, но любое обновление может сломаться без предупреждения. Это ещё один аргумент за стратегический переход на 6.x в будущем (раздел 6).

---

## 5. Тулчейн: gcc 13/14 против текущего gcc 8.4

Текущее состояние: `.config` сгенерирован OpenWrt-тулчейном gcc 8.3/musl (`CONFIG_GCC_VERSION=80300`, `cross-compilation/toolchain-powerpc_464fp_gcc-8.3.0_musl.url`). Со слов пользователя, ядро собиралось Ubuntu 18.04 gcc 8.4.

### 5.1 Проблемы 4.19.99 с новым gcc/binutils/make

1. **Хост, dtc: `multiple definition of yylloc`** (gcc ≥ 10, `-fno-common` по умолчанию). Исправление — upstream «scripts/dtc: Remove redundant YYLOC global declaration»: удалить `YYLTYPE yylloc;` из `scripts/dtc/dtc-lexer.l` и из `*_shipped`. В 4.19.325 скорее всего уже бэкпортировано (не проверено: `grep -n "YYLTYPE yylloc" scripts/dtc/*`). Для самого ядра `-fno-common` не проблема: он в `KBUILD_CFLAGS` давно.
2. **`CONFIG_PPC_WERROR=y`**: `arch/powerpc` собирается с `-Werror`. Новые предупреждения gcc 10–14 (`builtin-declaration-mismatch` для setjmp/longjmp, до 473575d518b1; `array-bounds`, `stringop-overflow`, `zero-length-bounds`, `dangling-pointer`, `address-of-packed-member`) превращаются в ошибки. **Выключить в любом случае.**
3. Верхний `Makefile` 4.19.99 **не** гасит шумные новые предупреждения. В .325 добавлено отключение `zero-length-bounds`, `array-bounds`, `stringop-overflow`, `restrict`, `dangling-pointer`, `maybe-uninitialized` (видно в diff Makefile). Это только шум, не ошибки, но шум огромный.
4. **GNU make 4.4** (Debian sid): в .99 флаг `s` ищется в `MAKEFLAGS` по-старому, поэтому переменные командной строки ложно включают silent-режим. В .325 исправлено (блок `make-4.0 (and later) keep single letter options…`). Косметика.
5. **binutils ≥ 2.39**: предупреждения `LOAD segment with RWX permissions` / `executable stack`. В .325 добавлено `-z noexecstack` и `--no-warn-rwx-segments`. Orphan-секция `.branch_lt` исправлена в 7ad4e05c5e60. В .99 будут предупреждения (не фатальные, если не включён `--fatal-warnings`).
6. `-Wl,-a32` в `KBUILD_AFLAGS` (убрано в 801ff5f45e76): gcc выдаёт «linker input unused», не фатально.
7. **gcc 14** делает ошибками по умолчанию `int-conversion`, `return-mismatch` (а также `implicit-*` и `incompatible-pointer-types`, но ядро и так ставит их как `-Werror=`). В старом коде 4.19 теоретически могут всплыть ошибки. Как минимум для `ppc44x_defconfig` 4.19.y с gcc 14 массово никто не тестировал (не проверено).
8. **Модули**: см. 321-crtsavres. С стоковым gcc патч нужно дропнуть.
9. `arch/powerpc/boot` (сборка `uImage`/wrapper) компилируется своими `BOOTCFLAGS`. С новыми gcc в 4.19 там исторически бывали проблемы; в .325 часть из них закрыта (не проверено для 44x). Нужна тестовая сборка.
10. Не актуально для ppc32: objtool (только x86), retpoline/`-fcf-protection`, gcc-plugins (не используются), BTF/pahole, `-fstack-clash-protection`. Последний Debian gcc по умолчанию не включает, в отличие от Ubuntu; это не ломает сборку.

### 5.2 Дружелюбнее ли 4.19.325?

**Да, заметно.** В нём есть: setjmp/longjmp-прототипы, отключение шумных предупреждений gcc 10–13, исправления под make 4.3/4.4, `-z noexecstack` / `--no-warn-rwx-segments`, `.branch_lt`, удаление `-Wl,-a32`, `dcr cmplwi`, stack-protector для ppc32, gcc-13 enum-фиксы (в ahci, у нас не собирается), dtc/yylloc (скорее всего). LKFT/KernelCI до конца жизни 4.19.y гоняли его с gcc 8–12 (по памяти; кажется, включая ppc44x/ppc6xx defconfig). gcc 13/14 для 4.19 — зона «как повезёт».

### 5.3 Рекомендация по тулчейну

* Для **4.19.99** оставить gcc 8.4 (Ubuntu 18.04 в контейнере). Там всё проверено.
* Для **4.19.325** взять gcc **12** (Debian bookworm `gcc-12-powerpc-linux-gnu` или bootlin `powerpc-440fp--glibc--stable`), выключить `PPC_WERROR`, дропнуть 321. Если хочется gcc 13/14, собирать и честно просматривать warnings в `arch/powerpc`, `drivers/ata`, `drivers/dma/dw`, `drivers/net/ethernet/ibm/emac` (там патчи ewaldc, и новые предупреждения могут указывать на реальные баги).
* Флаг `-mcpu=464fp` из 009 поддерживается gcc 13/14. Производительность ядра от gcc 12/14 против 8 на PPC464 заметно не изменится (не проверено). Смысла гнаться за новым gcc ради скорости нет.

---

## 6. Итоговая рекомендация

### Вариант A: остаться на 4.19.99 и бэкпортировать выборочно
* Нужно взять около 20 must-have из раздела 2.1 плюс их зависимости. Одна серия mbcache/xattr (98953044b3cd, efaa0ca678f5, 9f0d01eaa7b2, bb337d8dd1e1, 9ad75e78747b) тянет цепочку. Серия extent-path UAF 2024 г. опирается на рефакторинги, которых в .99 нет. Оценка: **3–6 дней** ручной работы с высоким риском ошибиться. Вне логов (NFSD/SUNRPC/random) ещё неизвестный объём.
* Плюсы: патчи ewaldc остаются без изменений, производительность и стабильность уже проверены.
* Минусы: остаются десятки исправлений, которые никто не выбрал. Каждый бэкпорт делается вручную и не тестирован upstream в такой комбинации.

### Вариант B (рекомендуется): перейти на 4.19.325 и перенести 5 патчей
* `201-extra_optimization`: 5 минут (или drop).
* 990/992/994/996: конфликтов по 1–3 hunk'а. Часть из них — места, которые upstream сам исправил (`sata_dwc` OOB → `SATA_DWC_QCMD_MAX`, путь ошибки probe; `qc_prep` → `ata_completion_errors`; TCP-исправления в `tcp.c`). Детали у агентов по хранилищу и сети. Оценка: **1–2 дня** на rebase и сборку, плюс **3–7 дней** torture-тестов (`fio`/`dd` по SATA, Samba и NFS под нагрузкой, `e2fsck -fn` после; ewaldc тестировал 96 ч).
* Одновременно почистить набор: drop 140, 202-wndr4700, 202-reduce, 204, 207, 301, 321, 702, 801–804, 902 (и, по желанию, 901, 047/048). Останется 002, 009, 201-apollo3g, 990–997 (+904). Меньше патчей — легче дальнейшие обновления.
* Конфиг: `EXT4_FS_POSIX_ACL`, `EXT4_FS_SECURITY`, `SECCOMP(_FILTER)`, `INET_DIAG`/`UNIX_DIAG`, `IKCONFIG_PROC` — включить; `PPC_WERROR`, `PROC_STRIPPED`, `MODULE_STRIPPED` и путь `UEVENT_HELPER` — выключить (или очистить путь). Тулчейн: gcc 12.
* Порядок безопасного перехода: собрать .325 с **тем же** конфигом (минус `PPC_WERROR`), прогнать тесты, затем отдельным шагом менять конфиг и набор патчей. Так регрессии можно локализовать. Старое ядро 4.19.99 держать как запасной uImage в u-boot env.
* **Суммарно: ~1–1.5 недели календарного времени, из которых 2–3 дня активной работы.**

### Дальше
* **CIP SLTS `linux-4.19.y-cip`** (git.kernel.org, cip/linux-cip) продолжает бэкпорты в 4.19 после EOL (по плану CIP до ~2029 г.). После перехода на .325 rebase на `v4.19.325-cipNN` почти бесплатен. Оговорка: CIP ориентирован на свои референсные платы (arm/x86), powerpc 44x там почти не тестируется, но общие ext4/net/nfsd-исправления попадают.
* **Долгосрочно:** mainline/6.x LTS по пути chunkeey (`c:\GitHub\mbl-debian-chunkeey`, upstream-DTS `wd-mybooklive.dts`, стоковый драйвер `sata_dwc_460ex` + dw_dmac, собирается Debian `gcc-powerpc-linux-gnu`). Это снимает проблемы udev и systemd-тулинга, orphan_file, отсутствия исправлений. Цена — потеря perf-патчей ewaldc (DMA-оптимизации SATA/EMAC, 16K/64K-тюнинг): придётся мерить и, возможно, частично переносить.

### Первые шаги (конкретно)
1. Собрать linux-stable `v4.19.325`, выполнить команду из раздела 1 и проверить NFSD/SUNRPC (CVE-2022-43945) и `random`.
2. Применить: 002, 009, 201-apollo3g, 904, 990–997, взяв от агентов исправленные 990/992/994/996.
3. `make olddefconfig` с `.config.4.19`, где `PPC_WERROR=n`; проверить, что `CONFIG_STACKPROTECTOR` можно включить (по желанию, после первых тестов).
4. Собрать gcc 12, загрузить по TFTP/USB или со второго uImage, прогнать torture-тест, `e2fsck -fn` на снимке и сравнить Samba- и NFS-производительность с 4.19.99.
