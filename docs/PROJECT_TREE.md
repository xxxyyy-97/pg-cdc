path: ~/projects/pg-cdc/docs/PROJECT_TREE.md
descripton:
в этом файле сохранена структура проекта pg-cdc.


----------

## Блок

Из листинга удалена папка **.git**.

## Особенности структуры

```bash
tree -a -I .git
```
```bash
.
├── .gitignore
├── README.md
├── connectors
│   ├── 01-source-orders.json
│   ├── 02-sink-orders.json
│   └── register.sh
├── docker
│   ├── .env
│   ├── .env.example
│   ├── connect
│   │   └── Dockerfile
│   ├── docker-compose.yml
│   └── init
│       ├── source
│       │   ├── 01-role-debezium.sql
│       │   └── 02-table-orders.sql
│       └── target
│           ├── 01-role-loader.sql
│           ├── 02-schema-cdc.sql
│           ├── 03-table-orders_hist.sql
│           └── 04-views.sql
└── docs
    ├── DEBEZIUM.md
    ├── INFRASTRUCTURE.md
    ├── NOTES.md
    ├── PROJECT_TREE.md
    ├── REGISTER.md
    └── docs.yml

8 directories, 21 files
```