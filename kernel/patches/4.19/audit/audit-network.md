# Аудит сетевых патчей 4.19 для WD My Book Live (APM821xx)

Проверены патчи из `C:\GitHub\My-Book-Live\kernel\patches\4.19\patches`:

- `992_ibm_emac+netconsole.patch`;
- `993_net_core_dev.patch`;
- `991_skbuff_perf.patch`;
- `990_ipv4_tcp_perf.patch`;
- `702-phy_add_aneg_done_function.patch`.

Смотрел итоговый код после наложения патчей: `C:\tmp\k419\patched-v4.19.99\...`. Ссылки вида `core.c:NNN` и `mal.c:NNN` относятся к `patched-v4.19.99/drivers/net/ethernet/ibm/emac/`. Конфигурация взята из `kernel/patches/4.19/config/.config.4.19`: `CONFIG_APM821xx=y`, `IBM_EMAC_TXB/RXB=256`, `POLL_WEIGHT=64`, `RX_COPY_THRESHOLD=256`, `INTR_COALESCE=y` (TX 40/0, RX 32/100000), `SYSFS=y`, `TAH=y`, `NETCONSOLE=y`, `NETPOLL=y`. DT: `mbl-debian/config/dts/apm82181.dtsi`, MAL с `descriptor-memory = "ocm"`, 1 TX и 1 RX канал.

Уровни: **critical / high / medium / low / info**. Пометка «(upstream)» значит, что дефект есть и в стоковом 4.19.99, а не внесён патчем. Пометка «(неуверенно)» значит, что вывод зависит от поведения железа или от фактов, которые я не смог проверить по исходникам.

---

## 0. Главное

| # | Уровень | Где | Суть |
|---|---|---|---|
| C1 | **critical** | mal.c:531-535 (и core.c:1560-1564) | При сбросе слишком длинного SG-кадра `rx_sg_append()` обнуляет локальную переменную, а не `dev->rx_sg_skb`. Остаётся висячий указатель, дальше use-after-free, double free или запись в чужой буфер. Срабатывает от одного кадра из L2-сегмента (jumbo/oversize). |
| H1 | **high** | core.c:1246-1267, tah.c:44-63, core.c:504, core.c:965-985 | TSO через TAH режет по SSR0 и игнорирует `gso_size`. SSR0 сбрасывается в 1500 при каждом `emac_configure()`, но после смены MTU «на ходу» может остаться 4080. Итог: сегменты больше MSS/PMTU, «чёрные дыры» через VPN/PPPoE, зависания при jumbo. |
| H2 | **high** | mal.c:785-807 | `mal_poll()` разыменовывает `mal->poll_commac` до проверки на NULL и всегда вызывает `poll_tx()`. После `ifdown` (`mal_poll_del()` → NULL) любое отложенное прерывание MAL даёт oops. |
| H3 | **high** | core.c:252-257 (upstream) + core.c:3030 (патч) | Ошибка приоритета операторов в `emac_rx_enable()` после RXDE может сбросить `MR0.TXE`, и TX встаёт. Патч поднял `watchdog_timeo` с 5 до 100 с, поэтому сеть «висит» до 100 с. |
| M1 | medium | 990, tcp_output.c:2341-2342 | Убран `tcp_pacing_check()`: утечка refcount сокета (`sock_hold` на каждый пакет) при внутреннем pacing. Это локальный DoS без привилегий через `SO_MAX_PACING_RATE`. |
| M2 | medium | mal.c:767-777 | `peek_rx_sg()` шагает по кольцу через 2 дескриптора (`u16* += sizeof(desc)`) и читает за концом кольца. |
| M3 | medium (неуверенно) | mal.c:1036-1051, 1161-1191 | Индексы coalescing-IRQ: при одном канале RX-обработчик вешается на DT-прерывание №6 (`tx1coal`), а EOB-прерывания не запрашиваются. `TxTimer=0`. |
| M4 | medium (upstream) | core.c:875-949 / 952-992 | Смена MTU под трафиком: RX перезапускается раньше, чем обновлены `rx_skb_size`/`rx_sync_size`. Возможен DMA-overflow буфера skb. |
| M5 | medium (upstream) | mal.c:781-807, core.c:654-667, 994-1006 | Гонка `poll_tx()` с `emac_clean_tx_ring()` в путях сброса: возможен double free skb. |

**Рекомендации кратко:**

1. Сразу исправить C1 (одна строка), H2, H3.
2. TSO: либо выключить (`ethtool -K eth0 tso off`), либо переписать выбор SSR через `ndo_features_check`.
3. Патч 990 выбросить целиком: выигрыш пренебрежимый, есть утечка.
4. 993 и 702 фактически мёртвый код.
5. Watchdog вернуть к 5 с.

---

## 1. 992_ibm_emac+netconsole.patch

### 1.1 Назначение

Это переписывание драйвера `drivers/net/ethernet/ibm/emac` под APM821xx:

- NAPI-пути `poll_tx`/`poll_rx`/`peek_rx_sg` перенесены в `mal.c` и специализированы под один канал (`mal->poll_commac` вместо списков);
- MAL interrupt coalescing через SDR0 ICC (`mal_enable_coal`), параметры через ethtool и sysfs;
- MAL-инстанс и кольца дескрипторов в OCM (некэшируемая on-chip память);
- TAH: аппаратный TX-checksum и TSO (`NETIF_F_TSO`, `EMAC_HW_TSO` в core.h:62), sysfs для SSR0..5;
- jumbo (MTU до `max-frame-size` из DT), выбор набора SSR по MTU;
- PHY BCM54610 (`CONFIG_APOLLO3G`), запрет half-duplex;
- sysfs coalescing, EMI-fix (`MASK_CEXT` выключен);
- «netconsole»: только пустой `ndo_poll_controller`;
- косметика: likely/unlikely, register, `__always_inline`, кэш `tmr0`.

