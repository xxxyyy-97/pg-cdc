path: ~/projects/pg-cdc/docs/INFRASTRUCTURE.md
descripton:
в этом файле раскрыта инфраструктура проекта.


----------

## Состав стенда

| Сервис | Образ | Порт на хосте | Назначение |
| --- | --- | --- | --- |
| kafka | confluentinc/cp-kafka:7.7.1 | 29092 | KRaft, 1 брокер, RF=1 |
| connect | сборка на базе quay.io/debezium/connect:3.0.0.Final | 8083 | Kafka Connect REST |
| source | postgres:17 | 5433 | источник, БД app |
| target | postgres:17 | 5434 | приёмник, БД dwh |
| kafka-ui | provectuslabs/kafka-ui | 8080 | просмотр топиков и коннекторов |

## Описание docker-compose.yml

```bash
cat docker/docker-compose.yml
```
```yaml
name: pg-cdc

services:
  kafka:
    image: confluentinc/cp-kafka:7.7.1
    container_name: kafka
    ports: ["29092:29092"]
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093,PLAINTEXT_HOST://0.0.0.0:29092
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092,PLAINTEXT_HOST://localhost:29092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      KAFKA_NUM_PARTITIONS: 1          # 1 партиция = глобальный порядок событий
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      CLUSTER_ID: ${KAFKA_CLUSTER_ID}
    volumes: [kafka-data:/var/lib/kafka/data]
    healthcheck:
      test: ["CMD-SHELL", "kafka-broker-api-versions --bootstrap-server kafka:9092 >/dev/null 2>&1"]
      interval: 10s
      timeout: 10s
      retries: 15

  connect:
    build: ./connect
    container_name: connect
    depends_on:
      kafka: {condition: service_healthy}
    ports: ["8083:8083"]
    environment:
      BOOTSTRAP_SERVERS: kafka:9092
      GROUP_ID: connect-1
      CONFIG_STORAGE_TOPIC: _connect_configs
      OFFSET_STORAGE_TOPIC: _connect_offsets
      STATUS_STORAGE_TOPIC: _connect_status
      CONFIG_STORAGE_REPLICATION_FACTOR: 1
      OFFSET_STORAGE_REPLICATION_FACTOR: 1
      STATUS_STORAGE_REPLICATION_FACTOR: 1
      KEY_CONVERTER: org.apache.kafka.connect.json.JsonConverter
      VALUE_CONVERTER: org.apache.kafka.connect.json.JsonConverter
      CONNECT_KEY_CONVERTER_SCHEMAS_ENABLE: "true"
      CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE: "true"   # JDBC sink требует схему
      CONNECT_OFFSET_FLUSH_INTERVAL_MS: 10000
      CONNECT_PLUGIN_PATH: /kafka/connect
      KAFKA_HEAP_OPTS: "-Xms512m -Xmx1g"
      CONNECT_CONFIG_PROVIDERS: env
      CONNECT_CONFIG_PROVIDERS_ENV_CLASS: org.apache.kafka.common.config.provider.EnvVarConfigProvider
      SOURCE_DEBEZIUM_USER: ${SOURCE_DEBEZIUM_USER}
      SOURCE_DEBEZIUM_PASSWORD: ${SOURCE_DEBEZIUM_PASSWORD}
      TARGET_DEBEZIUM_USER: ${TARGET_DEBEZIUM_USER}
      TARGET_DEBEZIUM_PASSWORD: ${TARGET_DEBEZIUM_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8083/connector-plugins >/dev/null"]
      interval: 10s
      timeout: 5s
      retries: 15

  source:
    image: postgres:17
    container_name: pg-source
    command: ["postgres","-c","wal_level=logical","-c","max_wal_senders=10","-c","max_replication_slots=10"]
    environment:
      POSTGRES_USER: ${SOURCE_DB_USER}
      POSTGRES_PASSWORD: ${SOURCE_DB_PASSWORD}
      POSTGRES_DB: ${SOURCE_DB_NAME}
      SOURCE_DEBEZIUM_USER: ${SOURCE_DEBEZIUM_USER}
      SOURCE_DEBEZIUM_PASSWORD: ${SOURCE_DEBEZIUM_PASSWORD}
    ports: ["${SOURCE_DB_PORT}:5432"]
    volumes:
      - ./init/source:/docker-entrypoint-initdb.d
      - source-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${SOURCE_DB_USER} -d ${SOURCE_DB_NAME}"]
      interval: 5s
      retries: 10

  target:
    image: postgres:17
    container_name: pg-target
    environment:
      POSTGRES_USER: ${TARGET_DB_USER}
      POSTGRES_PASSWORD: ${TARGET_DB_PASSWORD}
      POSTGRES_DB: ${TARGET_DB_NAME}
      TARGET_DEBEZIUM_USER: ${TARGET_DEBEZIUM_USER}
      TARGET_DEBEZIUM_PASSWORD: ${TARGET_DEBEZIUM_PASSWORD}
    ports: ["${TARGET_DB_PORT}:5432"]
    volumes:
      - ./init/target:/docker-entrypoint-initdb.d
      - target-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${TARGET_DB_USER} -d ${TARGET_DB_NAME}"]
      interval: 5s
      retries: 10

  kafka-ui:                      # опционально, очень помогает смотреть сообщения
    image: provectuslabs/kafka-ui:latest
    container_name: kafka-ui
    depends_on: [kafka]
    ports: ["8080:8080"]
    environment:
      KAFKA_CLUSTERS_0_NAME: local
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: kafka:9092
      KAFKA_CLUSTERS_0_KAFKACONNECT_0_NAME: connect
      KAFKA_CLUSTERS_0_KAFKACONNECT_0_ADDRESS: http://connect:8083
      DYNAMIC_CONFIG_ENABLED: "true"

  jikkou:
    image: streamthoughts/jikkou:latest
    profiles: ["tools"]              # не стартует при обычном up -d
    depends_on:
      connect: {condition: service_healthy}
    environment:
      JIKKOUCONFIG: /etc/jikkou/contexts.json
    volumes:
      - ./jikkou/contexts.json:/etc/jikkou/contexts.json:ro
      - ./jikkou/application.conf:/work/application.conf:ro
      - ../connectors:/work/connectors:ro
    working_dir: /work

volumes:
  kafka-data:
  source-data:
  target-data:
```

