#!/usr/bin/env bash
#
# Сборка и запуск приложения.
#
#   ./run.sh           — собрать клиент и поднять сервер
#   ./run.sh build     — только собрать клиент
#   ./run.sh serve     — только поднять сервер (клиент должен быть собран)
#   ./run.sh test      — юнит-тесты пакетов shared и server
#   ./run.sh e2e       — UI-тесты в браузерном окружении (нужен собранный клиент)
#   ./run.sh check     — всё сразу: сборка, юнит-тесты, UI-тесты
#   ./run.sh catalog   — перегенерировать каталог моделей из API
#
# Ключи провайдеров берутся из окружения: OPENAI_API_KEY, KIMI_API_KEY.

set -euo pipefail

cd "$(dirname "$0")"

STATIC_DIR="server/priv/static"

build_client() {
  echo "→ сборка клиента"
  (cd client && gleam run -m lustre/dev build client \
    --outdir="../$STATIC_DIR" --minify)

  # lustre/dev генерирует свой index.html и зовёт бандл client.js.
  # Подменяем разметку на нашу и кладём рядом стили.
  cp client/static/index.html "$STATIC_DIR/index.html"
  cp client/static/app.css "$STATIC_DIR/app.css"
  echo "✓ клиент собран в $STATIC_DIR"
}

serve() {
  if [[ ! -f "$STATIC_DIR/client.js" ]]; then
    echo "клиент не собран — запустите ./run.sh build" >&2
    exit 1
  fi

  # Занятый порт роняет mist многострочным дампом супервизора, из которого
  # причина неочевидна. Проверяем заранее и объясняем по-человечески.
  local port="${PORT:-8080}"
  if command -v ss >/dev/null && ss -tln 2>/dev/null | grep -q ":$port "; then
    echo "порт $port уже занят:" >&2
    ss -tlnp 2>/dev/null | grep ":$port " | sed 's/^/  /' >&2
    echo "укажите другой, например: PORT=8090 ./run.sh serve" >&2
    exit 1
  fi

  if [[ -z "${OPENAI_API_KEY:-}" && -z "${KIMI_API_KEY:-}" ]]; then
    echo "⚠ ни OPENAI_API_KEY, ни KIMI_API_KEY не заданы:"
    echo "  интерфейс поднимется, но отправка сообщений будет недоступна."
  fi

  # Сервер запускается из server/, поэтому относительный DB_PATH указывал бы
  # на server/data/. Разворачиваем в абсолютный путь от корня проекта —
  # так БД лежит там, где её ожидают README и .gitignore.
  if [[ -z "${DB_PATH:-}" ]]; then
    export DB_PATH="$PWD/data/chat.db"
  elif [[ "$DB_PATH" != /* ]]; then
    export DB_PATH="$PWD/$DB_PATH"
  fi

  # То же и для статики: путь задан относительно корня, а не server/.
  export STATIC_DIR="$PWD/$STATIC_DIR"

  echo "→ запуск сервера"
  cd server && exec gleam run
}

run_tests() {
  for package in shared server; do
    echo "→ тесты: $package"
    (cd "$package" && gleam test)
  done
}

case "${1:-all}" in
  build) build_client ;;
  serve) serve ;;
  test) run_tests ;;
  e2e) ./e2e/run.sh "${2:-}" ;;
  check)
    build_client
    run_tests
    ./e2e/run.sh
    ;;
  catalog) ./scripts/gen_catalog.sh --fetch ;;
  all)
    build_client
    serve
    ;;
  *)
    echo "неизвестная команда: $1" >&2
    echo "доступны: build, serve, test, e2e, check, catalog" >&2
    exit 1
    ;;
esac
