# Личные заметки в дополнение к README

1. запуск проекта
```bash
docker compose up -d --build

# дождаться воркера и убедиться, что оба плагина на месте
curl -s localhost:8083/connector-plugins | grep -Eo '"class":"[^"]*(Postgres|JdbcSink)[^"]*"'

curl -s -X POST -H 'Content-Type: application/json' \
    --data @../connectors/source-orders.json localhost:8083/connectors


curl -s -x post -H 'Content-Type: application/json' \
    --data @../connectors/sink-orders.json localhost:8083/connectors

curl -s localhost:8083/connectors/pg-orders-source/status
curl -s localhost:8083/connectors/pg-orders-sink/status
```

2. данные приемника
```bash
docker compose exec source psql -U postgres -d app -c \
"SELECT id, customer_id, amount, status, updated_at FROM public.orders;"
```


3. Проверьте, что снапшот доехал
```bash
docker compose exec target psql -U postgres -d dwh -c \
"SELECT hist_id, op, op_raw, id, amount, status, src_lsn, kafka_offset FROM cdc.orders_hist ORDER BY hist_id;"
```

4. тест DML
```sql
INSERT INTO orders(id,customer_id,amount,status) VALUES (3,101,777.77,'new');
UPDATE orders SET amount=999.99, status='paid', updated_at=now() WHERE id=1;
DELETE FROM orders WHERE id=2;
UPDATE orders SET status='paid' WHERE id=3;
UPDATE orders SET status='shipped' WHERE id=3;
```

5. Проверьте, что дублей пока нет
```sql
SELECT kafka_partition, kafka_offset, count(*)
FROM cdc.orders_hist 
GROUP BY kafka_partition, kafka_offset 
HAVING count(*) > 1;
```

6. Спровоцируйте повторную доставку (sink — at-least-once):
```bash
curl -X POST "localhost:8083/connectors/pg-orders-sink/restart?includeTasks=true&onlyFailed=false"
```

7. Полезные запросы поверх журнала
```sql
-- история одной сущности
SELECT op, amount, status, commit_ts FROM cdc.v_orders_hist
WHERE id = 3 ORDER BY src_lsn, kafka_offset;

-- состояние на момент времени (time travel)
SELECT DISTINCT ON (id) id, amount, status, op
FROM cdc.v_orders_hist
WHERE commit_ts <= '2026-11-16 19:36:00+03'
ORDER BY id, src_lsn DESC, kafka_offset DESC;
-- затем отфильтровать op <> 'D'

-- сверка с источником (полнота журнала)
SELECT count(*) FROM cdc.orders_current;   -- vs SELECT count(*) FROM orders на источнике
```

