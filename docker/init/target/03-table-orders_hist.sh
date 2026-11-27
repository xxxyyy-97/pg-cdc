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




