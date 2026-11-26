# pg-cdc — append-only CDC из PostgreSQL в PostgreSQL

Стенд Change Data Capture: **PostgreSQL → Debezium → Kafka → Kafka Connect JDBC Sink → PostgreSQL**.

Все DML-операции источника (INSERT / UPDATE / DELETE) попадают в приёмник **как вставки**
в журнал `cdc.orders_hist`, с полем `op`, отражающим тип операции.

```
pg-source (wal_level=logical, publication dbz_pub, REPLICA IDENTITY FULL)
   └─ Debezium PostgreSQL Connector (slot dbz_orders_slot, pgoutput)
        └─ Kafka: topic app.public.orders   op = c/u/d/r + before/after
             └─ JDBC Sink + SMT: unwrap → InsertField → ReplaceField
                  └─ pg-target: INSERT … ON CONFLICT (kafka_partition, kafka_offset)
                       cdc.orders_hist  (+ generated column op = I/U/D/R)
```

## Что демонстрирует

- **Append-only журнал**: строки никогда не изменяются и не удаляются.
- **Поле операции**: `op` = `I` / `U` / `D` / `R` (снапшот).
- **DELETE как INSERT**: значения берутся из before-image (`REPLICA IDENTITY FULL`).
- **Идемпотентность**: ключ события `(kafka_partition, kafka_offset)` + upsert — повторная
  доставка после сбоя не создаёт дублей.
- **Метаданные источника**: LSN, XID транзакции, время коммита.

## Состав стенда

| Сервис        | Образ                                                 | Порт на хосте | Назначение                    |
|---------------|-------------------------------------------------------|---------------|-------------------------------|
| `kafka`       | confluentinc/cp-kafka:7.7.1                           | 29092         | KRaft, 1 брокер, RF=1         |
| `connect`     | сборка на базе quay.io/debezium/connect:3.0.0.Final   | 8083          | Kafka Connect REST            |
| `source`      | postgres:17                                           | 5433          | источник, БД `app`            |
| `target`      | postgres:17                                           | 5434          | приёмник, БД `dwh`            |
| `kafka-ui`    | provectuslabs/kafka-ui                                | 8080          | просмотр топиков и коннекторов|

Учётки демо-стенда: `postgres/postgres` (суперюзер), `debezium/dbz` (репликация),
`loader/loader` (запись в приёмник). **Это не продакшн-конфигурация.**
Детальное описание стенда смотрите в [INFRASTRUCTURE.md](docs/INFRASTRUCTURE.md)

## Требования

Docker + Compose v2, ~4 ГБ RAM для Docker, `curl`, `jq` **или** `python3`.

## Структура
Структура проекта описана в [PROJECT_TREE.md](docs/PROJECT_TREE.md)

## Debezium-коннекторы
Debezium-коннекторы описаны в [DEBEZIUM.md](docs/DEBEZIUM.md)



## Быстрый старт
> Все команды `docker compose` ниже выполняются из каталога `docker/`.
```bash
cd docker
docker compose up -d --build
cd ..
./register.sh                   # создаст оба коннектора и дождётся RUNNING
```
Запустите `./register.sh h` и посмотрите описание [docs/REGISTER.md](docs/REGISTER.md), чтоб узнать о расширенных возможностях скрипта.

Проверка снапшота:

```bash
cd docker
docker compose exec target psql -U postgres -d dwh -c \
"SELECT hist_id, op, op_raw, id, amount, status FROM cdc.orders_hist ORDER BY hist_id;"

# или
./register.sh trg
```

Ожидаемо две строки `op='R'`, `op_raw='r'` — начальный снапшот.

## Проверка CDC

```bash
docker compose exec source psql -U postgres -d app -c "
  INSERT INTO orders(id,customer_id,amount,status) VALUES (3,101,777.77,'new');
  UPDATE orders SET amount=999.99, status='paid', updated_at=now() WHERE id=1;
  DELETE FROM orders WHERE id=2;
"

docker compose exec target psql -U postgres -d dwh -c \
"SELECT hist_id, op, op_raw, id, amount, status, src_xid, kafka_offset
   FROM cdc.orders_hist ORDER BY hist_id;"
```

```
 hist_id | op | op_raw | id | amount | status | src_xid | kafka_offset
---------+----+--------+----+--------+--------+---------+--------------
       1 | R  | r      |  1 | 500.00 | new    |     748 |            0
       2 | R  | r      |  2 | 250.50 | new    |     748 |            1
       3 | I  | c      |  3 | 777.77 | new    |     760 |            2
       4 | U  | u      |  1 | 999.99 | paid   |     761 |            3
       5 | D  | d      |  2 | 250.50 | new    |     761 |            4   ← before-image
```

Актуальное состояние: `SELECT * FROM cdc.orders_current;`

## Ключевые решения

| Задача                                        | Решение |
|-----------------------------------------------|---------|
| DELETE не должен удалять строку в приёмнике   | `delete.enabled=false` + SMT `ExtractNewRecordState` в режиме `delete.tombstone.handling.mode=rewrite`: событие превращается в обычную запись со значениями из `before` |
| Полный before-image                           | `ALTER TABLE … REPLICA IDENTITY FULL` на источнике |
| Поле `op` = I/U/D/R                           | `GENERATED ALWAYS AS (CASE op_raw …) STORED` — не требует кастомного SMT |
| Идемпотентность                               | SMT `InsertField` добавляет kafka-координаты, PK на них, `insert.mode=upsert` → `ON CONFLICT` возможен только при повторе **того же события** |
| Метаданные                                    | `add.fields=op,source.lsn,source.ts_ms,source.txId` + `ReplaceField` для переименования |
| Порядок событий                               | 1 партиция топика + `tasks.max=1` → глобальный порядок коммитов |