Прирост скорости почти наверняка дают TSO+TAH, coalescing (меньше прерываний), кольца 256/256 и copybreak. Изменения в TCP-стеке (990) на скорость практически не влияют (см. §4).

### 1.2 Дефекты

#### C1 — critical: висячий `rx_sg_skb` в `rx_sg_append()` (UAF / double free / переполнение кучи)

`mal.c:524-545` (рабочая копия; такая же ошибка в неиспользуемой `core.c:1553-1574`):

```c
if (unlikely(tot_len + NET_IP_ALIGN > dev->rx_skb_size)) {
        ++dev->estats.rx_dropped_mtu;
        dev_kfree_skb(skb_sgp);
        skb_sg = NULL;          /* <-- обнуляется ЛОКАЛЬНЫЙ указатель, а не *skb_sg */
```

В upstream 4.19.99 здесь `dev->rx_sg_skb = NULL;` (v4.19.99 core.c:1716-1719). Ошибка внесена патчем при переписывании на `struct sk_buff **skb_sg`.

**Сценарий.** Кадр длиннее одного RX-буфера MAL приходит несколькими дескрипторами (FIRST, …, LAST). Если суммарная длина больше `rx_skb_size - 2`, skb освобождается, но `dev->rx_sg_skb` продолжает на него указывать. Далее:

- **Кадр из 3 и более дескрипторов.** Следующий дескриптор вызывает `rx_sg_append()` с уже освобождённым skb. Код читает `len` из освобождённой памяти и выбирает одно из двух:
  - `memcpy(skb->tail, data, len)`, то есть данные из сети записываются в чужую или освобождённую память;
  - повторный `dev_kfree_skb()`.

  На LAST-дескрипторе освобождённый skb отправляется в стек (`netif_receive_skb`). Голова skb почти сразу переиспользуется: `napi_alloc_skb()` для следующего пакета берёт тот же объект из `skbuff_head_cache` по LIFO. Значит, «чужой» skb легко оказывается живым, в том числе маленьким copybreak-skb (≤256 байт). Проверка же идёт против `dev->rx_skb_size`, а не против реального размера буфера, поэтому возможна **запись в кучу ядра данных, которые контролирует атакующий**.
- **Кадр из 2 дескрипторов.** Указатель остаётся висячим до следующего FIRST, где он перезаписывается. Но пути `mal.c:685-690` (RXDE / RX_STOPPED), `emac_resize_rx_ring()` (core.c:885-889), `core_reset()` (core.c:2098-2102) и `emac_clean_rx_ring()` при `ifdown` (core.c:1019-1022) делают `dev_kfree_skb(dev->rx_sg_skb)`. Это double free, либо освобождение чужого, уже переиспользованного skb.

**Условия срабатывания.** При MTU 1500: RCBS = 1520, `rx_skb_size` = 1536, срабатывает кадр длиннее ~1534 байт. При MTU 4080: RCBS = 4080, `rx_skb_size` = 4128, срабатывает кадр длиннее ~4126 байт, например любой jumbo 9000 от хоста с MTU 9000 в той же сети.

Срабатывает, если EMAC/MAL реально пишет в DMA такие кадры, помечая их `PTL`, а не обрезая. Бит `EMAC_RX_ST_PTL` проверяется только на LAST, *после* `rx_sg_append()`. Наличие счётчика `rx_dropped_mtu` в upstream говорит, что такие кадры до этой точки доходят (неуверенно, стоит проверить).

**Последствия:** порча памяти ядра, oops/panic, потенциально удалённое выполнение кода атакующим в том же L2-сегменте (Wi-Fi гость, соседний хост, скомпрометированное IoT-устройство). Это очень правдоподобное объяснение «jumbo иногда вешал LAN» из заметок автора.

**Исправление:**

```c
dev_kfree_skb(skb_sgp);
*skb_sg = NULL;
```

То же сделать в `core.c:1563`. Заодно вернуть защиту в FIRST-ветке (mal.c:636-648): если `dev->rx_sg_skb != NULL`, освободить его, а не молча перезаписывать (сейчас там утечка).

**Проверка на железе:** с хоста с MTU 9000 выполнить `ping -s 8000 <mbl>` и параллельно смотреть `ethtool -S eth0 | grep -E 'rx_dropped_mtu|packet_too_long'`. Если счётчик `rx_dropped_mtu` растёт, баг достижим.

#### H1 — high: TSO через TAH игнорирует `gso_size`, SSR0 неконсистентен

- `emac_tx_csum()` (core.c:1246-1267) для **любого** GSO TCP skb возвращает `EMAC_TX_CTRL_TAH_SSR0`. Автор сам закомментировал «технически правильный» вариант (core.c:1255-1261), который к тому же был неверен: считал от `skb->len`. Аппарат знает о размере сегмента только через SSR-регистры (tah.h:30-35, `SS_2_TAH_SSR`, полуслова). `gso_size`, который выбрал TCP (MSS для данного соединения), до железа **не доходит**.
- `tah_reset()` (tah.c:44-63) при каждом вызове переписывает SSR0..5 значениями по умолчанию `{1500,1400,1280,576,256,68}`. Она вызывается из `emac_configure()` (core.c:504), то есть при `open`, link up (core.c:1185), `emac_reinitialize` при link down, tx-timeout (`reset_work`), sysfs `core_reset`, jumbo resize.
- `emac_change_mtu()` (core.c:965-985) ставит SSR0 = новый MTU, но **после** `emac_resize_rx_ring()` → `emac_full_tx_reset()` → `tah_reset()`. MTU, заданный до `ifup`, затирается в `emac_open()` → `emac_configure()`.

