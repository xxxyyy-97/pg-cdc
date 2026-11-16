#!/usr/bin/env bash
# Идемпотентная регистрация коннекторов Kafka Connect.
#
#   ./register.sh          создать или обновить все коннекторы из connectors/
#   ./register.sh status   показать текущие статусы
#
# Переменные окружения:
#   CONNECT_URL     по умолчанию http://localhost:8083
#   CONNECTORS_DIR  по умолчанию <каталог скрипта>/connectors
#   WAIT_TIMEOUT    секунды ожидания готовности, по умолчанию 180
#
# Нужен после каждого `docker compose down -v`: конфиги коннекторов живут
# в топике Kafka _connect_configs и исчезают вместе с томом.

set -euo pipefail

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECTORS_DIR="${CONNECTORS_DIR:-$SCRIPT_DIR/connectors}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"

have() { command -v "$1" >/dev/null 2>&1; }
die()  { echo "❌ $*" >&2; exit 1; }

have curl || die "нужен curl"
have jq || have python3 || die "нужен jq или python3"

# --- JSON-хелтеры: jq, иначе python3 ---------------------------------------
cfg_name() {
  if have jq; then jq -r '.name' "$1"
  else python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["name"])' "$1"; fi
}
cfg_body() {
  if have jq; then jq -c '.config' "$1"
  else python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["config"]))' "$1"; fi
}
names_list() {
  if have jq; then jq -r '.[]'
  else python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin)))'; fi
}
states() {  # stdin: JSON /status → "RUNNING RUNNING"
  if have jq; then jq -r '[.connector.state] + [.tasks[].state] | join(" ")'
  else python3 -c 'import json,sys;d=json.load(sys.stdin);print(" ".join([d["connector"]["state"]]+[t["state"] for t in d["tasks"]]))'; fi
}
traces() {
  if have jq; then jq -r '.tasks[]? | select(.state=="FAILED") | .trace'
  else python3 -c 'import json,sys;d=json.load(sys.stdin);[print(t.get("trace","")) for t in d["tasks"] if t["state"]=="FAILED"]'; fi
}

# --- ждём воркер ------------------------------------------------------------
echo "⏳ Connect: $CONNECT_URL"
for ((t=0; t<WAIT_TIMEOUT; t+=2)); do
  curl -sf "$CONNECT_URL/connector-plugins" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf "$CONNECT_URL/connector-plugins" >/dev/null 2>&1 \
  || die "Connect не отвечает ${WAIT_TIMEOUT}s — смотрите docker compose logs connect"
echo "✅ Connect доступен"

# --- режим status -----------------------------------------------------------
if [[ "${1:-}" == "status" ]]; then
  curl -s "$CONNECT_URL/connectors" | names_list | while read -r n; do
    [[ -z "$n" ]] && continue
    printf '%-22s %s\n' "$n" "$(curl -s "$CONNECT_URL/connectors/$n/status" | states)"
  done
  exit 0
fi

# --- регистрация ------------------------------------------------------------
shopt -s nullglob
files=("$CONNECTORS_DIR"/*.json)
((${#files[@]})) || die "в $CONNECTORS_DIR нет *.json"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
registered=()

for f in "${files[@]}"; do
  name="$(cfg_name "$f")"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
          --data @"$f" "$CONNECT_URL/connectors")"
  case "$code" in
    201) echo "✅ создан   $name" ;;
    409) curl -sf -X PUT -H 'Content-Type: application/json' --data "$(cfg_body "$f")" \
           "$CONNECT_URL/connectors/$name/config" >/dev/null
         echo "♻️  обновлён $name" ;;
    *)   echo "❌ $name → HTTP $code"; cat "$tmp"; exit 1 ;;
  esac
  registered+=("$name")
done

# --- ждём RUNNING -----------------------------------------------------------
fail=0
for name in "${registered[@]}"; do
  printf '⏳ %-22s ' "$name"
  s=""
  for ((t=0; t<WAIT_TIMEOUT; t+=2)); do
    s="$(curl -s "$CONNECT_URL/connectors/$name/status" | states || true)"
    [[ "$s" =~ FAILED ]] && break
    if [[ -n "$s" ]] && (( $(wc -w <<<"$s") >= 2 )) \
       && [[ ! "$s" =~ (FAILED|PAUSED|UNASSIGNED|RESTARTING) ]]; then break; fi
    sleep 2
  done
  echo "$s"
  if [[ "$s" =~ FAILED ]]; then
    curl -s "$CONNECT_URL/connectors/$name/status" | traces
    fail=1
  fi
done

((fail)) && die "есть упавшие задачи — трейс выше"
echo "🎉 все коннекторы RUNNING"
