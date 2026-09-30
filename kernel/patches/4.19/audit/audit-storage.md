# Аудит storage-патчей ewaldc для WD My Book Live (Linux 4.19.99)

Область проверки: `996_sata_dwc_460ex.patch`, `997_dw_dma.patch`, `994_libata+ledtrig.patch`, `995_block.patch`, `002_ppc4xx_ocm.patch`.
Проверялся итоговый код после наложения всех патчей (`C:\tmp\k419\patched-v4.19.99\...`), а не только diff. Все ссылки `файл:строка` указывают на эти пропатченные файлы, если не оговорено иное.

Конфигурация, от которой зависят выводы (`kernel/patches/4.19/config/.config.4.19`): `PPC_16K_PAGES=y`, `HIGHMEM` выключен, `NOT_COHERENT_CACHE=y`, `PREEMPT_NONE`, UP, `SATA_DWC=y`, `SATA_DWC_OLD_DMA` выключен, `DW_DMAC=y`, `SCSI_MQ_DEFAULT` выключен (legacy request path + deadline), `SATA_PMP` выключен, `ATA_LEDS` выключен, `DEBUG_SG` и `DEBUG_SPINLOCK` выключены.
DT (mbl-debian `apm82181.dtsi`): у AHB DMA `block_size = <4095>`, `data-width = <4>` для всех masters, `multi-block = <1>`. У SATA есть `dmas = <&AHBDMA0 …>` и `dma-names = "sata-dma"`. OCM занимает 32 КБ, туда же кладутся дескрипторы EMAC/MAL (`descriptor-memory = "ocm"`).

Шкала серьёзности: **critical**, **high**, **medium**, **low**, **info**.
Пометки: «(унаследовано)» — дефект уже есть в ванильном 4.19.99; «(внесено патчем)» — его добавил патч ewaldc.

---

## 0. Главное коротко

1. **critical (унаследовано, в 4.19.99 не исправлено): OOB-запись через `ATA_TAG_INTERNAL` = CVE-2022-49073.** В пропатченном драйвере по-прежнему `SATA_DWC_QCMD_MAX = 32`. Первая же *внутренняя DMA-команда* libata (READ LOG DMA EXT: например, чтение NCQ error log 10h в EH после любой NCQ-ошибки) выполняет `dma_pending[32] = 0`, что обнуляет соседнее поле `hsdevp->chan`. Следующий I/O падает на NULL-dereference в `sata_dwc_qc_issue`, NAS зависает. В 4.19.325 это исправлено (коммит 596c7efd69aa).
2. **high (внесено 994): `ata_host` и `ata_port` лежат в некэшируемой OCM, отображённой через ioremap.** `ap->sector_buf` и `dev->id` служат буферами внутренних команд. `sg_init_one()`/`virt_to_page()` на ioremap-адресе дают фиктивную `struct page`, поэтому та же READ LOG DMA EXT пошлёт DMA на несуществующий физический адрес. PIO пока работает только из-за «арифметического совпадения» при выключенном HIGHMEM.
3. **high (унаследовано): ошибка устройства (бит ERR в Status) при DMA/NODATA-командах завершает qc с `err_mask = 0`.** SCSI получает GOOD. Это тихая порча данных при UNC-секторе и незамеченная ошибка FLUSH CACHE. Кроме того, DMA-канал остаётся взведённым на старый буфер.
4. **high (унаследовано): нет остановки DMA в EH/timeout.** Глобальный счётчик чётности `dma_interrupt_count` никогда не сбрасывается. После любого сбоя команды могут завершаться «не на том» прерывании, то есть до окончания DMA.
5. **medium (внесено 994): из `ata_scsi_find_dev` убрана проверка `ata_dev_enabled()`.** После того как EH отключил или отсоединил диск, команды продолжают уходить в железо (ATAPI-веткой) вместо немедленного `DID_BAD_TARGET`.
6. **medium (внесено 996): `ppc4xx_ocm_alloc` → `memset` выполняется до проверки на NULL.** Память OCM никогда не освобождается. `probe` возвращает 0 даже при ошибке `ata_host_activate`.
7. **NCQ: определять `SATA_DWC_NCQ` НЕБЕЗОПАСНО.** Код NCQ по сути не реализован: completion-цикл мёртв и содержит бесконечный цикл, `qc_defer` отсутствует, BSY перед выдачей следующей команды не ждётся, для всех тегов один счётчик чётности, `active_tag` libata подменяется. Результат — таймауты, EH-штормы и вероятная порча данных. Для одного HDD при CPU-bound SMB выигрыша практически нет. Вердикт — **unsafe, не включать** (подробности в разделе 2).

Важная деталь текущего режима: драйвер выставляет `ATA_FLAG_NCQ`, а `can_queue = 1` не включает `ATA_DFLAG_NCQ_OFF`. Поэтому даже сейчас все чтения и записи идут как **READ/WRITE FPDMA QUEUED с тегом 0** через путь NEWFP (DMA Setup FIS) — это видно по `NCQ (depth 1/32)` в dmesg. То есть NCQ-протокол с глубиной 1 уже в продакшене, и именно NCQ-ошибка запускает EH-чтение log 10h, то есть триггер пунктов 1–2.

---

## 1. Разбор по патчам

### 1.1 `996_sata_dwc_460ex.patch` (драйвер SATA DWC 460EX)