## Схема журнала `cdc.orders_hist`

Инварианты: **одна строка = одно событие Kafka**; строки не изменяются и не удаляются
(кроме перезаписи себя же при повторной доставке).

| Поле              | Тип               | Смысл |
|-------------------|-------------------|-------|
| `hist_id`         | bigint identity   | локальный счётчик вставок; порядок загрузки, возможны пропуски |
| `op_raw`          | text              | операция Debezium: `c` insert, `u` update, `d` delete, `r` snapshot read |
| `op`              | char(1) generated | `I` / `U` / `D` / `R` — вычисляется из `op_raw` |
| `src_lsn`         | bigint            | LSN записи изменения в WAL источника. **Не уникален** (снапшот, multi-insert) |
| `src_xid`         | bigint            | XID транзакции источника; одинаков у всех её событий. 32-битный, зацикливается |
| `commit_ts_ms`    | bigint            | время **коммита** транзакции источника, epoch ms (UTC) |
| `is_deleted`      | boolean           | `true` только у `op_raw='d'`; избыточен |
| `kafka_partition` | integer           | партиция топика (часть PK) |
| `kafka_offset`    | bigint            | смещение в партиции (часть PK); ключ дедупликации |
| `loaded_at`       | timestamptz       | время вставки в приёмник; для расчёта лага |
| `id`, `customer_id`, `amount`, `status`, `updated_at` | как в источнике | значения из `after`, для `d` — из `before` |

## Полезные запросы

```sql
-- актуальное состояние (фильтр по удалениям — СНАРУЖИ подзапроса!)
SELECT id, amount, status FROM (
    SELECT DISTINCT ON (id) *
    FROM cdc.orders_hist
    ORDER BY id, src_lsn DESC NULLS LAST, kafka_offset DESC
) t WHERE op <> 'D';

-- история одной сущности
SELECT op, amount, status, to_timestamp(commit_ts_ms/1000.0) AS commit_ts
FROM cdc.orders_hist WHERE id = 3 ORDER BY src_lsn, kafka_offset;

-- все изменения одной транзакции
SELECT * FROM cdc.orders_hist WHERE src_xid = 762 AND commit_ts_ms = 1794854604156;

-- лаг доставки
SELECT hist_id, op, loaded_at - to_timestamp(commit_ts_ms/1000.0) AS lag
FROM cdc.orders_hist ORDER BY hist_id DESC LIMIT 20;

-- контроль идемпотентности
SELECT count(*) AS total, count(DISTINCT (kafka_partition, kafka_offset)) AS uniq
FROM cdc.orders_hist;
```

Индекс под эти запросы:

```sql
CREATE INDEX orders_hist_id_lsn_idx ON cdc.orders_hist (id, src_lsn DESC, kafka_offset DESC);
```

## Проверка идемпотентности

Graceful `restart` ничего не доказывает — offsets успевают закоммичиться. Нужен жёсткий kill под нагрузкой:

```bash
docker compose exec source psql -U postgres -d app -c \
"INSERT INTO orders(id,customer_id,amount,status)
 SELECT g,100,g*1.5,'new' FROM generate_series(4000,7000) g;"

docker kill -s KILL connect && docker start connect
```

`total == uniq` в контрольном запросе — дублей нет.

> Расхождение по `(src_lsn, id, op_raw)` при этом возможно: Debezium после сбоя перечитывает
> WAL и создаёт **новые** сообщения с новыми offset'ами. Это at-least-once на стороне source,
> синк такое не дедуплицирует.

## Эксплуатация

**Слот держит WAL** — главный риск стенда:

```sql
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
```

Остановленный коннектор → рост WAL на источнике. В проде: алерт на `active=false`
и `max_slot_wal_keep_size`.

**DDL не реплицируется.** Новая колонка: сначала в приёмнике (`auto.evolve=false`),
потом в источнике, иначе sink упадёт на неизвестном поле.

**Добавление таблицы:** `table.include.list` + `ALTER PUBLICATION dbz_pub ADD TABLE …`
+ новый sink (или `topics.regex` и `table.name.format=${topic}`).

## Сброс стенда

```bash
cd docker
docker compose down -v          # удалит и данные, и конфиги коннекторов
docker compose up -d
cd .. && ./register.sh          # обязательный шаг после -v
```

`docker compose down` **без** `-v` сохраняет и данные, и коннекторов.

## Troubleshooting

| Симптом                                                                                   | Причина / фикс |
|-------------------------------------------------------------------------------------------|----------------|
| Приёмник пуст, `curl localhost:8083/connectors` → `[]`                                    | после `down -v` конфиги стёрты → `./register.sh` |
| `there is no unique or exclusion constraint matching the ON CONFLICT specification`       | нет PK `(kafka_partition, kafka_offset)` |
| `column updated_at is of type timestamptz but expression is of type character varying`    | потерян `stringtype=unspecified` в JDBC URL |
| Нет строк с `op_raw='d'`                                                                  | не задан `delete.tombstone.handling.mode=rewrite`|
| `relation "orders_hist" does not exist`                                                   | потерян `currentSchema=cdc` в JDBC URL |
| Задача FAILED                                                                             | `curl -s localhost:8083/connectors/pg-orders-sink/tasks/0/status` |

## Ограничения демо

Один брокер (RF=1), JsonConverter со схемами (без Schema Registry), нет DLQ
и `errors.tolerance`, нет партиционирования и retention журнала, атомарность транзакции
источника в приёмнике не сохраняется (sink пишет батчами), доставка source — at-least-once.

## Лицензии

Бинарники коннекторов **не коммитятся** — их тянет `docker/connect/Dockerfile`.
Confluent JDBC Connector распространяется под Confluent Community License,
Debezium — под Apache 2.0.

[notes](NOTES.md)
