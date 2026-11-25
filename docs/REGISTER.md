path: ~/projects/pg-cdc/docs/REGISTER.md
descripton:
Описание работы скрипта register.sh

----------

### что может register.sh

| Команда | Действие |
| --- | --- |
| `./register.sh` | как раньше: все коннекторы + ожидание RUNNING |
| `./register.sh reg sink-orders` | один коннектор; принимает имя файла, *.json или имя коннектора |
| `./register.sh del pg-orders-sink` | DELETE; для source дополнительно напомнит про осиротевший слот |
| `./register.sh del all -y` | снести все без подтверждения |
| `./register.sh st` | таблица NAME / CONNECTOR / TASKS |
| `./register.sh st pg-orders-sink` | полный JSON со trace — то, что нужно при FAILED |
| `./register.sh src` | строки public.orders |
| `./register.sh src slots` | слоты + объём удержанного WAL |
| `./register.sh trg` | последние 30 записей журнала |
| `./register.sh trg current` | актуальное состояние (DISTINCT ON, без удалённых) |
| `./register.sh trg dup` | total vs uniq — контроль идемпотентности |
| `./register.sh trg lag` | лаг доставки по последним 20 |
| `./register.sh trg "SELECT …"` | произвольный SQL |
| `./register.sh h` | справка |