**Следствия.** Предполагаю, что SSR задаёт размер IP-датаграммы: иначе при MTU 1500 и SSR0 = 1500 LAN бы не работал. Тогда:

1. **MTU 1500, собеседник с MSS < 1460.** Это клиенты через VPN (WireGuard/OpenVPN), PPPoE-роутер с MSS clamping, пир после PMTUD, `TCP_MAXSEG`. TAH всё равно шлёт 1500-байтные IP-пакеты. С DF=1 роутер их отбрасывает и шлёт ICMP «frag needed». TCP уменьшает `mss_cache`, но TAH продолжает резать по 1500. Получается **PMTU black hole**: мелкие пакеты проходят, bulk-передача (скачивание с NAS по VPN) виснет.
2. **MTU 4080 выставлен на поднятом интерфейсе.** SSR0 = 4080 до ближайшего `emac_configure()`. Хостам с MTU 1500 (MSS 1460) уходят кадры по 4080 байт, коммутатор или их NIC их отбрасывает, TCP «висит». После любого link flap SSR0 снова 1500 и «само проходит». Это вторая правдоподобная причина «jumbo иногда вешал LAN».
3. **MTU < 1500 выставлен при загрузке.** SSR0 = 1500 больше MTU, TSO-кадры превышают MTU интерфейса.
4. Удалённый пир может заставить NAS нарушать его MSS. Это не порча памяти, но отказ в обслуживании конкретного соединения, плюс нарушение RFC 879/9293.

**Исправление:** реализовать `ndo_features_check()`. Если `skb_is_gso(skb)` и `gso_size + skb_transport_offset(skb) + tcp_hdrlen(skb) - ETH_HLEN` (длина IP-пакета) не совпадает ни с одним `dev->ssr[i]` (или > MTU, или не кратно 2), возвращать `features & ~NETIF_F_GSO_MASK`: стек сделает программный GSO. В `emac_tx_csum()` выбирать `EMAC_TX_CTRL_TAH_SSR(i)` по совпадению. В `tah_reset()` не затирать SSR, а восстанавливать `dev->ssr[]`, либо программировать SSR0 = MTU в `emac_configure()`.

Также проверить TAH-ограничения из вендорского драйвера AMCC: там требовалась кратность 8 и ограничение размера (неуверенно).

**Обходной путь:** `ethtool -K eth0 tso off`. Checksum offload остаётся. Throughput упадёт, но корректность будет гарантирована. Стоит замерить: при 800 МГц часть выигрыша может сохраниться за счёт coalescing и SG.

#### H2 — high: NULL-разыменование в `mal_poll()` после `ifdown`

`mal.c:785-807`:

```c
register struct mal_commac *mc = mal->poll_commac;
register struct emac_instance *dev = mc->dev;   /* до проверки mc != NULL */
...
poll_tx(dev);                                   /* безусловно */
...
if (likely(mc && !test_bit(...)))               /* проверка слишком поздно */
```

`emac_close()` → `mal_poll_del()` ставит `poll_commac = NULL` (mal.c:163-164). NAPI при этом остаётся включённым: `napi_disable` вызывается только в `mal_unregister_commac`. IRQ-обработчики MAL остаются зарегистрированными: coalescing TX/RX, RXDE, SERR. Отложенный RX-coalescing таймер (500 мкс) или RXDE после закрытия вызывает `mal_schedule_poll()` → `mal_poll()` → чтение `NULL->dev` → oops в softirq.

Upstream обходит список `poll_list`, который после `list_del` пуст, поэтому безопасен.

**Исправление:** в начале `mal_poll()`:

```c
if (unlikely(!mc)) { napi_complete_done(napi, 0); return 0; }
```

`poll_tx()` вызывать только если `mc` не NULL. Лучше также не вызывать `poll_tx()` при `MAL_COMMAC_POLL_DISABLED` (см. M5).

#### H3 — high: `emac_rx_enable()` может выключить передатчик; watchdog 100 с

`core.c:252-257`:

```c
while (!(r = in_be32(&p->mr0) & EMAC_MR0_RXI) && n--) udelay(1);
...
out_be32(&p->mr0, r | EMAC_MR0_RXE);
```

`=` имеет более низкий приоритет, чем `&`, поэтому `r` становится равным только биту `RXI`, и в MR0 пишется `RXI|RXE`: **`TXE` (и `WKE`) сбрасываются**. Путь срабатывает, если RX ещё не остановился после асинхронного `emac_rx_disable_async()`:

- RXDE (переполнение RX-кольца), когда при 100% CPU во время SMB-записи NAPI не успевает разгребать кольцо. Автор сам отключил прерывание RXOE «из-за массы overrun'ов», core.c:631-632;
- далее в `poll_rx` (mal.c:677-696) вызывается `emac_rx_enable()`, пока идёт приём кадра (jumbo-кадр при 1 Гбит длится ~33 мкс).

Итог: TX остановлен, очередь заполняется, восстанавливает только `ndo_tx_timeout`. Патч поднял `ndev->watchdog_timeo` до **100·HZ** (core.c:3030; в upstream 5·HZ), значит интерфейс может молчать до 100 секунд.

Сама ошибка приоритета есть и в upstream 4.19.99 (v4.19.99 core.c:263), вероятно и в mainline (неуверенно). Патч сделал последствия тяжелее.

Попутно: из-за `n--` (вместо upstream `--n`) после исчерпания таймаута `n == -1`, и сообщение «RX disable timeout» никогда не печатается (core.c:254-255, 270-271).

**Исправление:**

```c
while (!((r = in_be32(&p->mr0)) & EMAC_MR0_RXI) && n) { udelay(1); --n; }
```

и `watchdog_timeo = 5 * HZ`.

**Диагностика:** `ethtool -S eth0 | grep rx_stopped` (счётчик RXDE) и `dmesg | grep 'tx timeout'`.

