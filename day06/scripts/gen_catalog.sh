#!/usr/bin/env bash
#
# Генерирует shared/src/shared/catalog/generated.gleam из ответов /models.
#
#   ./scripts/gen_catalog.sh            — из сохранённых modeles.txt / kimi_models.txt
#   ./scripts/gen_catalog.sh --fetch    — сначала обновить их из API
#
# Для --fetch нужны OPENAI_API_KEY и KIMI_API_KEY.

set -euo pipefail

cd "$(dirname "$0")/.."

VEAI_BASE_URL="${VEAI_BASE_URL:-https://api.veai.ru/openai/api/v1}"
KIMI_BASE_URL="${KIMI_BASE_URL:-https://api.kimi.ai/coding/v1}"

VEAI_RAW="modeles.txt"
KIMI_RAW="kimi_models.txt"
OUT="shared/src/shared/catalog/generated.gleam"

if [[ "${1:-}" == "--fetch" ]]; then
  echo "→ veai $VEAI_BASE_URL/models"
  curl -fsS "$VEAI_BASE_URL/models" \
    -H "Authorization: Bearer ${OPENAI_API_KEY:?OPENAI_API_KEY не задан}" \
    -o "$VEAI_RAW.new"
  mv "$VEAI_RAW.new" "$VEAI_RAW"

  echo "→ kimi $KIMI_BASE_URL/models"
  curl -fsS "$KIMI_BASE_URL/models" \
    -H "Authorization: Bearer ${KIMI_API_KEY:?KIMI_API_KEY не задан}" \
    -o "$KIMI_RAW.new"
  mv "$KIMI_RAW.new" "$KIMI_RAW"
fi

for f in "$VEAI_RAW" "$KIMI_RAW"; do
  [[ -f "$f" ]] || { echo "нет файла $f — запустите с --fetch" >&2; exit 1; }
  jq -e '.data | type == "array" and length > 0' "$f" >/dev/null \
    || { echo "$f: нет непустого поля .data" >&2; exit 1; }
done

mkdir -p "$(dirname "$OUT")"

jq -n -r \
  --slurpfile veai "$VEAI_RAW" \
  --slurpfile kimi "$KIMI_RAW" \
  -f scripts/catalog.jq > "$OUT"

echo "✓ $OUT"
echo "  veai: $(jq '.data | length' "$VEAI_RAW") моделей"
echo "  kimi: $(jq '.data | length' "$KIMI_RAW") моделей"

if command -v gleam >/dev/null; then
  (cd shared && gleam format src/shared/catalog/generated.gleam) \
    && echo "  отформатировано"
fi