**Что меняет и зачем (задумка — производительность):**
- `hsdev` (struct sata_dwc_device) размещается в некэшируемой OCM вместо `devm_kzalloc` (`sata_dwc_460ex.c:1169`).
- Добавлены кэшированные `reg_base` и `scr_base`. Прямые `in_le32`/`out_le32` SCR (`sata_dwc_core_scr_read/write`, 427–450) заменяют `sata_dwc_scr_read(&ap->link, …)`.
- `sata_dwc_qc_complete` переписан (527–548): он больше не проверяет pending DMA и принимает `tag` и `hsdev` параметрами. `sata_dwc_clear_dmacr` (335–346) получает готовое значение `dma_pending`.
- `sata_dwc_exec_command_by_tag` (948–971) вызывает `iowrite8(command)` + `ioread8(altstatus)` + `ndelay(pause_after_command_exec = 10)` вместо `ata_sff_exec_command` (где пауза 400 нс). Добавлен module_param.
- `ata_qc_from_tag()` заменён на `&ap->qcmd[tag]` (596, 619).
- `dma_slave_config` сделан `static` с позиционным инициализатором (385–388). `dmaengine_prep_slave_sg` заменён прямым `device_prep_slave_sg(..., context = hsdev)` (411).
- Много `likely`/`unlikely` и `__always_inline`. ISR всегда возвращает `IRQ_RETVAL(1)` (753).
- `can_queue` оформлен как `#ifdef SATA_DWC_NCQ` → `ATA_MAX_QUEUE`, иначе `ATA_DEF_QUEUE` (1108–1112).
- В NCQ-issue и `bmdma_setup` тег теперь вычисляется как `ncq ? hw_tag : 0`. В `bmdma_start` (1021) вместо этого используется `qc->tag`.

**Дефекты:**