#### M2 — medium: `peek_rx_sg()` неправильно шагает по кольцу

`mal.c:767-777`:

```c
register u16 *rx_desc_ctrl = (u16 *)&dev->rx_desc[slot];
...
rx_desc_ctrl += sizeof(struct mal_descriptor);   /* +8 элементов u16 = +16 байт = +2 дескриптора */
```

Указатель уходит на 2 дескриптора за шаг, а счётчик `slot` на 1. Поэтому:

- для SG-кадра (FIRST на `rx_slot`) проверяется `rx_slot+2` вместо `rx_slot+1`. Готовый 2-дескрипторный кадр может быть «не замечен» и «гниёт» до следующего IRQ (задержка до 500 мкс при текущем coalescing);
- при `rx_slot` около конца кольца чтение уходит **за конец кольца дескрипторов** (до ~2 КБ). Это OCM, там лежат соседние выделения, например mal_instance или ATA-структуры из 994. Мусор приводит к ложным «rotting packet» с лишними `napi_reschedule`, либо к пропускам;
- убрана upstream-защита от бесконечного цикла (`if (slot == dev->rx_slot) return 0;`).

Та же ошибка в неиспользуемой `core.c:1709-1720`.

**Исправление:**

```c
slot = NXT_RX_SLOT(slot); ctrl = dev->rx_desc[slot].ctrl;
```

с выходом, если `slot == dev->rx_slot`.

#### M3 — medium (неуверенно): маршрутизация coalescing-прерываний, TxTimer = 0

- `mal.c:1036-1051`: индекс IRQ растёт подряд, `tx: 5 .. 5+N-1, rx: 5+N ...`. В DT (`apm82181.dtsi:175-187`) порядок `tx0coal, tx1coal, rx0coal, rx1coal` (индексы 5,6,7,8). При `num-tx-chans = 1` обработчик «RX0 COAL» получает прерывание №6 (`tx1coal`, UIC2 9), а `rx0coal` (UIC2 12) **не запрашивается**. Если имена в DT верны, прерываний по приёму нет. RX обрабатывается «попутно»: по TX-coalescing (каждые 40 TX-дескрипторов), по RXDE и через `napi_reschedule` в «rotting»-проверке. Это давало бы большие задержки на чистом приёме. Раз производительность хорошая, возможно, на APM82181 нумерация иная. **Проверить `/proc/interrupts`: растут ли счётчики «RX0 COAL» при чистом приёме, например `iperf3 -R` в обратную сторону.**
- При включённом coalescing обычные `MAL TX/RX EOB` IRQ вообще не запрашиваются (mal.c:1161-1177). Если coalescing-линия не та или «молчит», нет никакого запасного пути.
- `TxTimer = 0` (конфиг): семантику 0 для `SDR0_ICCTRTX0` проверить по документации. Если это «таймер выключен», завершения TX пакетов в хвосте пачки (<40 дескрипторов) не забираются до следующего RX-события. skb висят, TSQ (`tcp_small_queue_check`) тормозит отправку, UDP-отправители блокируются на `sk_wmem`. Рекомендую ненулевой TX-таймер, 50–200 мкс.
- `mal_remove()` (mal.c:1249-1253) делает `free_irq(txeob/rxeob)`, которые при coalescing не запрашивались. Будет WARN «Trying to free already-free IRQ» (low).

#### M4 — medium (upstream): смена MTU под трафиком и DMA-переполнение

`emac_resize_rx_ring()` (core.c:875-949) перезапускает RX и NAPI (`emac_netif_start`, core.c:945) и ставит RCBS = `emac_rx_size(new_mtu)`, то есть 4080 при jumbo. Но `dev->rx_skb_size`/`dev->rx_sync_size` обновляются только потом в `emac_change_mtu()` (core.c:987-988). В этом окне `alloc_rx_skb_napi()` (mal.c:567-572) выделяет skb старого размера (1536) и мапит старый `rx_sync_size`, а MAL уже может писать до 4080 байт. Результат — DMA за пределы буфера и порча кэша на некогерентном 44x.

Так же и в upstream. Окно маленькое (пара мьютексов `tah_set_ssr`), но при jumbo-экспериментах достижимо.

**Исправление:** присваивать `rx_skb_size`/`rx_sync_size` внутри `emac_resize_rx_ring()` до `mal_enable_rx_channel()`.

#### M5 — medium (upstream, усилено патчем): гонка `poll_tx()` и очистки TX-кольца

`emac_full_tx_reset()` → `emac_clean_tx_ring()` (core.c:654-667, 994-1006) работает без `netif_tx_lock`. `mal_poll_disable()` только ждёт текущий poll (`napi_synchronize`), но не запрещает новые. `mal_poll()` вызывает `poll_tx()` безусловно (mal.c:805, 869), даже при `POLL_DISABLED`.

На UP softirq на выходе из IRQ может вклиниться между `dev_kfree_skb(tx_skb[i])` и `tx_skb[i] = NULL`, что даёт double free. Кроме того, `poll_tx` декрементирует `tx_cnt`, который в это время обнуляется. Upstream имеет ту же структуру. Патч добавил новые пути полного сброса (sysfs `core_reset`, jumbo resize).

**Исправление:** в `poll_tx` проверять `MAL_COMMAC_POLL_DISABLED`, а в `emac_clean_tx_ring()` брать `netif_tx_lock_bh()`.

#### M6 — medium (upstream): мьютекс под спинлоком в `ndo_set_rx_mode`

`emac_set_multicast_list()` (core.c:841-854) вызывается ядром под `netif_addr_lock_bh`, а берёт `mutex_lock(&dev->link_lock)`. Мьютекс удерживается `emac_link_timer()` раз в секунду на время MDIO-чтений. При конкуренции получаем «scheduling while atomic». Триггеры: IGMP-join от avahi/samba, `ip maddr`. Есть в upstream 4.19.

