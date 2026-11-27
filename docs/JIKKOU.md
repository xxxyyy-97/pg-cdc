path: ~/projects/pg-cdc/docs/JIKKOU.md
descripton:
Управление debezium-коннекторами через jikkou (GitOps).
Манифесты: connectors/*.yaml. Конфиг: docker/jikkou/application.conf.
Alias jikkou = docker compose run --rm jikkou (запускать из docker/).


----------

Принцип: **источник истины — YAML в Git**. Любое изменение = правка манифеста → diff → apply.
Руками через REST/UI ничего не меняем — jikkou увидит это как дрейф.

### Жизненный цикл коннекторов

| Команда | Действие |
| --- | --- |
| `jikkou diff --files connectors/` | превью изменений против РЕАЛЬНОГО кластера; ничего не трогает |
| `jikkou apply --files connectors/` | FULL reconcile: создаст, обновит, удалит помеченные; идемпотентен (повтор → ok: N, altered: 0) |
| `jikkou apply --files connectors/ -s 'metadata.name IN (pg-orders-sink)'` | точечно один коннектор из директории |
| `jikkou apply --files connectors/ --dry-run` | то же, что diff, но в формате результата apply |
| `jikkou create --files connectors/` | только CREATE, существующие не трогает |
| `jikkou update --files connectors/` | CREATE + UPDATE, без удалений |
| `jikkou replace --files connectors/pg-orders-sink.yaml` | DELETE + CREATE заново; для source может запустить новый снапшот |
| `jikkou validate --files connectors/` | проверка манифестов до похода в кластер: name, label connect-cluster, connectorClass, tasksMax |

### Пауза / остановка / запуск

| Действие | Как |
| --- | --- |
| Поставить на паузу | `spec.state: PAUSED` в манифесте → `jikkou apply` |
| Остановить (конфиг сохраняется) | `spec.state: STOPPED` → `jikkou apply` |
| Вернуть в работу | `spec.state: RUNNING` → `jikkou apply` |
| Перезапустить упавшие инстансы и задачи | `jikkou action kafkaconnectrestartconnectors execute --only-failed --include-tasks` |
| Перезапустить конкретный коннектор целиком | `jikkou action kafkaconnectrestartconnectors execute --connector-name pg-orders-sink --include-tasks` |

## Удаление — только через аннотацию

> [!IMPORTANT]
> Просто удалить YAML и сделать apply — НЕ сработает: orphan-коннекторы не вычисляются (deleteOrphans=false в KafkaConnectorChangeComputer).
> Правильный путь:
> 1. Добавить в манифест `metadata.annotations["jikkou.io/delete"]: true`
> 2. `jikkou delete --files connectors/pg-orders-sink.yaml` (или apply)
> 3. `git rm connectors/pg-orders-sink.yaml`
> Для source после удаления вручную дропнуть осиротевший слот на pg-source.

### Наблюдение и статус

| Команда | Действие |
| --- | --- |
| `jikkou get kafkaconnect connectors` | список коннекторов + конфиги; spec.state — ЖЕЛАЕМОЕ, не фактическое |
| `jikkou get kafkaconnect connectors --name pg-orders-sink` | один коннектор |
| `jikkou get kafkaconnect connectors -o JSON` | для скриптов |
| `jikkou health get kafkaconnect` | здоровье воркера: UP/DOWN, версия, kafkaClusterId |
| `curl -s 'localhost:8083/connectors?expand=status' \| jq \\<br> 'to_entries[] \| {name: .key, connector: .value.status.connector.state, tasks: [.value.status.tasks[].state]}'...` | фактический RUNNING/FAILED коннекторов и задач (URL в кавычках — zsh!) |
| `curl -s 'localhost:8083/connectors/pg-orders-sink/status' \| jq` | полный JSON с trace при FAILED |
| `jikkou action kafkaconnectrestartconnectors execute --only-failed --include-tasks` | альтернатива curl: возвращает статус в ответе + перезапускает упавшее |

## Баг версии 1.1.0

> [!WARNING]
> Флаг `--expand-status` описан в документации, но не работает: KafkaConnectorCollector не переопределяет configProperties(), поэтому опция не регистрируется в CLI.
> Используйте curl expand=status или action --only-failed для просмотра фактического статуса.

### Контроль дрейфа и CI

| Команда | Действие |
| --- | --- |
| `jikkou diff --files connectors/` | кто-то поменял конфиг через kafka-ui → видно сразу, без state-файла |
| `jikkou diff --files connectors/ --fail-on-changes` | exit code 3 при любом расхождении; для cron/CI |
| `jikkou diff --files connectors/ --filter-resource-op CREATE,DELETE` | смотреть только нужные операции |
| `jikkou apply --files connectors/` | откатить ручные изменения к состоянию из Git |

### Интроспекция и шаблоны

| Команда | Действие |
| --- | --- |
| `jikkou api-providers list` | какие провайдеры доступны и включены |
| `jikkou api-resources` | какие ресурсы поддерживает сборка |
| `jikkou api-extensions` | коллекторы, контроллеры, actions |
| `jikkou config view` | merged-конфиг (проверить clusters, url) |
| `jikkou config current-context` | текущий контекст (local) |
| `jikkou apply --files connectors/orders.tpl --values-files values.yaml` | Jinja-шаблон: один манифест × N таблиц/окружений |
| `jikkou get kafkaconnect connectors -o YAML > current.yaml` | экспорт состояния кластера в Git |