## Метаданные CDC
| Поле              | Тип               | Кто заполняет                                     | Точный смысл | Особенности и подводные камни |
|-------------------|-------------------|---------------------------------------------------|--------------|-------------------------------|
| op_raw            | text NOT NULL     | Debezium op → SMT add.fields=op → rename __op     | Тип операции в источнике: c — INSERT, u — UPDATE, d — DELETE, r — read, строка начального снапшота (не DML) | При d бизнес-колонки заполнены из before (нужен REPLICA IDENTITY FULL). При r — состояние на момент снапшота. Другие коды (t — truncate, m — logical message) в вашей конфигурации не приходят |
| src_lsn           | bigint            | source.lsn                                        | LSN (Log Sequence Number) — байтовая позиция записи изменения в WAL источника. Для r — LSN точки консистентности снапшота | Монотонен в пределах одного сервера/таймлайна. Не уникален: одинаков у снапшот-строк и у пачки строк из multi-insert (INSERT … SELECT пишет одну WAL-запись на много строк). Не годится как ключ дедупа. После failover/пересоздания кластера нумерация другая. Пример: 26502504 = 0/1946568 |
| src_xid           | bigint            | source.txId                                       | Идентификатор транзакции PostgreSQL (XID), в которой закоммичено изменение. Одинаков у всех событий одной транзакции | 32-битный, зацикливается (~4.29 млрд) и номера переиспользуются → нельзя сортировать по нему глобально, только группировать (лучше вместе с commit_ts_ms). Пропуски в нумерации нормальны — это чужие транзакции. Для r — XID снапшот-транзакции, один на весь снапшот |
| commit_ts_ms      | bigint            | source.ts_ms                                      | Время коммита транзакции источника, epoch milliseconds (UTC). Одинаково у всех событий транзакции | Для r — момент снапшота, не коммита. Точность 1 мс → две транзакции теоретически могут совпасть. Это именно source.ts_ms (время в БД-источнике), а не ts_ms верхнего уровня (время обработки коннектором) |
| is_deleted        | boolean           | SMT в режиме delete.tombstone.handling.mode=rewrite добавляет __deleted   | true только у записей-удалений (op_raw='d'), иначе false | Избыточен — дублирует op_raw, можно удалить без потерь. SMT отдаёт его строкой 'true'/'false', в boolean-колонку попадает благодаря stringtype=unspecified в JDBC URL. Не означает, что строка удалена в приёмнике — она вставлена |
| kafka_partition   | integer NOT NULL  | SMT InsertField$Value → partition.field           | Номер партиции топика app.public.orders, из которой прочитано сообщение | Сейчас всегда 0 — топик с одной партицией. Часть ключа идемпотентности. При увеличении числа партиций порядок гарантируется только внутри партиции (по ключу id) |
| kafka_offset | bigint NOT NULL        | SMT InsertField$Value → offset.field              | Смещение сообщения в партиции, присвоенное брокером; строго монотонно | Уникален в паре (partition, offset) и только в рамках одного топика. Если добавите другие топики в эту же таблицу — в PK придётся добавить topic, иначе коллизии. Обнуляется при пересоздании топика. Это ваш ключ дедупликации и порядок доставки |

## Остальные колонки таблицы
| Поле      | Тип                       | Смысл                                 | Особенности |
|-----------|---------------------------|---------------------------------------|-------------|
| hist_id   | bigint identity           | Локальный счётчик вставок в приёмнике | Порядок загрузки, не порядок источника. Возможны пропуски (откаты батчей, конфликты) |
| op        | char(1) generated         | I / U / D / R — вычисляется из op_raw | То самое требуемое поле. R = снапшот. Пересчитывается автоматически, sink его не пишет |
| loaded_at | timestamptz DEFAULT now() | Время вставки строки в приёмник       | Для расчёта лага. Не транзакционно: события одной транзакции могут попасть в разные батчи (у вас .924 и .930) |

## Какое поле для чего годится
| Поле                      | Пригодность для определения «последней версии» |
|---------------------------|------------------------------------------------|
| src_lsn                   | ✅ основной ключ сортировки — физический порядок изменений в WAL источника |
| kafka_offset              | ✅ тай-брейкер: разруливает одинаковый LSN (multi-insert) и повторные доставки |
| commit_ts_ms              | ⚠️ только для срезов «на момент времени». Внутри транзакции одинаков (ваши строки 6–9) — порядок не определит |
| src_xid                   | ❌ 32-битный, зацикливается, не монотонен |
| loaded_at, hist_id        | ❌ порядок загрузки ≠ порядок источника (батчи, реплей после сбоя) |
| updated_at                | ❌ бизнес-поле, может вообще не меняться |
| op / op_raw / is_deleted  | ✅ для отсева удалённых, но не для сортировки |

## Базовый запрос
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

## Шпаргалка
```sql
-- порядок событий источника
ORDER BY kafka_partition, kafka_offset

-- все изменения одной транзакции
WHERE src_xid = 762 AND commit_ts_ms = 1794854604156

-- только реальные DML, без снапшота
WHERE op_raw <> 'r'

-- время коммита и лаг доставки
SELECT hist_id, op,
       to_timestamp(commit_ts_ms/1000.0)                    AS commit_ts,
       loaded_at - to_timestamp(commit_ts_ms/1000.0)        AS delivery_lag
FROM cdc.orders_hist;

-- LSN в привычном виде X/YYYY
SELECT pg_lsn '0/0' + src_lsn FROM cdc.orders_hist;

-- контроль идемпотентности
SELECT count(*) AS total, count(DISTINCT (kafka_partition, kafka_offset)) AS uniq
FROM cdc.orders_hist;
```