#### L1 — low: sysfs без валидации, `core_reset()` без rtnl

- `store_tx_count/rx_count/tx_time/rx_time` (core.c:2116-2169): `simple_strtol` без проверок. `rx_count=0` при `rx_time=0` может полностью остановить RX-прерывания, так как EOB-IRQ не запрошены (см. M3). Отрицательные и огромные значения пишутся в SDR как есть (count маскируется до 9 бит).
- `core_reset()` (core.c:2093-2113) вызывается из sysfs без `rtnl_lock` и без проверки `dev->opened`. Гонка с `emac_close()` приведёт к перезапуску MAL-каналов на закрытом интерфейсе с `rx_skb[] = NULL`, и `poll_rx` разыменует NULL.
- `store_tah_ssr` (core.c:2209-2218): SSR = 0 или нечётное значение не проверяется. SSR = 0 при TSO даёт неопределённое поведение TAH и вероятный TX hang.
- `emac_ethtool_set_coalesce` (core.c:2024-2036): `usecs * plb_bus_freq` может переполниться, валидации нет.

Всё это только root (`S_IWUSR`, `CAP_NET_ADMIN`), поэтому low, но это «ружья» для самострела. Комментарий автора «FIXME: … it hangs» (core.c:2125) указывает на связанные проблемы.

#### L2 — low: регрессии в probe/remove

- `emac_remove()` (core.c:3108-3137) **не вызывает `unregister_netdev()`** (в upstream есть, v4.19.99 core.c:3235). `free_netdev()` на зарегистрированном устройстве даёт `BUG_ON(reg_state != NETREG_UNREGISTERED)`. Проявится только при unbind через sysfs, так как драйвер встроенный.
- `emac_probe()` (core.c:3070-3077): при ошибке `sysfs_create_group()` возвращается ошибка уже *после* `register_netdev()`. Сетевое устройство остаётся зарегистрированным, а devm-ресурсы (`mii_bus`) освобождаются, что ведёт к UAF. Лучше `ndev->sysfs_groups[0] = &ibm_emac_attr_group` до регистрации, это заодно убирает гонку с udev.

#### L3 — low: OCM-выделение MAL

- `mal.c:946-955`: `memset(mal, …)` до проверки `mal != NULL`. Если OCM исчерпан (его делят ATA из 994, sata_dwc из 996 и др.), получаем oops при загрузке вместо отката на `kzalloc`.
- `mal.c:1227-1228` и `mal.c:1269`: `kfree(mal)` для памяти из `ppc4xx_ocm_alloc()` даёт crash на пути ошибки или remove. Нужен `ppc4xx_ocm_free()`.
- `mal.c:996-998`: `goto fail` вместо `goto fail_unmap`, утечка DCR-мэппинга. Исправлено в upstream 4bd7823cacb2; на APM (`mcmal2`) путь не достигается.
- (неуверенно) `mal_instance` целиком лежит в некэшируемой OCM: `napi_struct`, `dummy_dev`, флаги commac. По ним идут атомарные операции (`cmpxchg`/`set_bit` через `lwarx/stwcx.`) по caching-inhibited памяти. Архитектурно это зависит от реализации, на PPC464 эмпирически работает. `memset` по CI-памяти вызывает alignment exception на `dcbz` и эмулируется, это работает, но медленно (однократно). Выигрыш от размещения `napi_struct` в некэшируемой памяти сомнителен: кэшируемая SDRAM-копия, вероятно, быстрее. Дескрипторы в OCM — разумная идея.
- `mal_unregister_commac()` (mal.c:76-78): `napi_disable()`, который может спать, вызывается под `spin_lock_irqsave` (upstream).

#### L4 — low: netpoll/netconsole

- `emac_netpoll()` (core.c:2836-2838) пустой. В 4.19 `ndo_poll_controller` уже необязателен, так что заглушка ничего не даёт. NAPI висит на `mal->dummy_dev`, поэтому netpoll не может забрать завершения TX. Плюс в том, что нет реентерабельности `poll_rx` из netpoll.
- Если `panic` или printk идут с выключенными IRQ, после заполнения TX-кольца (256) сообщения netconsole теряются. `netpoll_send_skb` на каждое сообщение до 1 jiffy крутится впустую. Для консоли паники это приемлемо.
- xmit из hard-IRQ (netpoll) против `poll_tx` в softirq: netpoll использует trylock, дедлока нет. В upstream есть относящийся к этому фикс 9f313bcb3b3d («net: disable netpoll on fresh napis»).

#### L5 — low / info: прочее

- **RX checksum (upstream).** `rx_csum()` (mal.c:509-517) ставит `CHECKSUM_UNNECESSARY` любому кадру без битов ошибок TAH, включая IPv6, фрагменты и не-IP. Если TAH проверяет только IPv4 TCP/UDP (неуверенно), повреждённые IPv6 TCP/UDP данные и собранные фрагменты не будут перепроверены. Это вопрос целостности, не безопасности. `NETIF_F_RXCSUM` не входит в `hw_features`, выключить через ethtool нельзя.
- В FIRST-ветке (mal.c:636-648) закомментирован `BUG_ON(dev->rx_sg_skb)`: при потере LAST skb течёт.
- `NXT_TX_SLOT`/`NXT_RX_SLOT` (core.h:85-94) без внешних скобок и с `;` на конце. Сейчас используются только как операторы; хрупко.
- `EMAC4_RMR_MJS(ndev->mtu)` (core.c:424-428, upstream): если MJS считается по длине кадра с заголовками, полноразмерные jumbo-кадры помечаются PTL (неуверенно).
- RX FIFO high-watermark поднят до 3/4 (core.c:619-620). Для 16K FIFO с jumbo 4080 запас после PAUSE около одного jumbo-кадра, возможны overrun'ы. Отключено прерывание RXOE (core.c:632), overrun'ы видны только в `rx_bd_overrun`.
- `emac_rx_enable` экспортирован как `inline` + `EXPORT_SYMBOL_GPL`, это косметика.

