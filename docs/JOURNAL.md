path: ~/projects/pg-cdc/docs/JOURNAL.md
descripton:
Журнал cdc.orders_hist: смысл полей, выбор версии строки, готовые запросы.
DDL журнала — в INFRASTRUCTURE.md, маппинг полей коннектором — в DEBEZIUM.md.


----------

## Метаданные CDC

| Поле | Тип | Кто заполняет | Точный смысл | Подводные камни |
| --- | --- | --- | --- | --- |
| op_raw | text NOT NULL | Debezium op → SMT add.fields=op → rename __op | c — INSERT, u — UPDATE, d — DELETE, r — snapshot read | При d бизнес-колонки из before (нужен REPLICA IDENTITY FULL). t/m в этой конфигурации не приходят |
| src_lsn | bigint | source.lsn | Байтовая позиция записи в WAL источника | Не уникален: одинаков у снапшот-строк и multi-insert. Не ключ дедупа. После failover нумерация другая |
| src_xid | bigint | source.txId | XID транзакции; одинаков у всех её событий | 32-битный, зацикливается (~4.29 млрд) → только группировать, не сортировать глобально |
| commit_ts_ms | bigint | source.ts_ms | Время коммита транзакции источника, epoch ms UTC | Для r — момент снапшота. Точность 1 мс. Это время БД-источника, не время обработки коннектором |
| is_deleted | boolean | SMT rewrite добавляет __deleted | true только у op_raw='d' | Избыточен — дублирует op_raw. В boolean попадает благодаря stringtype=unspecified |
| kafka_partition | integer NOT NULL | SMT InsertField$Value | Партиция топика app.public.orders | Сейчас всегда 0. Часть ключа идемпотентности |
| kafka_offset | bigint NOT NULL | SMT InsertField$Value | Смещение в партиции, строго монотонно | Уникален в паре (partition, offset) в рамках одного топика. Обнуляется при пересоздании топика. Ключ дедупликации |

## Остальные колонки

| Поле | Тип | Смысл | Особенности |
| --- | --- | --- | --- |
| hist_id | bigint identity | Локальный счётчик вставок в приёмнике | Порядок загрузки ≠ порядок источника. Возможны пропуски |
| op | char(1) generated | I / U / D / R — вычисляется из op_raw | R = снапшот. Sink его не пишет |
| loaded_at | timestamptz DEFAULT now() | Время вставки в приёмник | Для расчёта лага. Не транзакционно: события одной транзакции могут попасть в разные батчи |

## Какое поле для чего годится

| Поле | Пригодность для определения последней версии |
| --- | --- |
| src_lsn | ✅ основной ключ сортировки — физический порядок изменений в WAL |
| kafka_offset | ✅ тай-брейкер: разруливает одинаковый LSN и повторные доставки |
| commit_ts_ms | ⚠️ только для срезов на момент времени; внутри транзакции одинаков |
| src_xid | ❌ 32-битный, зацикливается, не монотонен |
| loaded_at, hist_id | ❌ порядок загрузки ≠ порядок источника |
| updated_at | ❌ бизнес-поле, может не меняться |
| op / op_raw / is_deleted | ✅ для отсева удалённых, но не для сортировки |

## Базовый запрос — актуальное состояние

```sql
SELECT id, customer_id, amount, status, updated_at,
       op, src_lsn, src_xid, commit_ts_ms, kafka_offset
FROM (
    SELECT DISTINCT ON (id) *
    FROM cdc.orders_hist
    ORDER BY id,
             src_lsn DESC NULLS LAST,   -- порядок источника
             kafka_offset DESC          -- тай-брейкер
) last
WHERE op <> 'D';                        -- ← фильтр СНАРУЖИ
```
Готовая view: `cdc.v_orders_current` (см. DDL в INFRASTRUCTURE.md).

## Шпаргалка запросов

```sql
-- порядок событий источника
ORDER BY kafka_partition, kafka_offset

-- история одной сущности
SELECT op, amount, status, commit_ts FROM cdc.v_orders_hist
WHERE id = 3 ORDER BY src_lsn, kafka_offset;

-- все изменения одной транзакции
SELECT * FROM cdc.orders_hist
WHERE src_xid = 762 AND commit_ts_ms = 1794854604156;

-- состояние на момент времени (time travel)
SELECT DISTINCT ON (id) id, amount, status, op
FROM cdc.v_orders_hist
WHERE commit_ts <= '2026-11-16 19:36:00+03'
ORDER BY id, src_lsn DESC, kafka_offset DESC;
-- затем отфильтровать op <> 'D'

-- только реальные DML, без снапшота
WHERE op_raw <> 'r'

-- время коммита и лаг доставки
SELECT hist_id, op,
       to_timestamp(commit_ts_ms/1000.0)             AS commit_ts,
       loaded_at - to_timestamp(commit_ts_ms/1000.0) AS delivery_lag
FROM cdc.orders_hist;

-- LSN в привычном виде X/YYYY
SELECT pg_lsn '0/0' + src_lsn FROM cdc.orders_hist;

-- контроль идемпотентности
SELECT count(*) AS total,
       count(DISTINCT (kafka_partition, kafka_offset)) AS uniq
FROM cdc.orders_hist;

-- сверка полноты журнала с источником
SELECT count(*) FROM cdc.v_orders_current;  -- vs SELECT count(*) FROM orders на источнике
```
Индекс под эти запросы:
```sql
CREATE INDEX orders_hist_id_lsn_idx
    ON cdc.orders_hist (id, src_lsn DESC, kafka_offset DESC);
```