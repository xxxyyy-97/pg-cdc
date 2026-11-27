path: ~/projects/pg-cdc/docs/DEBEZIUM.md
descripton:
В этом файле описаны debezium-коннекторы.


----------

## producer таблицы orders в источнике

```bash
cat connectors/pg-orders-source.yaml
```
```yaml
apiVersion: "kafka.jikkou.io/v1" 
kind: "KafkaConnector"
metadata:
  name: "pg-orders-source"
  labels:
    kafka.jikkou.io/connect-cluster: "local"   # имя из application.conf
spec:
  connectorClass: "io.debezium.connector.postgresql.PostgresConnector"
  tasksMax: 1
  state: "RUNNING"
  config:
    plugin.name: "pgoutput"
    database.hostname: "source"
    database.port: "5432"
    database.user: "debezium"
    database.password: "dbz"
    database.dbname: "app"
    topic.prefix: "app"
    table.include.list: "public.orders"
    slot.name: "dbz_orders_slot"
    publication.name: "dbz_pub"
    publication.autocreate.mode: "disabled"
    snapshot.mode: "initial"
    decimal.handling.mode: "precise"
    tombstones.on.delete: "false"
    heartbeat.interval.ms: "10000"
```

## consumer таблицы orders_hist в приемнике

```bash
cat connectors/pg-orders-sink.yaml
```
```yaml
apiVersion: "kafka.jikkou.io/v1"
kind: "KafkaConnector"
metadata:
  name: "pg-orders-sink"
  labels:
    kafka.jikkou.io/connect-cluster: "local"
  # annotations:
  #   jikkou.io/delete: true        # ← маркер удаления
spec:
  connectorClass: "io.confluent.connect.jdbc.JdbcSinkConnector"
  tasksMax: 1
  state: "RUNNING"
  config:
    topics: "app.public.orders"

    connection.url: "jdbc:postgresql://target:5432/dwh?stringtype=unspecified&currentSchema=cdc"
    connection.user: "loader"
    connection.password: "loader"
    table.name.format: "orders_hist"

    insert.mode: "upsert"
    pk.mode: "record_value"
    pk.fields: "kafka_partition,kafka_offset"
    delete.enabled: "false"
    auto.create: "false"
    auto.evolve: "false"
    batch.size: "1000"

    transforms: "unwrap,meta,rename"

    transforms.unwrap.type: "io.debezium.transforms.ExtractNewRecordState"
    transforms.unwrap.delete.tombstone.handling.mode: "rewrite"
    transforms.unwrap.add.fields: "op,source.lsn,source.ts_ms,source.txId"

    transforms.meta.type: "org.apache.kafka.connect.transforms.InsertField$Value"
    transforms.meta.offset.field: "kafka_offset"
    transforms.meta.partition.field: "kafka_partition"

    transforms.rename.type: "org.apache.kafka.connect.transforms.ReplaceField$Value"
    transforms.rename.renames: "__op:op_raw,__source_lsn:src_lsn,__source_ts_ms:commit_ts_ms,__source_txId:src_xid,__deleted:is_deleted"

    value.converter: "org.apache.kafka.connect.json.JsonConverter"
    value.converter.schemas.enable: "true"
```