### 1.3 Барьеры и DMA на некогерентном 44x

Модель upstream (map без unmap, `dma_map_single(FROM_DEVICE)` = invalidate, `wmb()` перед записью `ctrl`) сохранена:

- `__prepare_rx_skb` (mal.c:547-557) и `recycle_rx_skb` (mal.c:498-507): `wmb()` перед `ctrl`;
- в `poll_rx` `mb()` между чтением `ctrl` и `data_len`;
- в TX `wmb()` перед установкой READY в головном дескрипторе (core.c:1309, 1402).

Размеры маппинга согласованы: `rx_sync_size` = `SKB_DATA_ALIGN(RCBS+2)` ≤ буфер skb, `skb_shared_info` не затрагивается. Отдельных ошибок барьеров я не нашёл, кроме окна при смене MTU (M4). В `emac_xmit_split()` дескрипторы продолжения помечаются READY до головного, как и в upstream: MAL остановится на не-READY голове. `undo_frame` корректно откатывает `tx_cnt`.

---

## 2. 993_net_core_dev.patch

**Назначение.** `alloc_netdev_mqs_ocm(addr, …)` размещает `net_device` + priv в заранее выделенной памяти (OCM). `alloc_netdev_mqs()` становится обёрткой.

**Состояние.** Код **мёртвый**: единственный вызывающий (core.c:2893-2901) под `EMAC_ALLOC_ON_OCM`, а он закомментирован (core.c:2870). Если его включить:

- при `addr != NULL` пропускаются проверки `strlen(name)`, `txqs/rxqs < 1` и размера (medium);
- `free_netdev()` → `netdev_freemem()` → `kvfree()` для OCM-адреса даёт crash (high, при ошибке probe или remove);
- в `emac_probe` результат `ppc4xx_ocm_alloc()` не проверяется перед `memset`.

**Рекомендация:** выбросить. На 4.19.325 тело функции не изменилось, накладывается с fuzz, семантически корректно.

## 3. 991_skbuff_perf.patch

`__always_inline` для `spd_fill_page()` и `__splice_segment()` (splice/sendfile из сокета). Поведение не меняется, выигрыш на уровне шума: GCC -O2 скорее всего и так их инлайнит, это static-функции с одним или двумя вызовами. Безопасен; на 325 функции идентичны. **Можно оставить или выбросить**, разницы нет.

## 4. 990_ipv4_tcp_perf.patch

### 4.1 Что меняет

1. `tcp.c:903-925`: `tcp_xmit_size_goal()` слита в `tcp_send_mss()`; **убран `tcp_bound_to_half_wnd()`** для size_goal (строка 914). Логика OOB эквивалентна.
2. `tcp_output.c`: макросы вместо функций `tcp_minshall_check`, `tcp_nagle_check` (1688), `tcp_pacing_check`; `minl` (1700); `inline`/`__always_inline`; `register`; likely/unlikely.
3. `tcp_mss_split_point()` получает `tp` параметром; `tcp_mtu_probe()` разбита на inline-обёртку с ранним выходом и `_tcp_mtu_probe()`. Эквивалентно.
4. В `tcp_write_xmit()` вычисление `limit` перенесено в else-ветку. Эквивалентно оригиналу (`tso_segs > 1 && !urg`).
5. **Закомментирован `if (tcp_pacing_check(sk)) break;`** в `tcp_write_xmit()` (tcp_output.c:2341-2342).

### 4.2 Корректность

- **M1 — medium: утечка сокетов при внутреннем pacing.** В 4.19.99 `tcp_internal_pacing()` (tcp_output.c:967-984) на каждый отправленный skb делает `hrtimer_start()` + `sock_hold()`. Таймер (`tcp_pace_kick`) делает один `sock_put()` на срабатывание. Без `tcp_pacing_check()` в основном цикле таймер перевзводится при каждом пакете, refcount растёт, закрытые сокеты **никогда не освобождаются**, память течёт.

  Кто включает внутренний pacing: BBR, либо любое **непривилегированное** приложение через `setsockopt(SO_MAX_PACING_RATE)`, если qdisc не `fq` (sock.c:997-1005: `SK_PACING_NONE→NEEDED`). Итого локальный DoS памяти на машине с 256 МБ, плюс ограничение скорости молча игнорируется.

  В stable это частично закрыто коммитом 0a70f118475e («tcp: fix possible socket leaks in internal pacing mode»): на 4.19.325 `tcp_internal_pacing()` проверяет `hrtimer_is_queued`. Но pacing с патчем всё равно не работает.
- **`tcp_bound_to_half_wnd` в size_goal.** На проводе это ничего не меняет: MSS (`mss_now`) по-прежнему ограничивается половиной окна в `tcp_sync_mss()` (tcp_output.c:1546). Окно получателя соблюдается через `tcp_mss_split_point()`/`tso_fragment()`. Меняется только размер skb в write queue: всегда около 64 КБ.
  - В LAN окно измеряется мегабайтами, половина окна > 64 КБ, так что **изменение там вообще no-op**.
  - С пиром с маленьким окном skb по 64 КБ будут многократно дробиться `tso_fragment()`: лишние аллокации и CPU. Это слабый усилитель нагрузки со стороны злонамеренного пира, но не порча памяти.
  - С фиксами CVE-2019-11477/11478/11479 (в 4.19.99 они есть) конфликта нет. `gso_segs` ≤ `sk_gso_max_segs`, проверки pcount ≤ 65535 и лимит `tcp_fragment` (11478) остаются. `tcp_min_snd_mss` (11479) не затронут.
  - MSG_OOB обрабатывается как раньше (`size_goal = mss_now`).
