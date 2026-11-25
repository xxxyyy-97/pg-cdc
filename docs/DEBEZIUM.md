path: ~/projects/pg-cdc/docs/DEBEZIUM.md
descripton:
В этом файле описаны debezium-коннекторы.


----------

## producer таблицы orders в источнике

```bash
cat connectors/01-source-orders.json
```
```json
{
  "name": "pg-orders-source",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "plugin.name": "pgoutput",
    "database.hostname": "source",
    "database.port": "5432",
    "database.user": "debezium",
    "database.password": "dbz",
    "database.dbname": "app",
    "topic.prefix": "app",
    "table.include.list": "public.orders",
    "slot.name": "dbz_orders_slot",
    "publication.name": "dbz_pub",
    "publication.autocreate.mode": "disabled",
    "snapshot.mode": "initial",
    "decimal.handling.mode": "precise",
    "tombstones.on.delete": "false",
    "heartbeat.interval.ms": "10000",
    "tasks.max": "1"
  }
}
```

## consumer таблицы orders_hist в приемнике

```bash
cat connectors/02-sink-orders.json
```
```json
{
  "name": "pg-orders-sink",
  "config": {
    "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
    "tasks.max": "1",
    "topics": "app.public.orders",

    "connection.url": "jdbc:postgresql://target:5432/dwh?stringtype=unspecified&currentSchema=cdc",
    "connection.user": "loader",
    "connection.password": "loader",
    "table.name.format": "orders_hist",

    "insert.mode": "upsert",
    "pk.mode": "record_value",
    "pk.fields": "kafka_partition,kafka_offset",
    "delete.enabled": "false",
    "auto.create": "false",
    "auto.evolve": "false",
    "batch.size": "1000",

    "transforms": "unwrap,meta,rename",

    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.delete.tombstone.handling.mode": "rewrite",
    "transforms.unwrap.add.fields": "op,source.lsn,source.ts_ms,source.txId",

    "transforms.meta.type": "org.apache.kafka.connect.transforms.InsertField$Value",
    "transforms.meta.offset.field": "kafka_offset",
    "transforms.meta.partition.field": "kafka_partition",

    "transforms.rename.type": "org.apache.kafka.connect.transforms.ReplaceField$Value",
    "transforms.rename.renames": "__op:op_raw,__source_lsn:src_lsn,__source_ts_ms:commit_ts_ms,__source_txId:src_xid,__deleted:is_deleted",

    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "true"
  }
}
```