| # | Серьёзность | Где | Описание |
|---|---|---|---|
| D1 | **critical** (унаследовано; исправлено в 4.19.325) | 155, 159–164, 356, 631, 785 | **CVE-2022-49073.** Массивы `cmd_issued/dma_pending/desc[32]` индексируются `ap->link.active_tag`, а для внутренних команд он равен `ATA_TAG_INTERNAL = 32` (`include/linux/libata.h:132`). Раскладка структуры: `cmd_issued[32]`, `dma_pending[32]`, `chan`, `desc[32]`. Поэтому `dma_pending[32]` совпадает с `chan`. Сценарий внутренней DMA-команды: `qc_issue` использует тег 0 (hw_tag), completion — тег 32. `dma_dwc_xfer_done` (356) читает `dma_pending[32]` (там указатель `chan`) и уходит в ветку «Driver out of sync», сбрасывая оба направления DMACR. ISR (631) выполняет `cmd_issued[32] = 0`, что затирает `dma_pending[0]`. `sata_dwc_dma_xfer_complete` (785) выполняет `dma_pending[32] = NONE`, то есть **`hsdevp->chan = NULL`**. Следующий `dma_dwc_xfer_setup` → `dmaengine_slave_config(NULL…)` → Oops. Это ровно сценарий из коммита Christian Lamparter 596c7efd69aa (он попал в 4.19.238). Триггер — любая READ LOG DMA EXT: `ata_read_log_page()` (libata-core.c:2096), если диск поддерживает её (`ata_id_has_read_log_dma_ext`) и выставлен `dev->dma_mode`. На практике это `ata_eh_read_log_10h` после NCQ-ошибки, а также NCQ send/recv и identify-log при probe на поддерживающих дисках. **Быстрая проверка:** `hdparm -I /dev/sda \| grep -i READ_LOG_DMA`. Исправление — `#define SATA_DWC_QCMD_MAX (ATA_MAX_QUEUE + 1)`. |
| D2 | **high** (унаследовано) | 633–636, 709–714, 527–548, 659–660 | При `status & ATA_ERR` qc завершается через `ata_qc_complete()` **без `qc->err_mask`**. В `ata_qc_complete` (libata-core.c:5252) ошибка определяется только по `err_mask`, поэтому EH не зовётся и `ata_scsi_qc_complete` отдаёт `SAM_STAT_GOOD`. Для READ с UNC это значит, что в page cache попадёт мусор/старые данные как «успех». Для FLUSH CACHE и других NODATA-команд (ветка 659) ошибка теряется. Внутренних команд это не касается: `ata_exec_internal` сам проверяет `result_tf`. Исправление: `qc->err_mask \|= ac_err_mask(status)` (или `AC_ERR_DEV`) + `ata_port_freeze`/abort. |
| D3 | **high** (унаследовано) | 365–374, 649–656, 721–727; ops 1122–1140 | Нет остановки DMA при ошибке и таймауте. `ata_sff_port_ops` не имеет `bmdma_stop`/`post_internal_cmd` для DW DMA, а `dmaengine_terminate_sync` есть только в `port_stop` (933). После ATA_ERR (D2) или таймаута дескриптор остаётся активным или в очереди dw_dma. Следующий `dmaengine_submit` встаёт за ним, и первые данные новой команды уходят **в буфер старой, уже завершённой и, возможно, освобождённой** команды. `dma_interrupt_count` глобальный и **никогда не обнуляется** (единственные места — `++`), поэтому любой потерянный или лишний callback навсегда сдвигает чётность. Тогда команда может быть завершена по SATA-IRQ до завершения DMA: риск чтения неполных данных. Точное поведение DWC при прерванной передаче не проверено (uncertain), но в коде защиты нет вовсе. |
| D4 | **medium** (внесено) | 1169–1173, 1243, 1245–1247, 1250–1267 | `hsdev = ppc4xx_ocm_alloc(...)` сразу идёт в `memset(hsdev, 0, …)` **до** проверки `!hsdev`: если OCM закончилась или не проинициализирована, будет NULL-dereference в probe. Нет `ppc4xx_ocm_free` ни в error-путях (`return PTR_ERR(base)`, `error_out`), ни в `sata_dwc_remove`. При `-EPROBE_DEFER` (phy/dma) каждый повтор теряет блок OCM. `ata_host_activate` при ошибке → `return 0` (1239–1243, унаследовано): драйвер «успешно» привязан к неработающему хосту. |
| D5 | **medium** (внесено) | 596–602 | В NEWFP-ветке `ata_qc_from_tag()` заменён на `&ap->qcmd[tag]`. Проверка `!qc` бессмысленна (адрес элемента массива не NULL), флаг ACTIVE/FAILED не проверяется. `cmd_issued[tag]` сбрасывается в NOT только в путях успешного completion, после EH/таймаута он остаётся PEND. Поздний или ложный NEWFP для уже прерванного тега вызовет `bmdma_start_by_tag` со старым `desc[tag]`, чей sg-список уже unmapped: **DMA в освобождённую память**. (Оригинал в этом случае падал на NULL, что тоже плохо, но без тихой порчи.) Кроме того, `tag = (u8)readl(fptagr)` не маскируется `& 0x1f`: мусор в регистре приведёт к OOB `cmd_issued[tag]`. |
| D6 | **medium** (внесено) | 622 | Потеряна проверка `ATA_TFLAG_POLLING` из оригинала (`qc->tf.flags & ATA_TFLAG_POLLING`). libata опрашивает IDENTIFY (libata-core.c:1916) и SET FEATURES XFER (4857) в polling-режиме. Если в этот момент DWC всё же поднимет IRQ, ISR вызовет `ata_sff_hsm_move()` параллельно с polling-задачей: гонка HSM, «HSM violation» и reset. Вероятность низкая (nIEN выставлен). |
| D7 | **medium** (внесено) | 753 | ISR всегда возвращает `IRQ_HANDLED`, даже если INTPR пуст. Детектор spurious/stuck IRQ ядра отключается, и при залипшем уровне прерывания система зависнет в livelock, а не отключит линию. Вдобавок прерывания SATA разрешаются (1205) **до** `request_irq` в `ata_host_activate` (1239) — это унаследовано; в 2026 году в апстрим отправлен фикс этого порядка. |
| D8 | **medium** (унаследовано; с NCQ станет high) | 470–473, 587 | `clear_interrupt_bit()` игнорирует аргумент `bit` и записывает обратно весь INTPR, то есть сбрасывает **все** pending-биты. Если NEWFP пришёл одновременно с другим событием (ERR или завершение), второе событие теряется, и получится таймаут. |
| D9 | **medium** (M3; унаследовано + усилено 16K-страницами и 997) | 1119; dmesg `blk_queue_segment_boundary: set to minimum 3fff` | Драйвер требует, чтобы LLI не пересекал 8 КБ (`dma_boundary = 0x1fff`, комментарий о «8K max FIS boundary … error in the host controller»). При 16K-страницах блок-слой принудительно поднимает маску до `PAGE_SIZE-1 = 0x3fff`. Сегменты до 16 КБ пересекают 8K-границы, и это ограничение фактически **не соблюдается**. 997 режет LLI по 16380 байт, а 16380 не кратно 64-байтному burst (`AHB_DMA_BRST_DFLT`). Поэтому 16-КБ сегмент превращается в LLI 16380 + 4 байта, и все следующие burst-ы смещены на 4 байта относительно потока. Раз в продакшене 121 МБ/с без ошибок, жёсткое ограничение, возможно, мнимое (uncertain). Но это единственный режим, где такие LLI вообще возникают (при 4K-страницах сегменты ≤ 8 КБ). Дешёвое улучшение: резать по 8192 байта (кратно и burst, и 8K; для 16-КБ сегмента это те же 2 LLI). |
| D10 | **low** (внесено) | 355–356 | `dma_dwc_xfer_done` читает `active_tag` и `dma_pending[tag]` **до** `spin_lock_irqsave`. Callback работает в tasklet (softirq) с разрешёнными IRQ. SATA-ISR может вклиниться и изменить состояние, после чего `clear_dmacr` сработает по устаревшему значению. На UP окно маленькое, но оно есть; в оригинале чтение было под lock. Если `active_tag == ATA_TAG_POISON`, происходит OOB-чтение `dma_pending[0xfd]` (только чтение; то же в `sata_dwc_error_intr`, 493/503). |
| D11 | **low** (внесено) | 948–971 | Пауза после записи команды уменьшена с 400 нс (ata_sff_pause) до 10 нс. Для SATA shadow-регистров BSY выставляет сам контроллер, так что практического вреда, вероятно, нет (uncertain). Но это отход от спецификации ради ~0.4 мкс на команду, что незаметно на фоне ~8 мс seek. |
| D12 | **low** (внесено) | 475, 542–546 | `tag_to_mask_compl(tag) = 0xFFFFFFFE << tag` — это не `~(1 << tag)`: макрос сбрасывает биты 0…tag. `sactive_queued = 0` сразу перед `&= mask` бессмыслен. Сейчас эти поля ни на что не влияют (см. D14), но при попытке NCQ это ошибка. |
| D13 | **low** (внесено) | 1021 vs 975/1031 | `bmdma_start` берёт `qc->tag`, `bmdma_setup` и `qc_issue` — `qc->hw_tag`. Для не-SAS хостов они совпадают, а в NCQ-путь `bmdma_start` не вызывается, так что это несогласованность без эффекта. |
| D14 | **info** (унаследовано) | 569, 613–617, 666–749 | `hsdev->sactive_issued = 0` в начале каждого ISR (вне lock) делает условие на 617 всегда истинным (`tag_mask = (0 \| sactive) ^ sactive = 0`). Весь NCQ-completion цикл 666–749 **мёртв**. Завершение идёт через «не-NCQ» ветку по `active_tag`, который выставляет сам драйвер в NEWFP (608). В 2026 г. Rosen Penev отправил в апстрим патч, переносящий обнуление под lock; это не делает цикл живым. |
| D15 | **info** (внесено) | 385–388, 391–396 | `static struct dma_slave_config` с позиционным инициализатором хрупок при изменении struct, а общий static для двух портов безопасен только на UP. `sconf.direction = qc->dma_dir` смешивает `enum dma_data_direction` и `dma_transfer_direction` (числа совпадают; так было и в оригинале). Результат `dmaengine_slave_config` не проверяется. |
| D16 | **info** (внесено) | 534–540 | Под `#ifdef DEBUG` вызывается несуществующий `printdev_err`: сборка с `CONFIG_SATA_DWC_DEBUG` сломана. Опечатка формата `0xl%08llx` (598). Макросы `SATA_DWC_CORE_SCR_READ/WRITE` не используются. |
| D17 | **low** (унаследовано) | 1044–1048, 1045 | Дескриптор dw_dma готовится в `qc_issue`. Если команда падает или истекает по таймауту до NEWFP/`bmdma_start`, подготовленный, но не отправленный дескриптор не освобождается никогда (утечка из `dma_pool`), а `desc[tag]` перезаписывается при следующей выдаче. |