- Остальное (макросы, inline, register) семантически эквивалентно. Макрос `tcp_nagle_check(prt, tp, nonagle)` вычисляет аргументы корректно, побочных эффектов в аргументах нет.

### 4.3 Производительность

Выигрыш **пренебрежимый**:

- `register` компилятор игнорирует;
- static-функции с одним вызовом GCC -O2 и так инлайнит;
- `tcp_pacing_check()` — одно чтение `sk_pacing_status`, `tcp_mtu_probe` — несколько сравнений.

При ~50–80 тыс. вызовов `tcp_write_xmit` в секунду это доли процента CPU. Удвоение пропускной способности даёт драйвер (TSO/TAH, coalescing, кольца), а не 990. Проверить можно A/B-замером `iperf3`/SMB с 990 и без него.

### 4.4 Рекомендация

**Выбросить 990 целиком.** Минимум — вернуть `tcp_pacing_check()`. Это заодно снимает 3 из 4 проблем при переносе на 4.19.325. Там уже собранный `patched-v4.19.325/net/ipv4/tcp_output.c` **не компилируется**: нет обёртки `tcp_mtu_probe(sk,tp)`, `tcp_mss_split_point()` вызывается с 6 аргументами при 5 в определении.

## 5. 702-phy_add_aneg_done_function.patch

Добавляет хук `phy_driver->update_link` и вызов из `genphy_update_link()` (phy_device.c:1513-1514). **Ни один драйвер в дереве его не заполняет** (grep `update_link`), и EMAC на MBL использует собственный `phy.c` (BCM54610), а не phylib. Мёртвый код, безвреден (info). Можно выбросить. Название («aneg_done») не соответствует содержанию.

---

## 6. Безопасность: удалённо достижимое

| Вектор | Уровень | Комментарий |
|---|---|---|
| Кадр длиннее `rx_skb_size` из L2-сегмента (jumbo на не-jumbo сети; 9000 при MTU 4080) | **critical** | C1: UAF / double free / запись данных атакующего в кучу. Один кадр. Нужен доступ к тому же L2-сегменту. Достижимость зависит от того, пишет ли EMAC в DMA overlong-кадры (проверить тестом из C1). |
| Удалённый TCP-пир с маленьким MSS или PMTU (VPN, PPPoE) | high (доступность) | H1: TSO шлёт сегменты по SSR0; соединение висит. Это не порча памяти. |
| Перегрузка RX (флуд) → RXDE | high (доступность) | H3: TX может выключиться до 100 с. Любой в LAN, кто может флудить на 1 Гбит/с, этого добьётся. |
| Мелкое окно у пира | low | 990: лишние `tso_fragment()`. |
| Кадры с плохой контрольной суммой L4 по IPv6 | low (целостность, неуверенно) | L5: `CHECKSUM_UNNECESSARY` для всего без ошибок TAH. |
| Специально собранные TSO skb | low | Только локально с `CAP_NET_RAW` (`PACKET_VNET_HDR`) или через tun/tap/bridge. GRO драйвер не использует (`netif_receive_skb`), так что GSO-skb извне через forwarding не появляются. TAH игнорирует `gso_size` (см. H1), а `gso_type` TCPv4 с не-TCP payload даст мусор на проводе (root-only). |
| sysfs / ethtool | low | Только root: DoS интерфейса через некорректные параметры. |
| Локальный непривилегированный | medium | M1 (990): утечка сокетов через `SO_MAX_PACING_RATE`. |

Плюс все сетевые CVE, исправленные после 4.19.99 и отсутствующие в ядре (§7).

---

## 7. Upstream 4.19.99 → 4.19.325

### 7.1 EMAC/MAL

Между 99 и 325 в `drivers/net/ethernet/ibm/emac` изменился только `mal.c`: **4bd7823cacb2 «net: ibm: emac: mal: fix wrong goto»** (утечка DCR при ошибке probe на 405EZ; на APM не достигается). В патченном mal.c та же ошибка на строке 998 (`goto fail` → `goto fail_unmap`).

Остальные файлы emac в patched-325 побайтно совпадают с patched-99. Коммиты ibmvnic/ibmveth/ehea относятся к pSeries и неактуальны.

### 7.2 TCP / net core, важные для этой системы

Выборка из `log-net.txt`. CVE указаны там, где уверенность высокая; остальное помечено.

| Коммит | Что | CVE | Удалённо? |
|---|---|---|---|
| 458f07ffeccd | tcp: do not accept ACK of bytes we never sent | CVE-2023-52881 | да (ослабление защит RFC 5961, blind-атаки) |
| 0d3ffbbf8631 | net: prevent mss overflow in skb_segment() | CVE-2023-52435 | в основном локально / GRO-forwarding |
| 05c6ca8d7011 | tcp: make retransmitted SKB fit into the send window | — | да (пир сжимает окно; корректность) |
| 6145a82d87ea | net: Remove acked SYN flag from packet in the transmit queue correctly | неуверенно | да (TFO) |
| 633da7b30b24 | tcp: fix indefinite deferral of RTO with SACK reneging | неуверенно | да (зависание соединения) |
| 9bbde0825846 | tcp: do not leave dangling pointers in tp->highest_sack | неуверенно | возможно (UAF через SACK) |
| 75a578000ae5 | inet: fully convert sk->sk_rx_dst to RCU rules | неуверенно | гонка UAF в RX-пути |
| 4818f1870417 | ipv6: tcp: drop silly ICMPv6 packet too big messages | — | да (MSS ~48, усиление нагрузки) |
| 7e1c74befe15, bcf95ac62cb5, 55c73db29958, 4d941fdf910b | разные исправления TCP (stall / ресурсы / TLP / RTO) | — | да, влияние пира |
| 34e41a031fd7 | tcp: defer shutdown(SEND_SHUTDOWN) for TCP_SYN_RECV | CVE-2024-36905 (довольно уверенно) | частично (TFO) |
| d7d1a28f5dd5, d70ca7598943, 0ab47ec3874a | qdisc_pkt_len_init / gso_features_check | CVE-2024-49949 (довольно уверенно) и др. | локально |
| 5bb642cc3355, 93f0133b9d58 | гонки icsk_af_ops / таймеры kernel-сокетов | CVE-2022-3566, CVE-2024-35910 | локально |
| **0a70f118475e** | tcp: fix possible socket leaks in internal pacing mode | — | локально; **напрямую связан с M1 (990)** |
| 9f313bcb3b3d | net: disable netpoll on fresh napis | — | связан с netconsole |
| 669c0b5782fb, 66fb76f3a8d7 | truesize крошечных skb | — | учёт памяти под флудом |

