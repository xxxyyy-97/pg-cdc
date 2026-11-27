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
- **Идемпотентность**: ключ `(kafka_partition, kafka_offset)` + upsert — повторная доставка не создаёт дублей.
- **Метаданные источника**: LSN, XID транзакции, время коммита.

## Документация

Технические детали генерируются автоматически из исходников — **[docs/README.md](docs/README.md)** (оглавление).

| Вопрос | Куда смотреть |
|--------|---------------|
| Сервисы, порты, Dockerfile, SQL-инициализация, .env | [docs/INFRASTRUCTURE.md](docs/INFRASTRUCTURE.md) |
| Конфиги source/sink коннекторов, SMT-цепочки | [docs/DEBEZIUM.md](docs/DEBEZIUM.md) |
| Поля журнала, выбор последней версии, готовые запросы | [docs/JOURNAL.md](docs/JOURNAL.md) |
| Управление коннекторами (`jikkou`) | [docs/JIKKOU.md](docs/JIKKOU.md) |
| Структура репозитория | [docs/PROJECT_TREE.md](docs/PROJECT_TREE.md) |

> [!NOTE]
> Файлы в `docs/` не редактируются вручную. Обновление: `uv run llm-docs-gen --config docs/docs.yml`.

## Требования

Docker + Compose v2, ~4 ГБ RAM для Docker, `curl`, `jq` **или** `python3`.

Учётки демо-стенда: `postgres/postgres` (суперюзер), `debezium/dbz` (репликация),
`loader/loader` (запись в приёмник). **Это не продакшн-конфигурация.**

## Быстрый старт
> [!WARNING]
> перед началом работ нужен алиас `alias jikkou='docker compose run --rm jikkou'`

> Все команды `docker compose` выполняются из каталога `docker/`.

```bash
cd docker
docker compose up -d --build

# дождаться воркера и убедиться, что оба плагина на месте
curl -s localhost:8083/connector-plugins | grep -Eo '"class":"[^"]*(Postgres|JdbcSink)[^"]*"'

# регистрация коннекторов через jikkou через алиас
jikkou apply --files connectors/ 
```

Расширенные возможности `jikkou`: [docs/JIKKOU.md](docs/JIKKOU.md).

Проверка снапшота:

```bash
cd docker && docker compose exec target psql -U postgres -d dwh -c \
"SELECT hist_id, op, op_raw, id, amount, status FROM cdc.orders_hist ORDER BY hist_id;"
```

Ожидаемо две строки `op='R'`, `op_raw='r'` — начальный снапшот.

## Проверка CDC

```bash
cd docker
# DML в источнике
docker compose exec source psql -U postgres -d app -c "
  INSERT INTO orders(id,customer_id,amount,status) VALUES (3,101,777.77,'new');
  UPDATE orders SET amount=999.99, status='paid', updated_at=now() WHERE id=1;
  DELETE FROM orders WHERE id=2;
  UPDATE orders SET status='paid'    WHERE id=3;
  UPDATE orders SET status='shipped' WHERE id=3;
"
# Проверка данных в приемнике
docker compose exec target psql -U postgres -d dwh -c \
"SELECT
    hist_id, id, customer_id, amount, status, updated_at, 
    commit_ts_ms, loaded_at, op, op_raw, is_deleted, 
    kafka_partition, kafka_offset, src_lsn, src_xid  
FROM cdc.orders_hist ORDER BY hist_id;"
```

Ожидаемый журнал после первого блока DML:

```
 hist_id | op | op_raw | id | amount | status | src_xid | kafka_offset
---------+----+--------+----+--------+--------+---------+--------------
       1 | R  | r      |  1 | 500.00 | new    |     748 |            0
       2 | R  | r      |  2 | 250.50 | new    |     748 |            1
       3 | I  | c      |  3 | 777.77 | new    |     760 |            2
       4 | U  | u      |  1 | 999.99 | paid   |     761 |            3
       5 | D  | d      |  2 | 250.50 | new    |     761 |            4   ← before-image
```

Запросы поверх журнала (история сущности, time travel, лаг, транзакции) — в
[docs/JOURNAL.md](docs/JOURNAL.md), раздел «Шпаргалка запросов».

## Ключевые решения

| Задача | Решение |
|--------|---------|
| DELETE не должен удалять строку в приёмнике | `delete.enabled=false` + SMT `ExtractNewRecordState` в режиме `delete.tombstone.handling.mode=rewrite`: событие превращается в обычную запись со значениями из `before` |
| Полный before-image | `ALTER TABLE … REPLICA IDENTITY FULL` на источнике |
| Поле `op` = I/U/D/R | `GENERATED ALWAYS AS (CASE op_raw …) STORED` — не требует кастомного SMT |
| Идемпотентность | SMT `InsertField` добавляет kafka-координаты, PK на них, `insert.mode=upsert` |
| Метаданные | `add.fields=op,source.lsn,source.ts_ms,source.txId` + `ReplaceField` для переименования |
| Порядок событий | 1 партиция топика + `tasks.max=1` → глобальный порядок коммитов |

Конфиги, реализующие эти решения — [docs/DEBEZIUM.md](docs/DEBEZIUM.md),
DDL — [docs/INFRASTRUCTURE.md](docs/INFRASTRUCTURE.md).

## Проверка идемпотентности

Graceful `restart` ничего не доказывает — offsets успевают закоммичиться. Нужен жёсткий kill под нагрузкой:

```bash
cd docker
docker compose exec source psql -U postgres -d app -c \
"INSERT INTO orders(id,customer_id,amount,status)
 SELECT g,100,g*1.5,'new' FROM generate_series(4000,7000) g;"

docker kill -s KILL connect && docker start connect
```

> Расхождение по `(src_lsn, id, op_raw)` при этом возможно: Debezium после сбоя перечитывает
> WAL и создаёт **новые** сообщения с новыми offset'ами. Это at-least-once на стороне source,
> синк такое не дедуплицирует.

## Эксплуатация

**Слот держит WAL** — главный риск стенда:
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
```

`docker compose down` **без** `-v` сохраняет и данные, и коннекторов.

## Troubleshooting

| Симптом | Причина / фикс |
|---------|----------------|
| Приёмник пуст, `curl localhost:8083/connectors` → `[]` | после `down -v` конфиги стёрты → `./register.sh` |
| `there is no unique or exclusion constraint matching the ON CONFLICT specification` | нет PK `(kafka_partition, kafka_offset)` |
| `column updated_at is of type timestamptz but expression is of type character varying` | потерян `stringtype=unspecified` в JDBC URL |
| Нет строк с `op_raw='d'` | не задан `delete.tombstone.handling.mode=rewrite` |
| `relation "orders_hist" does not exist` | потерян `currentSchema=cdc` в JDBC URL |
| Задача FAILED | `./register.sh st pg-orders-sink` (полный JSON со trace) |

## Ограничения демо

Один брокер (RF=1), JsonConverter со схемами (без Schema Registry), нет DLQ
и `errors.tolerance`, нет партиционирования и retention журнала, атомарность транзакции
источника в приёмнике не сохраняется (sink пишет батчами), доставка source — at-least-once.

Бинарники коннекторов **не коммитятся** — их тянет `docker/connect/Dockerfile`.
Confluent JDBC Connector распространяется под Confluent Community License,
Debezium — под Apache 2.0.

## Credits / Используемые инструменты
- [Jikkou](https://github.com/streamthoughts/jikkou) (Apache-2.0) — декларативное управление конфигурацией Kafka Connect
- [Debezium](https://debezium.io) (Apache-2.0) — CDC-коннектор
