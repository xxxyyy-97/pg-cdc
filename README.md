1. запуск проекта
```bash
docker compose up -d --build

# дождаться воркера и убедиться, что оба плагина на месте
curl -s localhost:8083/connector-plugins | grep -Eo '"class":"[^"]*(Postgres|JdbcSink)[^"]*"'

curl -s -X POST -H 'Content-Type: application/json' \
    --data @../connectors/source-orders.json localhost:8083/connectors
curl -s -x post -H 'Content-Type: application/json' \
    --data @../connectors/sink-orders.json localhost:8083/connectors

curl -s localhost:8083/connectors/pg-orders-source/status   # RUNNING?
curl -s localhost:8083/connectors/pg-orders-sink/status
```

2. Проверьте, что снапшот доехал
```bash
docker compose exec target psql -U postgres -d dwh -c \
"SELECT hist_id, op, op_raw, id, amount, status, src_lsn, kafka_offset FROM cdc.orders_hist ORDER BY hist_id;"
```

3. тест DML
```sql
INSERT INTO orders(id,customer_id,amount,status) VALUES (3,101,777.77,'new');
UPDATE orders SET amount=999.99, status='paid', updated_at=now() WHERE id=1;
DELETE FROM orders WHERE id=2;
UPDATE orders SET status='paid' WHERE id=3;
UPDATE orders SET status='shipped' WHERE id=3;
```

4. Проверьте, что дублей пока нет
```sql
SELECT kafka_partition, kafka_offset, count(*)
FROM cdc.orders_hist 
GROUP BY kafka_partition, kafka_offset 
HAVING count(*) > 1;
```

5. Спровоцируйте повторную доставку (sink — at-least-once):
```bash
curl -X POST "localhost:8083/connectors/pg-orders-sink/restart?includeTasks=true&onlyFailed=false"
```

6. Полезные запросы поверх журнала
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
