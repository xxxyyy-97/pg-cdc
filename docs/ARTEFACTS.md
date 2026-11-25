path: ~/projects/pg-cdc/docs/ARTEFACTS.md
descripton:
в этом файле приведены атрtфакты проекта cdc.
расположение файлов и общую структуру можно уточнить в файле PROJECT_TREE.md


----------

## Скрипт управления debezium-коннекторами. см. описание в [REGISTER.md](REGISTER.md)

```bash
cat connectors/register.sh
#!/usr/bin/env bash
# register.sh — управление CDC-стендом pg-cdc.
# Без параметров: зарегистрировать/обновить все коннекторы из connectors/ и дождаться RUNNING.
# Справка: ./register.sh help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
# CONNECTORS_DIR="${CONNECTORS_DIR:-$SCRIPT_DIR/connectors}"
CONNECTORS_DIR="${CONNECTORS_DIR:-$SCRIPT_DIR}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/../docker/docker-compose.yml}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
SOURCE_SVC="${SOURCE_SVC:-source}"; SOURCE_DB="${SOURCE_DB:-app}"
TARGET_SVC="${TARGET_SVC:-target}"; TARGET_DB="${TARGET_DB:-dwh}"
PGUSER="${PGUSER:-postgres}"
ASSUME_YES=0

have() { command -v "$1" >/dev/null 2>&1; }
die()  { echo "❌ $*" >&2; exit 1; }

have curl || die "нужен curl"
have jq || have python3 || die "нужен jq или python3"

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# ---------- JSON-хелтеры: jq, иначе python3 --------------------------------
cfg_name() {
  if have jq; then jq -r '.name' "$1"
  else python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["name"])' "$1"; fi
}
cfg_body() {
  if have jq; then jq -c '.config' "$1"
  else python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["config"]))' "$1"; fi
}
names_list() {
  if have jq; then jq -r 'if type == "array" then .[] else empty end'
  else python3 -c 'import json,sys
d = json.load(sys.stdin)
print("\n".join(d if isinstance(d, list) else []))'; fi
}
states() {
  if have jq; then
    jq -r '[(.connector.state // "UNKNOWN")] + [(.tasks // [])[].state] | join(" ")'
  else
    python3 -c 'import json,sys
d = json.load(sys.stdin)
c = (d.get("connector") or {}).get("state", "UNKNOWN")
t = [x.get("state", "UNKNOWN") for x in (d.get("tasks") or [])]
print(" ".join([c] + t))'
  fi
}
jget() {  # stdin: JSON коннектора, $1: ключ из .config
  if have jq; then jq -r --arg k "$1" '.config[$k] // empty'
  else python3 -c 'import json,sys;print(json.load(sys.stdin).get("config",{}).get(sys.argv[1],""))' "$1"; fi
}
pretty() { if have jq; then jq .; else python3 -m json.tool; fi; }

# ---------- Connect ---------------------------------------------------------
need_connect() {  # $1 — сколько секунд ждать (0 = проверить один раз)
  local timeout="${1:-0}" t=0
  while :; do
    if curl -sf --max-time 5 "$CONNECT_URL/connector-plugins" >/dev/null 2>&1; then
      return 0
    fi
    if (( t >= timeout )); then
      die "Connect недоступен: $CONNECT_URL (docker compose up -d; docker compose logs connect)"
    fi
    sleep 2; t=$((t+2))
  done
}

resolve_file() {  # имя коннектора | имя файла | путь → путь к JSON
  local arg="$1" f
  [[ -f "$arg" ]] && { echo "$arg"; return 0; }
  [[ -f "$CONNECTORS_DIR/$arg" ]] && { echo "$CONNECTORS_DIR/$arg"; return 0; }
  [[ -f "$CONNECTORS_DIR/$arg.json" ]] && { echo "$CONNECTORS_DIR/$arg.json"; return 0; }
  for f in "$CONNECTORS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ "$(cfg_name "$f")" == "$arg" ]]; then echo "$f"; return 0; fi
  done
  die "не найден коннектор или файл: $arg"
}

wait_running() {
  local name="$1" s="" t
  printf '⏳ %-22s ' "$name"
  for ((t=0; t<WAIT_TIMEOUT; t+=2)); do
    s="$(curl -sf "$CONNECT_URL/connectors/$name/status" | states || true)"
    if [[ "$s" == *FAILED* ]]; then break; fi
    if [[ -n "$s" ]] && (( $(wc -w <<<"$s") >= 2 )) \
       && [[ ! "$s" =~ (PAUSED|UNASSIGNED|RESTARTING|UNKNOWN) ]]; then break; fi
    sleep 2
  done
  echo "$s"
  if [[ "$s" == *FAILED* ]]; then
    curl -s "$CONNECT_URL/connectors/$name/status" | pretty >&2
    return 1
  fi
  return 0
}

register_one() {
  local file="$1" name code
  name="$(cfg_name "$file")"
  code="$(curl -s -o "$TMP" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
          --data @"$file" "$CONNECT_URL/connectors")"
  case "$code" in
    201) echo "✅ создан   $name" ;;
    409) curl -sf -X PUT -H 'Content-Type: application/json' --data "$(cfg_body "$file")" \
           "$CONNECT_URL/connectors/$name/config" >/dev/null
         echo "♻️  обновлён $name" ;;
    *)   echo "❌ $name → HTTP $code"; cat "$TMP"; return 1 ;;
  esac
  wait_running "$name"
}

delete_one() {
  local name="$1" code cls slot cfg
  cfg="$(curl -s "$CONNECT_URL/connectors/$name" || true)"
  cls="$(printf '%s' "$cfg" | jget connector.class || true)"
  slot="$(printf '%s' "$cfg" | jget slot.name || true)"
  code="$(curl -s -o "$TMP" -w '%{http_code}' -X DELETE "$CONNECT_URL/connectors/$name")"
  case "$code" in
    200|204) echo "🗑  удалён   $name" ;;
    404)     echo "⚠️  не найден $name"; return 0 ;;
    *)       echo "❌ $name → HTTP $code"; cat "$TMP"; return 1 ;;
  esac
  if [[ "$cls" == *PostgresConnector* && -n "$slot" ]]; then
    cat <<EOF
⚠️  Слот репликации '$slot' остался на источнике и продолжает удерживать WAL.
    Проверить: ./register.sh source slots
    Удалить:   ./register.sh source "SELECT pg_drop_replication_slot('$slot')"
EOF
  fi
}

# ---------- psql ------------------------------------------------------------
run_sql() {  # service db sql
  have docker || die "нужен docker"
  [[ -f "$COMPOSE_FILE" ]] || die "не найден compose-файл: $COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" exec -T "$1" \
    psql -U "$PGUSER" -d "$2" -v ON_ERROR_STOP=1 -c "$3"
}

confirm() {
  if (( ASSUME_YES )); then return 0; fi
  printf '%s [y/N] ' "$1"
  local ans; read -r ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# ---------- команды ---------------------------------------------------------
cmd_register() {
  need_connect "$WAIT_TIMEOUT"
  local files=() f fail=0
  if (( $# == 0 )); then
    shopt -s nullglob
    files=("$CONNECTORS_DIR"/*.json)
    ((${#files[@]})) || die "в $CONNECTORS_DIR нет *.json"
  else
    for a in "$@"; do files+=("$(resolve_file "$a")"); done
  fi
  for f in "${files[@]}"; do register_one "$f" || fail=1; done
  if (( fail )); then die "есть ошибки — смотрите вывод выше"; fi
  echo "🎉 готово"
}

cmd_delete() {
  (( $# )) || die "usage: ./register.sh delete <имя|all>"
  need_connect 0
  local names=() n fail=0
  if [[ "$1" == "all" ]]; then
    while read -r n; do [[ -n "$n" ]] && names+=("$n"); done \
      < <(curl -s "$CONNECT_URL/connectors" | names_list)
    ((${#names[@]})) || { echo "коннекторов нет"; return 0; }
    if ! confirm "Удалить все коннекторы (${names[*]})?"; then echo "отменено"; return 0; fi
  else
    names=("$@")
  fi
  for n in "${names[@]}"; do delete_one "$n" || fail=1; done
  return $fail
}

cmd_status() {
  need_connect 0
  local name="${1:-}" list n s conn tasks
  if [[ -n "$name" ]]; then
    curl -s "$CONNECT_URL/connectors/$name/status" | pretty
    return 0
  fi
  list="$(curl -s "$CONNECT_URL/connectors" | names_list)"
  [[ -z "$list" ]] && { echo "коннекторов нет (./register.sh)"; return 0; }
  printf '%-22s %-10s %s\n' "NAME" "CONNECTOR" "TASKS"
  while read -r n; do
    [[ -z "$n" ]] && continue
    s="$(curl -sf "$CONNECT_URL/connectors/$n/status" | states || true)"
    conn="${s%% *}"
    if [[ "$s" == *" "* ]]; then tasks="${s#* }"; else tasks="(нет задач)"; fi
    printf '%-22s %-10s %s\n' "$n" "$conn" "$tasks"
  done <<<"$list"
}

cmd_source() {
  local q="${1:-}" sql
  case "$q" in
    ""|orders) sql="SELECT id, customer_id, amount, status, updated_at FROM public.orders ORDER BY id;" ;;
    slots)     sql="SELECT slot_name, active, wal_status,
                           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
                    FROM pg_replication_slots;" ;;
    pub)       sql="SELECT * FROM pg_publication_tables;" ;;
    *)         sql="$q" ;;
  esac
  run_sql "$SOURCE_SVC" "$SOURCE_DB" "$sql"
}

cmd_target() {
  local q="${1:-}" sql
  case "$q" in
    ""|hist)  sql="SELECT hist_id, op, op_raw, id, amount, status, src_xid, kafka_offset
                   FROM cdc.orders_hist ORDER BY hist_id DESC LIMIT 30;" ;;
    current)  sql="SELECT id, customer_id, amount, status, updated_at, op, src_lsn, kafka_offset
                   FROM (SELECT DISTINCT ON (id) * FROM cdc.orders_hist
                         ORDER BY id, src_lsn DESC NULLS LAST, kafka_offset DESC) t
                   WHERE op <> 'D' ORDER BY id;" ;;
    dup)      sql="SELECT count(*) AS total,
                          count(DISTINCT (kafka_partition, kafka_offset)) AS uniq
                   FROM cdc.orders_hist;" ;;
    lag)      sql="SELECT hist_id, op, to_timestamp(commit_ts_ms/1000.0) AS commit_ts,
                          loaded_at - to_timestamp(commit_ts_ms/1000.0) AS delivery_lag
                   FROM cdc.orders_hist ORDER BY hist_id DESC LIMIT 20;" ;;
    count)    sql="SELECT count(*) FROM cdc.orders_hist;" ;;
    *)        sql="$q" ;;
  esac
  run_sql "$TARGET_SVC" "$TARGET_DB" "$sql"
}

usage() {
  cat <<'EOF'
register.sh — управление CDC-стендом pg-cdc

  ./register.sh                       зарегистрировать/обновить ВСЕ коннекторы + ждать RUNNING
  ./register.sh register [имя|файл…]  то же для конкретных коннекторов
  ./register.sh delete <имя|all>      удалить коннектор(ы)
  ./register.sh status [имя]          все — таблицей, один — JSON с trace
  ./register.sh source [SQL|пресет]   источник
  ./register.sh target [SQL|пресет]   приёмник
  ./register.sh help                  эта справка

Пресеты source: orders (по умолчанию) | slots | pub
Пресеты target: hist (по умолчанию, последние 30) | current | dup | lag | count
Вместо пресета можно передать произвольный SQL строкой.

Флаги: -y/--yes (без подтверждения), -h/--help
Окружение: CONNECT_URL, CONNECTORS_DIR, COMPOSE_FILE, WAIT_TIMEOUT, PGUSER,
           SOURCE_SVC/SOURCE_DB, TARGET_SVC/TARGET_DB

Примеры:
  ./register.sh register sink-orders
  ./register.sh status pg-orders-sink
  ./register.sh delete pg-orders-sink
  ./register.sh delete all -y
  ./register.sh source slots
  ./register.sh target current
  ./register.sh target "SELECT op, count(*) FROM cdc.orders_hist GROUP BY op"
EOF
}

# ---------- разбор аргументов ----------------------------------------------
while (( $# )); do
  case "$1" in
    -y|--yes)  ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        die "неизвестный флаг: $1 (см. --help)" ;;
    *)         break ;;
  esac
done

cmd="${1:-register}"
if (( $# )); then shift; fi

case "$cmd" in
  register|reg)         cmd_register "$@" ;;
  delete|del|rm)        cmd_delete "$@" ;;
  status|st)            cmd_status "$@" ;;
  source|src)           cmd_source "$@" ;;
  target|tgt|trg|dst)   cmd_target "$@" ;;
  help|h)               usage ;;
  *)                    die "неизвестная команда: $cmd (см. ./register.sh help)" ;;
esac
```