## Описание oбраза debezium

```bash
cat docker/connect/Dockerfile
```
```dockerfile
FROM alpine:3.20 AS fetch
RUN apk add --no-cache curl unzip
ARG JDBC_VERSION=10.7.4
ARG PG_JDBC=42.7.4
RUN curl -fSL -o /tmp/jdbc.zip \
      "https://api.hub.confluent.io/api/plugins/confluentinc/kafka-connect-jdbc/versions/${JDBC_VERSION}/confluentinc-kafka-connect-jdbc-${JDBC_VERSION}.zip" \
 && unzip -q /tmp/jdbc.zip -d /tmp && mv /tmp/confluentinc-kafka-connect-jdbc-* /tmp/jdbc-plugin \
 && curl -fSL -o /tmp/postgresql.jar \
      "https://repo1.maven.org/maven2/org/postgresql/postgresql/${PG_JDBC}/postgresql-${PG_JDBC}.jar"

FROM quay.io/debezium/connect:3.0.0.Final
COPY --from=fetch /tmp/jdbc-plugin/lib/ /kafka/connect/kafka-connect-jdbc/
COPY --from=fetch /tmp/postgresql.jar   /kafka/connect/kafka-connect-jdbc/
```

## Настройка источника pg-source

```bash
awk 'FNR==1 {print "\n==>", FILENAME, "<==\n"} 1' 'docker/init/source/*'
```
```sql

==> docker/init/source/01-role-debezium.sh <==

#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE ${SOURCE_DEBEZIUM_USER} WITH LOGIN PASSWORD '${SOURCE_DEBEZIUM_PASSWORD}' REPLICATION;
    GRANT CONNECT ON DATABASE $POSTGRES_DB TO ${SOURCE_DEBEZIUM_USER};
    GRANT USAGE ON SCHEMA public TO ${SOURCE_DEBEZIUM_USER};
EOSQL

==> docker/init/source/02-table-orders.sh <==

#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE TABLE public.orders (
        id          bigint PRIMARY KEY,
        customer_id bigint NOT NULL,
        amount      numeric(12,2) NOT NULL,
        status      text NOT NULL,
        updated_at  timestamptz NOT NULL DEFAULT now()
    );

    GRANT SELECT ON public.orders TO ${SOURCE_DEBEZIUM_USER};

    -- обязательно: иначе в DELETE/UPDATE приедет только PK
    ALTER TABLE public.orders REPLICA IDENTITY FULL;

    -- publication создаём сами, чтобы не давать debezium права owner'а таблиц
    CREATE PUBLICATION dbz_pub FOR TABLE public.orders;

    INSERT INTO public.orders (id, customer_id, amount, status)
    VALUES (1, 100, 500.00, 'new'), (2, 100, 250.50, 'new');
EOSQL
```