**Про `likely`/`unlikely`/inline:** семантику они не меняют, кроме уже перечисленных замен функций (D5, D6). Выигрыш неизмерим: при ~121 МБ/с и запросах по 128–512 КБ получается несколько сотен команд в секунду, так что десятки сэкономленных тактов на команду несущественны. Некэшируемая OCM для `hsdev` скорее замедляет: каждое обращение к полю — это некэшируемая загрузка по PLB вместо попадания в L1.

### 1.2 `997_dw_dma.patch` (drivers/dma/dw/core.c, platform.c)

**Что меняет:**
- Под `CONFIG_APM821xx` `dwc_prep_slave_sg` жёстко использует ширину 32 бита (`mem_width = reg_width = 2`), `max_block_size = 4095`, `max_block_bytes = 16380` (712–715, 757, 804) и обходится без `__ffs`/`bytes2block`.
- `dwc_complete_all` теперь вызывается под уже взятым `dwc->lock` и сам его отпускает (361–386, 440). Раньше lock отпускался и брался снова.
- `dwc_initialize` превращён в макрос (178). `dma_async_tx_descriptor_init` заменён прямым `txd.chan = …` (116).
- В `platform.c` повторно разбирается `snps,dma-protection-control` (дубликат блока выше).

**Проверка корректности:** для DT MBL (`data-width = <4>`, `block_size = <4095>`) оригинальный код и так вычислял ширину ≤ 32 бит и блок ≤ 4095 слов. Жёсткие константы дают **тот же** результат. Перестановка lock в `dwc_complete_all` корректна и даже закрывает окно между unlock/lock. Callbacks по-прежнему вызываются без lock (`dwc_descriptor_complete`).

| # | Серьёзность | Где | Описание |
|---|---|---|---|
| W1 | **medium** | 757, 804 | `BLOCK_TS = dlen >> 2`, а `desc->len` и `total_len` считают `dlen` в байтах. Длина, не кратная 4, **молча урезается** (оригинал переключал ширину на байтовую). Для ATA-дисков sg-длины кратны 512 (dma_alignment очереди 511), так что практически это не проявляется. Разбиение по 16380 см. D9. |
| W2 | **low** | 116 | Без `dma_async_tx_descriptor_init` не инициализируется `tx->lock`. Он нужен только при `CONFIG_ASYNC_TX_ENABLE_CHANNEL_SWITCH`, которого здесь нет, и `dma_pool_zalloc` его обнуляет. |
| W3 | **low** | 178 | Макрос `if (…) _dwc_initialize(dwc)` без `do{}while(0)` ломается при появлении `else` у вызывающего кода. Сейчас оба вызова (300, 311) безопасны. |
| W4 | **info** | 211–245, 712–715 | `bytes2block` определён только под `CONFIG_APM821xx` (`//#else` закомментирован), а используется и в `dwc_prep_dma_memcpy`: без APM821xx файл не собирается. `#define mem_width/reg_width/max_block_size` внутри функции «протекают» до конца файла. Жёсткие константы годятся только для этого SoC и DT. |
| W5 | **info** | platform.c | Двойной разбор `snps,dma-protection-control` безвреден. Закомментированный код OCM оставлен. |

Реального выигрыша от 997, кроме экономии нескольких инструкций на LLI, нет: SATA-II DMA работает на скорости диска.

### 1.3 `994_libata+ledtrig.patch` (libata-core/-scsi/-eh, libata.h, Kconfig)

**Что меняет:**
- (a) Под `CONFIG_APM821xx` `ata_host` и `ata_port` выделяются в **некэшируемой OCM** (libata-core.c:84–85, 6015, 6162; освобождение 6104, 6111, 6207).
- (b) `ata_qc_new_init` перенесён в libata-scsi.c (ради inline).
- (c) `__ata_qc_complete(ap, qc)` получает `ap` параметром, `ata_qc_complete` переписан через `goto`.
- (d) `ata_qc_from_tag`, `__ata_qc_from_tag`, `ata_link_max_devices`, `ata_link_active` сделаны макросами (libata.h:1711–1718, ~1583).
- (e) `ata_scsi_find_dev` заменён макросом на `__ata_scsi_find_dev` (libata-scsi.c:68), `__ata_scsi_find_dev` развёрнут.
- (f) Добавлена инфраструктура LED-триггеров `ata%u` (OpenWrt-патч).
- (g) `likely`/`unlikely`.

Функциональную эквивалентность `ata_qc_complete` я проверил: все return-пути сохранены (libata-core.c:5230–5320).

