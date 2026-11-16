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
