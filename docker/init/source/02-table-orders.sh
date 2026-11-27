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