| # | Серьёзность | Где | Описание |
|---|---|---|---|
| L1 | **high** | libata-core.c:6015, 6162; буферы: `ap->sector_buf` (libata-core.c:2129–2442, 4297; libata-eh.c:1461), `dev->id` | `ata_port` (а с ним `sector_buf` и `link.device[].id`) лежит в OCM, отображённой через `__ioremap(_PAGE_NO_CACHE\|_PAGE_GUARDED)` (ocm.c:182). Эти адреса используются как буферы **внутренних команд**: `ata_exec_internal` → `sg_init_one(buf)` → `virt_to_page()` на vmalloc/ioremap-адресе. Получается фиктивная `struct page` за пределами `mem_map` и «физический адрес» `__pa(VA)` ≈ 0x1xxxxxxx, **за пределами 256 МБ RAM**. **DMA-вариант** (READ LOG DMA EXT) отправит DMA на несуществующий адрес: ошибка шины, AHB-error в dw_dma или порча. Uncertain, что именно произойдёт на PLB. **PIO** (IDENTIFY, READ LOG EXT) работает только потому, что без HIGHMEM `page_address(virt_to_page(v)) == v` сходится арифметически; при `CONFIG_DEBUG_SG`/`DEBUG_VIRTUAL` это сразу BUG. Триггер тот же, что у D1 (NCQ-ошибка → log 10h по DMA): **пара D1+L1 превращает первую же ошибку чтения диска в падение ядра.** |
| L2 | **medium** | libata-scsi.c:68, 4445 (и 187, 446, 460, 536, 562) | Макрос `ata_scsi_find_dev` = `__ata_scsi_find_dev` **теряет проверку `ata_dev_enabled(dev)`** (в оригинале это libata-scsi.c:3146). Когда EH отключает сбойный диск (`class` становится `*_UNSUP`) или идёт detach, `ata_scsi_queuecmd` не возвращает `DID_BAD_TARGET`. Он зовёт `__ata_scsi_queuecmd`, где не-ATA класс уходит в **ATAPI-ветку** (`atapi_xlat`), и в отключённое устройство отправляются PACKET-команды. Итог — таймауты и циклы EH вместо быстрого отказа, зависание при выдёргивании или отказе диска. |
| L3 | **medium** | libata-core.c:6015–6018, 6162–6166 | Нет fallback на `kzalloc`, если OCM занята. OCM (32 КБ) делится с EMAC/MAL (`emac/core.c:2898`, `mal.c:950, 1089`) и `hsdev`. Моя оценка `sizeof(struct ata_port)` — около 10–14 КБ (33×`ata_queued_cmd` + 2×`ata_device` с `id[256]` и ering + `tdev`); uncertain, фактическое распределение смотреть в `/sys/kernel/debug/ppc4xx_ocm/info`. На MBL **Duo** (2 порта, 2×(host+port)) или при увеличении колец EMAC диск просто не определится (-ENOMEM). Аллокатор OCM (`ocm.c:310`) не имеет блокировок. Выделение с выравниванием 4 нарушает `____cacheline_aligned` у `sector_buf` (на некэшируемой памяти это не важно). |
| L4 | **low/uncertain** | весь `ata_port`/`ata_host` в OCM | В этих структурах есть `kref`, `mutex`, `struct device` (refcount). На ppc32 они используют `lwarx/stwcx.` даже на UP, то есть атомики выполняются по **cache-inhibited guarded** памяти. Power ISA оставляет резервации на такой памяти на усмотрение реализации (на e500 это DSI). На 464 система грузится и работает, значит, скорее всего, поддерживается, но это архитектурно сомнительно. Каждое обращение к полям qc/link идёт мимо кэша, так что заявленный выигрыш в производительности сомнителен и, вероятно, отрицателен. |
| L5 | **low** (унаследовано из 4.19.99, внесено «удвоение») | libata-core.c:6200–6210 | В error-пути `ata_host_alloc` после `devres_add(dr)` → `err_out: devres_release_group` → `ata_host_release` освобождает host, затем `err_free:` освобождает его ещё раз (двойной free; в апстриме исправлено 290073b2b557). С OCM это двойной `ppc4xx_ocm_free`. Срабатывает только при отказе выделения порта. |
| L6 | **low** | libata.h:1714–1718 | Макрос `ata_qc_from_tag` не учитывает `!ap->ops->error_handler`: для old-EH драйверов он вернёт NULL для FAILED qc, оригинал вернул бы qc. На этой сборке таких драйверов нет, так что последствие только для переносимости. |
| L7 | **info** | libata-core.c:742–750, 6058, 6590 | `ata_led_act()` нигде не вызывается (в OpenWrt он вызывается из `ata_qc_complete`), а `CONFIG_ATA_LEDS` в конфиге выключен: это мёртвый код. |
| L8 | **info** | libata-scsi.c ~3098–3125 | Развёрнутый `__ata_scsi_find_dev` эквивалентен оригиналу для не-PMP случая. В 4.19.325 `ata_find_dev` изменён апстримом (06520b993cc6), этот hunk и не применился. |

### 1.4 `995_block.patch` (bio.c, bio.h, blk-core.c, blkdev.h, blk-softirq.c)

**Что меняет:**
- `blk_start_plug`/`blk_finish_plug`, `bio_init` перенесены в заголовки как inline. EXPORT_SYMBOL при этом убраны, но модули получают inline-копию.
- `bvec_alloc` получил формулу `fls((nr-1) << ((nr>64)+1)) >> 1` вместо switch (bio.c:197).
- `bio_has_data` кэширует `bio_op`. `inline` на `__blk_complete_request` и `bvec_alloc`.

| # | Серьёзность | Где | Описание |
|---|---|---|---|
| B1 | **low** | include/linux/bio.h:86–95 | `unsigned int opf = bio_op(bio);` разыменовывает `bio` **до** проверки `bio &&`. Проверка на NULL теряет смысл, и компилятор вправе её выкинуть. Все in-tree вызовы (blk-core.c:2553, 3418; blkdev.h:1757; `bio_cur_bytes`/`bio_data`) передают не-NULL, так что дефект латентный. |
| B2 | **info** | bio.c:197–198 | Формулу я проверил для nr = 1, 2, 4, 5, 16, 17, 64, 65, 128, 129, 256: индексы 0–5 совпадают со switch. При `nr ≤ 0` получается `fls(0xFFFFFFFE) >> 1 = 16`, то есть OOB `bvec_slabs[16]` (оригинал возвращал NULL), но вызывающие передают `nr > inline_vecs ≥ 0`, так что это недостижимо. |
| B3 | **info** | blkdev.h:1347 | Inline-копии `blk_start_plug`/`blk_finish_plug` дословно совпадают с 4.19.99. Защита через самодельный `_BLKDEV_H` работает. `void inline` на экспортируемой функции корректен только в gnu89 (для 4.19 это верно). |

Реального эффекта на производительность нет: это пути в несколько десятков инструкций на bio.

### 1.5 `002_ppc4xx_ocm.patch`

Исправляет инвертированную проверку `debugfs_create_file()`: оригинал печатал ошибку и возвращал -1 при **успехе**. В 4.19 функция возвращает NULL при ошибке, так что исправление корректно (**info**, полезно). Сам аллокатор OCM (ocm.c) без блокировок (**low**, см. L3).

---

## 2. NCQ (`SATA_DWC_NCQ`)

### 2.1 Что делает `#define SATA_DWC_NCQ`

Он меняет **только** `can_queue` 1 → 32 (sata_dwc_460ex.c:1108–1112). Весь остальной «NCQ-код» уже скомпилирован и работает с глубиной 1. После включения libata/SCSI начнут держать до 32 FPDMA-команд и смешивать их с не-NCQ командами (FLUSH, SMART, SET FEATURES).

