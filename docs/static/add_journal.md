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
Готовая view: `cdc.v_orders_current` (см. DDL в [INFRASTRUCTURE.md](../INFRASTRUCTURE.md)).


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
