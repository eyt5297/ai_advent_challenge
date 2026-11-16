#!/usr/bin/env bash
#
# Тесты поверх запущенного сервера.
#
#   ./e2e/run.sh                 — все тесты
#   ./e2e/run.sh 03_params       — один тест по префиксу имени
#   ./e2e/run.sh api_contract    — только контракт HTTP API
#
# api_contract_test.mjs проверяет форму эндпоинтов без участия интерфейса.
# Это точка опоры при переделке бэкенда: пока он зелёный, клиент продолжит
# работать. Остальные тесты проверяют UI в DOM-окружении.
#
# Каждый тест стартует с чистой БД: сервер запоминает выбор модели и
# параметры в сессии, поэтому состояние от предыдущего теста влияет на
# следующий. Вместо реального провайдера поднимается мок на :8777 —
# так проверяется полный цикл без расхода токенов.

set -uo pipefail

cd "$(dirname "$0")/.."

PORT=8099
MOCK_PORT=8777
DB=data/e2e.db
LOG=/tmp/opencode/e2e-server.log

export PATH="$PWD/client/.lustre/bin/bun-linux-x64:$PATH"

command -v bun >/dev/null || {
  echo "нет bun — сначала соберите клиент: ./run.sh build" >&2
  exit 1
}

[[ -f server/priv/static/client.js ]] || {
  echo "клиент не собран — запустите ./run.sh build" >&2
  exit 1
}

[[ -d e2e/node_modules ]] || (cd e2e && bun install >/dev/null)

# Песочница для read_file: внутри — разрешённый файл, снаружи — «тайна»,
# до которой агент не должен добраться.
FILES_ROOT=/tmp/opencode/e2e-sandbox
rm -rf "$FILES_ROOT" /tmp/opencode/outside.txt
mkdir -p "$FILES_ROOT"
echo "видимое содержимое" > "$FILES_ROOT/note.txt"
echo "тайна снаружи" > /tmp/opencode/outside.txt

cleanup() {
  pkill -f "beam.*server" 2>/dev/null
  [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null
  rm -f "$DB"*
}
trap cleanup EXIT

# Мок провайдера живёт один на весь прогон — он без состояния.
pkill -f mock_provider 2>/dev/null
bun e2e/mock_provider.mjs > /tmp/opencode/e2e-mock.log 2>&1 &
MOCK_PID=$!
sleep 1

start_server() {
  pkill -f "beam.*server" 2>/dev/null
  sleep 1.5
  rm -f "$DB"*
  (cd server && setsid nohup env \
    DB_PATH="../$DB" \
    PORT="$PORT" \
    VEAI_BASE_URL="http://localhost:$MOCK_PORT" \
    OPENAI_API_KEY=e2e-test-key \
    AGENT_FILES_ROOT="$FILES_ROOT" \
    AGENT_HTTP_ALLOWLIST=example.com \
    AGENT_MAX_DEPTH=2 \
    gleam run > "$LOG" 2>&1 < /dev/null &)

  for _ in $(seq 1 30); do
    if curl -sf "http://localhost:$PORT/api/health" > /dev/null; then return 0; fi
    sleep 0.5
  done

  echo "сервер не поднялся, лог:" >&2
  tail -20 "$LOG" >&2
  return 1
}

filter="${1:-}"
total=0
failed_tests=()

for test in e2e/*_test.mjs; do
  name=$(basename "$test" .mjs)
  [[ -n "$filter" && "$name" != "$filter"* ]] && continue

  start_server || exit 1

  output=$(bun "$test" 2>&1)
  status=$?

  echo "$output" | grep -E "^(===|[✓✗])" || echo "$output" | tail -5
  echo

  ok=$(grep -c "^✓" <<< "$output")
  bad=$(grep -c "^✗" <<< "$output")
  total=$((total + ok + bad))

  if [[ $status -ne 0 || $bad -gt 0 ]]; then
    failed_tests+=("$name")
  fi
done

if [[ ${#failed_tests[@]} -eq 0 ]]; then
  echo "✓ все проверки пройдены ($total)"
  exit 0
fi

echo "✗ провалились: ${failed_tests[*]}"
exit 1