### 2.2 Полнота реализации — по пунктам

| Аспект | Состояние | Последствие при глубине > 1 |
|---|---|---|
| Выдача команды (`qc_issue`, 1050–1062) | Пишет SActive, taskfile и Command **без ожидания BSY = 0** после предыдущей команды. SFF-стиль NCQ требует дождаться D2H Register FIS с BSY = 0 (так делает, например, `sata_nv` swncq со своей очередью и defer). | Вторая команда, записанная, пока устройство BSY, перезаписывает shadow-регистры: команда теряется или искажается. **critical** |
| `qc_defer` | Отсутствует: `ata_sff_port_ops` наследует `ata_base_port_ops`, где нет `ata_std_qc_defer` (libata-core.c:87–93, libata-sff.c:46–70). | libata отправит FLUSH CACHE или другую не-NCQ команду при активных NCQ. По ATA это нарушение протокола: устройство абортирует всю очередь. Плюс `WARN_ON_ONCE(link->sactive)` в `ata_qc_issue`. **critical** |
| Учёт тегов (`sactive_issued`) | Обнуляется в начале каждого ISR (569), поэтому NCQ completion-цикл 666–749 мёртв (D14). | Любые завершения идут через ветку «один `active_tag`». |
| NCQ completion-цикл (если «оживить») | `while (!(tag_mask & 1)) { tag++; tag_mask <<= 1; }` (697–700) сдвигает **влево**: младший бит никогда не станет 1, маска обнуляется, и получается **бесконечный цикл в hardirq под host->lock** (жёсткое зависание). `ata_qc_from_tag` может вернуть NULL, а 706 разыменовывает `qc->ap`. `tag_to_mask_compl` неверен (D12). Нет `ata_qc_complete_multiple()`. | **critical** |
| `active_tag` | Драйвер сам пишет `ap->link.active_tag = tag` в NEWFP (608) и в ISR (630), хотя для NCQ libata держит `active_tag = POISON` и работает через `sactive`. | Ломаются инварианты libata (`WARN_ON_ONCE(ata_tag_valid(active_tag))` в `ata_qc_issue`, libata-core.c:5428). EH (`ata_sff_error_handler`) ищет не тот qc. |
| Завершение DMA и команды | Один глобальный счётчик чётности `dma_interrupt_count` (DMA-callback + SATA-IRQ = 2) на все теги. `dma_dwc_xfer_done` берёт тег из `active_tag` в момент срабатывания tasklet-а. | Последовательность NEWFP(A) → DMA(A) → NEWFP(B) → DMA(B) → SDB(A, B) завершит **B** по чётности до его SDB, а **A** не завершится никогда (таймаут 30 с). Один SDB FIS, закрывающий несколько тегов, завершает максимум один qc. **critical** (таймауты и EH-шторм; порча при завершении до конца DMA). |
| DMACR | NEWFP пишет DMACR целиком (`TXCHEN` **или** `RXCHEN`, 1006–1012). Callback предыдущего тега сбрасывает биты по `dma_pending[active_tag]` уже **нового** тега (366). | Отключение канала посреди передачи следующего тега, особенно при смене направления: зависание DMA. **high** |
| DMA на тег | `desc[tag]` готовится при выдаче, отправляется в NEWFP. Один канал DW DMA на порт — **это не проблема само по себе**: фазы данных SATA на линке и так последовательны, а dw_dma ставит дескрипторы в очередь. Проблема в учёте (строки выше) и в утечке неотправленных дескрипторов (D17). | — |
| Потеря прерываний | `clear_interrupt_bit` сбрасывает все биты INTPR (D8). При NCQ NEWFP и завершения часто совпадают. | Потерянные завершения, таймауты. **high** |
| Ошибки и таймауты | Нет freeze, нет `dmaengine_terminate`, `err_mask` не ставится (D2, D3). NCQ-EH читает log 10h, что при READ LOG DMA EXT ведёт к D1 (падение) и L1. | Первая же ошибка приводит к падению или порче. **critical** (до исправления D1/L1). |

**Итог:** это не «почти готовый» NCQ. Реализованы только выдача FPDMA и старт DMA по DMA Setup FIS; этого хватает для глубины 1. Учёт нескольких тегов, завершение, EH и сериализация выдачи отсутствуют.

### 2.3 Что говорят апстрим и сообщество

- В исходном драйвере с 2008 г. есть комментарий «test-only: Currently this driver doesn't handle NCQ correctly. We enable NCQ but set the queue depth to a max of 1. This will get fixed in a future release.» С тех пор NCQ в апстриме так и не доделали.
- Christian Lamparter (сопровождающий apm821xx в OpenWrt), openwrt-devel, февраль 2021: «The DesignWare IP-Core inside the APM82181 can only do SATA-2 and the driver does not have support for NCQ.»
- Серия Andy Shevchenko 2016 «ata: sata_dwc_460ex: make it working again» (перевод на generic dmaengine, при участии Måns Rullgård и Lamparter) NCQ не трогала, глубина осталась 1.
- 2022: Lamparter исправил OOB (CVE-2022-49073). Разбор в коммите совпадает с D1: `dma_pending[tag] = NONE` обнуляет `chan`, затем NULL-deref в `sata_dwc_qc_issue`.
- 2026 (linux-ide/lkml, Rosen Penev и др.): патчи-cleanup и фикс гонки `sactive_issued`. В обсуждениях отмечено, что completion-путь при нескольких тегах использует `active_tag` и даёт неверный результат, а в битовом сканере NCQ-цикла есть бесконечный цикл. Серию просматривал Niklas Cassel; NCQ она не включает.
- **Свидетельств, что NCQ аппаратно сломан в DWC-ядре, я не нашёл.** Регистры `FPTAGR/FPBOR/FPTCR` и прерывание `NEWFP` говорят о том, что ядро рассчитано на first-party DMA. Но и свидетельств рабочего NCQ > 1 на 460EX/APM82181 ни в апстриме, ни в OpenWrt нет. Аппаратная пригодность: **uncertain**.

### 2.4 Даст ли NCQ выигрыш

