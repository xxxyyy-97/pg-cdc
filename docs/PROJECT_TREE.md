path: ~/projects/pg-cdc/docs/PROJECT_TREE.md
descripton:
в этом файле сохранена структура проекта pg-cdc.


----------

## Особенности структуры

```bash
tree -a -I '.git|depricate'
```
```bash
.
├── .gitignore
├── README.md
├── connectors
│   ├── pg-orders-sink.yaml
│   └── pg-orders-source.yaml
├── docker
│   ├── .env
│   ├── .env.example
│   ├── connect
│   │   └── Dockerfile
│   ├── docker-compose.yml
│   ├── init
│   │   ├── source
│   │   │   ├── 01-role-debezium.sql
│   │   │   └── 02-table-orders.sql
│   │   └── target
│   │       ├── 01-role-loader.sql
│   │       ├── 02-schema-cdc.sql
│   │       ├── 03-table-orders_hist.sql
│   │       └── 04-views.sql
│   └── jikkou
│       ├── application.conf
│       └── contexts.json
└── docs
    ├── DEBEZIUM.md
    ├── INFRASTRUCTURE.md
    ├── JIKKOU.md
    ├── JOURNAL.md
    ├── PROJECT_TREE.md
    ├── README.md
    ├── docs.yml
    └── static
        └── add_journal.md

10 directories, 24 files
```

Из листинга удалена папка **.git**.