## Настройка приемника pg-target

```bash
awk 'FNR==1 {print "\n==>", FILENAME, "<==\n"} 1' 'docker/init/target/*'
```
```sql

==> docker/init/target/01-role-loader.sh <==

#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE ${TARGET_DEBEZIUM_USER} WITH LOGIN PASSWORD '${TARGET_DEBEZIUM_PASSWORD}';
EOSQL

==> docker/init/target/02-schema-cdc.sh <==

#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE SCHEMA cdc;
    GRANT USAGE ON SCHEMA cdc TO ${TARGET_DEBEZIUM_USER};
EOSQL

==> docker/init/target/03-table-orders_hist.sh <==

#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE TABLE cdc.orders_hist (
        hist_id         bigint GENERATED ALWAYS AS IDENTITY,

        -- метаданные от Debezium (их пишет sink)
        op_raw          text NOT NULL,        -- c / u / d / r
        src_lsn         bigint,
        commit_ts_ms    bigint,
        is_deleted      boolean,
        kafka_partition integer NOT NULL, 
        kafka_offset    bigint NOT NULL, 
        src_xid bigint,
        -- бизнес-колонки; nullable, т.к. зависят от replica identity
        id              bigint NOT NULL,
        customer_id     bigint,
        amount          numeric(12,2),
        status          text,
        updated_at      timestamptz,

        -- ТО САМОЕ ПОЛЕ: insert / update / delete
        op char(1) GENERATED ALWAYS AS (
            CASE op_raw 
              WHEN 'u' THEN 'U'
              WHEN 'd' THEN 'D'
              WHEN 'r' THEN 'R'
              ELSE 'I' END
        ) STORED,

        loaded_at timestamptz NOT NULL DEFAULT now()
    );

    -- CREATE INDEX orders_hist_id_idx ON cdc.orders_hist (id, src_lsn);
    ALTER TABLE cdc.orders_hist ADD PRIMARY KEY (kafka_partition, kafka_offset);
    GRANT SELECT, INSERT, UPDATE ON cdc.orders_hist TO ${TARGET_DEBEZIUM_USER};
EOSQL





==> docker/init/target/04-views.sql <==

CREATE VIEW cdc.v_orders_hist AS
SELECT hist_id, op, op_raw, id, customer_id, amount, status, updated_at,
       to_timestamp(commit_ts_ms / 1000.0) AS commit_ts,
       src_lsn, kafka_partition, kafka_offset
FROM cdc.orders_hist;

-- «текущее состояние» из журнала
CREATE VIEW cdc.v_orders_current AS
SELECT id, customer_id, amount, status, updated_at
FROM (
  SELECT *, row_number() OVER (PARTITION BY id
             ORDER BY src_lsn DESC NULLS LAST, kafka_offset DESC) AS rn
  FROM cdc.orders_hist
) t
WHERE rn = 1 AND op <> 'D';
```

> [!WARNING]
> Файл docker/.env содержит секреты.
> В репозитории хранится только .env.example.

## Шаблон переменных окружения. Переименуйте в .env и подставьте нужные значения

```bash
cat docker/.env.example
```
```bash
SOURCE_DB_USER=postgres
SOURCE_DB_PASSWORD=postgres
SOURCE_DB_NAME=app
SOURCE_DB_PORT=5433

SOURCE_DEBEZIUM_USER=debezium
SOURCE_DEBEZIUM_PASSWORD=dbz

TARGET_DB_USER=postgres
TARGET_DB_PASSWORD=postgres
TARGET_DB_NAME=dwh
TARGET_DB_PORT=5434

TARGET_DEBEZIUM_USER=loader
TARGET_DEBEZIUM_PASSWORD=loader

KAFKA_CLUSTER_ID=MkU3OEVBNTcwNTJENDM2Qk
```