Почти никакого:
- Последовательное чтение и запись (121/115 МБ/с) уже упираются в скорость пластин WD30EZRS (5400 rpm, ~110–130 МБ/с на внешних дорожках). NCQ последовательный поток не ускоряет.
- NCQ помогает случайному I/O с глубокой очередью (переупорядочивание в диске, у 5400 rpm HDD порядка +10–30 % IOPS). Но deadline-планировщик уже сортирует запросы, а SMB на этом устройстве ограничен CPU (800 МГц PPC464), а не диском.
- Цена — больше прерываний и работы CPU на команду, а CPU и так узкое место.

### 2.5 Вердикт

**UNSAFE — не определять `SATA_DWC_NCQ`.** Ожидаемый результат: таймауты и EH-reset под нагрузкой, потерянные команды, при EH — падение (D1/L1), вероятная порча данных (завершение до конца DMA, DMA в чужой буфер).

Чтобы NCQ стал возможен, нужно минимум:
1. Исправить D1 (QCMD_MAX), L1 (вернуть `ata_port` в обычную память), D2 и D3 (`err_mask`, freeze, `dmaengine_terminate_sync` в EH и `post_internal_cmd`, сброс состояния и счётчика).
2. Добавить `.qc_defer = ata_std_qc_defer` и программную очередь выдачи с ожиданием BSY = 0 / D2H FIS, как в `sata_nv` swncq.
3. Убрать запись в `ap->link.active_tag`, вести состояние DMA-тега и чётность **по тегу**. Завершение делать по SActive: `done = issued & ~SActive` → `ata_qc_complete_multiple()`, при условии, что DMA тега завершён.
4. Исправить сканер тегов (`__ffs`, сдвиг вправо), `tag_to_mask_compl`, не обнулять `sactive_issued` в каждом ISR, очищать только обработанные биты INTPR, писать DMACR read-modify-write по направлению тега.
5. Нагрузочные тесты с fio (randread/randwrite, iodepth 32, смешанно с fsync) и инъекцией ошибок.

Объём работы — фактически переписать completion и EH драйвера, ради выигрыша, который на этом устройстве почти не виден.

**Практическая рекомендация на сейчас:** оставить глубину 1. Как необязательную меру снижения риска D1/L1 до ребейза можно рассмотреть `libata.force=noncq`. Тогда используется обычный READ/WRITE DMA EXT без NEWFP-пути, а ошибка чтения не вызывает NCQ-EH-чтение log 10h. Скорость должна остаться той же (uncertain, проверить dd/fio до и после). Лучшее решение — ребейз на 4.19.325 с исправлениями из раздела 3.

---

## 3. Апстрим 4.19.99 → 4.19.325 и ребейз

### 3.1 Изменения в драйверах этой платформы (`diff-drivers-99-325.diff`)

- `sata_dwc_460ex.c`:
  - **596c7efd69aa «Fix crash due to OOB write»** (CVE-2022-49073): `SATA_DWC_QCMD_MAX = ATA_MAX_QUEUE + 1`. **Обязателен** (D1).
  - **4c26ed04be9e «No need to call phy_exit() before phy_init()»**: error-путь probe переписан на прямые `return`. Именно он даёт отказ hunk #31 патча 996.
- `drivers/dma/dw`: только **5ec87f6958d7** (Kconfig `depends on HAS_IOMEM`). 997 применяется с fuzz, функциональных конфликтов нет.

### 3.2 Значимые коммиты ata-ядра (log-storage.txt)

| Коммит | Значимость для MBL |
|---|---|
| 596c7efd69aa sata_dwc OOB | **critical**, см. D1 |
| 30ac5bf460d4 libata: fix checking of DMA state | Высокая: `ata_read_log_page` использовал `dev->dma_mode &&` (0xff = «не задан» считалось true) и мог выбрать READ LOG DMA EXT, когда DMA не включён. Это прямо связано с триггером D1/L1. |
| bf18a04bd0c5 libata: fix read log timeout value | Средняя (EH/READ LOG) |
| 61295b8cadb6 if T_LENGTH is zero, dma direction should be DMA_NONE | Средняя: SG_IO passthrough от smartctl/hdparm. У sata_dwc неверное направление ведёт к подготовке DMA-дескриптора для non-data команды. |
| 290073b2b557 / f7827b47e9b2 / d9c4df80b1b0 / a810bd5af069 | Error-пути `ata_host_alloc`/`alloc_pinfo` (двойной free, утечка, NULL). **Конфликтуют с OCM-частью 994.** |
| 06520b993cc6 Use correct device no in ata_find_dev() | Конфликтует с 994 (libata-scsi) |
| 040251185b9d, af72179da9a3, edcb7efdbb96, 7371ef43c7e9 | Удаление портов и устройств, PM-блокировки, detach: shutdown/rmmod/отказ диска |
| e2b7e0a9b430 libata-eh: do not clear ATA_PFLAG_EH_PENDING in ata_eh_reset() | Средняя: корректность EH |
| 15402e0e8433 Fix sata_down_spd_limit() | Средняя: понижение скорости линка при ошибках |
| 11e6b688936b mode_select page_address, 0994f3e464ff REPORT SUPPORTED OPCODES, 0dfadcf9e9e4 ata_host_start | Низкая или средняя |
| 5d4f303010b7 ata_pio_sector HIGHMEM | Неприменимо (HIGHMEM выключен), но фикс того же места, что затрагивает L1 |
| c9a512f8fa91 / a34e3ce81dc8 qc_prep returns ata_completion_errors | Нейтрально: sata_dwc использует noop `qc_prep` |
| ahci/pata/sata_mv/nv/fsl/PMP/SAS/LPM | Неприменимо |

### 3.3 Блок-слой (legacy request path + deadline, без bfq/cfq/blk-mq по умолчанию)