**Важно:** `log-net.txt` покрывает только net core, TCP и IBM-драйверы. В нём нет IPv4/IPv6 фрагментации, ICMP, UDP, netfilter, bridge. По памяти (**проверить отдельно**) за этот период в 4.19 закрыты и такие удалённо значимые проблемы:

- CVE-2020-25705 (SAD DNS, глобальный ICMP rate limit, «icmp: randomize the global rate limiter»);
- CVE-2020-16166 (утечка состояния `prandom` в сетевом стеке);
- CVE-2022-32296 / CVE-2022-1012 (утечка через выбор TCP source port, «tcp: increase source port perturb table to 2^16»);
- исправления фрагментации IPv6/IPv4 (например, «ipv6: frags …» 2020-2022).

Всё это аргумент за переход на 4.19.325 (или новее), а не за латание 4.19.99.

### 7.3 Сложность переноса на 4.19.325

- **992:** проваленный hunk #4 — в **mal.c** (`@@ -516 +927`, вся `mal_probe()`), а не в core.c. Единственное изменение upstream в этом месте — `goto fail_unmap` из 4bd7823cacb2. Остальные файлы emac upstream не менялись. Решение тривиально: скопировать `patched-v4.19.99/drivers/net/ethernet/ibm/emac/*` в дерево 325 и поправить mal.c:998 на `goto fail_unmap`. Внимание: текущий `patched-v4.19.325/.../mal.c` — смесь (upstream `mal_probe` без OCM и coalescing + переписанный остальной файл), использовать нельзя.
- **990:** 3 hunk'а не легли:
  - #5 (`READ_ONCE` для `sysctl_tcp_min_tso_segs`, 15085721749a);
  - #8 (`tcp_pacing_check` перемещена 0a70f118475e);
  - #14 (`tcp_cwnd_validate` из 1bbbaaf3e64d).

  Портировать можно за час, но **рекомендую не переносить вовсе** (§4.4).
- **991, 993:** ложатся с fuzz, функции не изменились, семантически корректно (993 всё равно мёртвый код).
- Коммиты `rejects-v4.19.325.txt` пуст; реальные `.rej` воспроизведены субагентом в scratchpad.

---

## 8. Сводные рекомендации

1. **Немедленно** (минимальные правки к работающему 4.19.99):
   - C1: `*skb_sg = NULL;` в mal.c:534 (и core.c:1563).
   - H2: проверка `mc == NULL` в начале `mal_poll()`.
   - H3: скобки в `emac_rx_enable()` (core.c:254) и `watchdog_timeo = 5*HZ` (core.c:3030).
   - M2: исправить шаг в `peek_rx_sg()`.
   - Проверить `/proc/interrupts` на «RX0 COAL» (M3) и выставить ненулевой TX-таймер coalescing.
2. **TSO:** до переделки на `ndo_features_check` с выбором SSR по `gso_size` держать `tso off`, если есть удалённые клиенты (VPN) или jumbo. Замерить, сколько скорости реально теряется.
3. **Jumbo:** не использовать, пока не исправлены C1, H1, M4. Сейчас это прямой путь к порче памяти и зависаниям.
4. **990:** выбросить. **991:** всё равно. **993, 702:** выбросить (мёртвый код).
5. Sysfs: валидировать ввод, брать `rtnl_lock` в `core_reset()`, регистрировать группу через `ndev->sysfs_groups`.
6. Вернуть `unregister_netdev()` в `emac_remove()`; OCM-пути: проверять NULL, освобождать через `ppc4xx_ocm_free()`.
7. Перейти на 4.19.325 (перенос 992 тривиален, 990 не нужен). Лучше в перспективе mainline (6.x), куда стоит портировать только действительно полезные части: coalescing, TSO с корректным выбором SSR, размеры колец.

## 9. Что не проверено / неуверенно

- Точная семантика TAH SSR (длина IP-датаграммы или кадра) и ограничения кратности. Вывод H1 от неё не зависит: `gso_size` в железо не передаётся ни при какой семантике.
- Пишет ли EMAC/MAL в DMA кадры длиннее MJS/1518 (это определяет удалённую достижимость C1). Нужен тест.
- Реальная маршрутизация coalescing-IRQ на APM82181 и смысл `TxTimer = 0` (M3).
- Корректность `lwarx/stwcx.` по caching-inhibited OCM на PPC464 (L3). Эмпирически работает.
- Покрывает ли TAH проверку RX checksum для IPv6 (L5).
- CVE из §7.2, помеченные «неуверенно», и список не-TCP CVE.
- Патчи debloat (901/902/904) и не-сетевые патчи в объём не входили.