Применимые:
- **18243d8479fd** `bio_copy_kern` + `__GFP_ZERO` (CVE-2022-0494, утечка через SG_IO).
- **473d7f5ed75b** blktrace RCU (CVE-2019-19768), если используется blktrace.
- **3d13ebbd0669** UAF в `disk_part_iter_next`.
- **b0393aadc2d2** NULL в `register_disk`.
- **cc019421d037** unhash part inode.
- **6a139c9ec508** «Fix fsync always failed if once failed».
- **d2d0b95ca1b5** «Remove special-casing of compound pages»: ошибки в bvec при compound-страницах. Uncertain, но при 16K-страницах и THP/compound это стоит иметь.
- **108d5817b044** выравнивание `max_sectors`.
- **732fd460bb72 / fd397508347f** `io_pages`.
- **fa137b50f326, 6c63a7be2b11, ee3d84e67d01** гонки при смене elevator через sysfs.
- **ee12aa483f6c / 602210ebc391** `blk_validate_block_size` (loop/nbd).
- **23047a238f44** ioprio_get.
- **6281beee5bb9** merge across cgroup — если включён blkcg.

Неприменимые: bfq (выключен), blk-mq-специфичные (9525b38180e2, 3e62d49f597f — если не включён `scsi_mod.use_blk_mq=1`), zoned, integrity, discard (HDD без TRIM), compat_ioctl (ppc32).

### 3.4 Как ребейзить 996 и 994 на 4.19.325

**996:**
1. Применить патч. Отклонённый hunk #31 — это только косметика: замена `&ofdev->dev` на `dp` в `dev_err` для «no SATA DMA irq». Его **отбросить**: апстрим теперь делает `return -ENODEV` без `goto error_out`.
2. Убедиться, что сохранилось `#define SATA_DWC_QCMD_MAX (ATA_MAX_QUEUE + 1)`. 996 эту строку не трогает, и в `patched-v4.19.325/.../sata_dwc_460ex.c:159` она на месте.
3. Одновременно рекомендую:
   - `ppc4xx_ocm_alloc` с проверкой NULL и fallback на `devm_kzalloc` — или просто вернуть `devm_kzalloc` (D4).
   - Вернуть `ata_qc_from_tag` в NEWFP и проверку POLLING (D5, D6).
   - Возвращать `IRQ_RETVAL(handled)` (D7).
   - Выставлять `err_mask` при ATA_ERR (D2).
   - Делать `dmaengine_terminate_sync` и сброс `dma_interrupt_count`/`dma_pending` в `.error_handler` и `.post_internal_cmd` (D3).
   - Маскировать `fptagr & 0x1f`.

**994** (3 отказавших hunk-а):
1. `libata-core.c` hunk #16 (`ata_host_alloc`, ~6175): апстрим убрал метку `err_free` и добавил `kfree(host)` в двух ранних выходах (после `devres_open_group` и `devres_alloc`). Если OCM-размещение сохраняется, обе `kfree(host)` заменить на `#ifdef ALLOCATE_ATA_HOST_ON_OCM ppc4xx_ocm_free(host) #else kfree(host)`. После `devres_add` host освобождается только через `ata_host_release` (двойного free больше нет). **Рекомендация: отказаться от `ALLOCATE_ATA_HOST_ON_OCM` и `ALLOCATE_ATA_PORT_ON_OCM` полностью** (L1, L3, L4). Тогда этот hunk и hunk-и `ata_host_release`/`ata_port_alloc` не нужны.
2. `libata-scsi.c` hunk #3 (~3098, `ata_find_dev`/`__ata_scsi_find_dev`): не переносить. Оставить новую апстримную `ata_find_dev` (06520b993cc6). **Удалить** макрос `#define ata_scsi_find_dev(...) __ata_scsi_find_dev(...)` и вернуть функцию с проверкой `ata_dev_enabled` (L2).
3. `include/linux/libata.h` hunk #1 (строка 38): изменился контекст, апстрим добавил `#include <linux/async.h>`. Вставить `#ifdef CONFIG_ATA_LEDS #include <linux/leds.h>` вручную. Поскольку `ATA_LEDS` выключен и `ata_led_act` не вызывается, LED-часть можно выбросить целиком.
4. Макросы `ata_qc_from_tag`/`__ata_qc_from_tag` в libata.h выгоды не дают; их лучше убрать (L6).

**997, 995, 002** применяются (fuzz/ok). После ребейза стоит изменить `max_block_bytes` в 997 на 8192 (D9, W1).

---

## 4. Приоритетный список действий

1. **critical:** ребейз на 4.19.325 или минимум backport 596c7efd69aa (`SATA_DWC_QCMD_MAX = ATA_MAX_QUEUE + 1`) и 30ac5bf460d4.
2. **high:** убрать OCM-размещение `ata_port`/`ata_host` (994) и `hsdev` (996) — или хотя бы `ata_port`, где лежат DMA-буферы.
3. **high:** в драйвере — `err_mask` при ATA_ERR; остановка dw_dma и сброс состояния в EH и `post_internal_cmd`.
4. **medium:** вернуть проверку `ata_dev_enabled` в `ata_scsi_find_dev`; вернуть проверки в NEWFP и POLLING; `IRQ_RETVAL(handled)`.
5. **medium:** LLI по 8192 байта в 997.
6. **NCQ:** не включать. До ребейза при желании — `libata.force=noncq` (проверить скорость до и после).
7. Проверить на устройстве: `hdparm -I /dev/sda | grep -i READ_LOG_DMA` (есть ли триггер D1/L1), `cat /sys/kernel/debug/ppc4xx_ocm/info` (заполненность OCM), `dmesg | grep -i "sata-dwc\|dma not pending\|out of sync\|SError"`.

## Источники (веб)

- Stable-бэкпорт OOB-фикса в 4.19: https://lore.kernel.org/lkml/20220414110848.025150856@linuxfoundation.org/
- Текст коммита (lkml): https://lkml.iu.edu/hypermail/linux/kernel/2204.1/04916.html
- CVE-2022-49073: https://ubuntu.com/security/CVE-2022-49073
- Lamparter об отсутствии NCQ: https://lists.openwrt.org/pipermail/openwrt-devel/2021-February/033988.html
- Серия Shevchenko 2016: https://lore.kernel.org/patchwork/cover/671186/
- Патчи 2026 (гонка `sactive_issued`, cleanup): https://ratatoskr.run/lkml/2026/09/17534005/t, https://ratatoskr.run/lkml/2026/07/17201601/t
