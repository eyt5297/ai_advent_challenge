// Контрактный тест HTTP API.
//
// Фиксирует форму всех эндпоинтов независимо от интерфейса и от того, как
// устроен бэкенд внутри. Перед переделкой архитектуры это точка опоры:
// пока тест зелёный, клиент продолжит работать с новым бэкендом.
//
// Запуск: bun e2e/api_contract_test.mjs   (нужен поднятый сервер)
//         ./e2e/run.sh api_contract

const BASE = process.env.BASE_URL ?? "http://localhost:8099";

const results = [];
const check = (name, ok, detail = "") => results.push([name, Boolean(ok), detail]);

async function call(method, path, body) {
  const response = await fetch(BASE + path, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // Оставляем null: часть проверок как раз про то, что ответ — JSON.
  }
  return { status: response.status, json, text };
}

/// Проверяет, что в объекте есть все перечисленные ключи.
/// Лишние ключи допустимы — добавление поля контракт не ломает,
/// в отличие от удаления.
function hasKeys(object, keys) {
  if (!object || typeof object !== "object") return false;
  return keys.every((key) => key in object);
}

const MESSAGE_KEYS = [
  "id", "session_id", "seq", "role", "content", "reasoning",
  "provider_id", "model_id", "status", "error", "params", "hand_edited",
  "raw_request", "raw_response", "http_status", "latency_ms", "usage",
  "created_at",
];

const SESSION_KEYS = [
  "id", "title", "created_at", "updated_at", "provider_id", "model_id", "params",
];

const PARAM_KEYS = [
  "temperature", "max_tokens", "system_prompt",
  "reasoning_enabled", "reasoning_effort", "stream",
];

// ─── GET /api/health ─────────────────────────────────────────────────────────

{
  const { status, json } = await call("GET", "/api/health");
  check("health: 200", status === 200, String(status));
  check("health: поля status и db", hasKeys(json, ["status", "db", "providers"]));
  check("health: провайдеры со статусом ключа",
    Array.isArray(json?.providers) &&
    json.providers.every((p) => hasKeys(p, ["id", "title", "base_url", "has_key"])));
  check("health: ключи не раскрываются",
    !JSON.stringify(json).includes("test-key") &&
    !JSON.stringify(json).match(/sk-[a-zA-Z0-9]/));
}

// ─── GET /api/catalog ────────────────────────────────────────────────────────

{
  const { status, json } = await call("GET", "/api/catalog");
  check("catalog: 200", status === 200, String(status));
  check("catalog: массив providers", Array.isArray(json?.providers));

  const entry = json?.providers?.[0];
  check("catalog: provider + available", hasKeys(entry, ["provider", "available"]));
  check("catalog: поля провайдера",
    hasKeys(entry?.provider, ["id", "title", "default_model", "groups"]));

  const group = entry?.provider?.groups?.[0];
  check("catalog: группа с моделями", hasKeys(group, ["title", "models"]));

  const model = group?.models?.[0];
  check("catalog: поля модели",
    hasKeys(model, ["id", "title", "context_length", "max_output_tokens",
                    "vision", "tools", "reasoning"]));
  check("catalog: reasoning размечен видом",
    ["none", "optional", "always"].includes(model?.reasoning?.kind),
    model?.reasoning?.kind);

  // Шкала усилий приходит данными, а не подразумевается клиентом.
  const withEfforts = entry.provider.groups
    .flatMap((g) => g.models)
    .find((m) => m.reasoning?.kind !== "none");
  check("catalog: шкала усилий передаётся",
    Array.isArray(withEfforts?.reasoning?.efforts) &&
    withEfforts.reasoning.efforts.length > 0,
    withEfforts?.reasoning?.efforts?.join(","));
}

// ─── Жизненный цикл сессии ───────────────────────────────────────────────────

let sessionId;

{
  const { status, json } = await call("POST", "/api/sessions", {});
  check("create: 201", status === 201, String(status));
  check("create: форма сессии", hasKeys(json, SESSION_KEYS));
  check("create: параметры по умолчанию", hasKeys(json?.params, PARAM_KEYS));
  check("create: модель подставлена", typeof json?.model_id === "string");
  sessionId = json?.id;
}

{
  const { status, json } = await call("GET", "/api/sessions");
  check("list: 200", status === 200, String(status));
  check("list: массив sessions", Array.isArray(json?.sessions));
  check("list: форма строки списка",
    hasKeys(json?.sessions?.[0],
      ["id", "title", "created_at", "updated_at", "message_count"]));
}

{
  const { status, json } = await call("GET", `/api/sessions/${sessionId}`);
  check("get: 200", status === 200, String(status));
  check("get: форма сессии", hasKeys(json, SESSION_KEYS));
}

{
  const { status, json } = await call("PATCH", `/api/sessions/${sessionId}`, {
    title: "контрактный тест",
    params: { temperature: 0.3 },
  });
  check("patch: 200", status === 200, String(status));
  check("patch: заголовок применён", json?.title === "контрактный тест", json?.title);
  check("patch: параметр применён", json?.params?.temperature === 0.3,
    String(json?.params?.temperature));
  // Частичность: незаданные поля не затираются.
  check("patch: модель не затёрта", typeof json?.model_id === "string", json?.model_id);
}

{
  const { status, json } = await call("GET", `/api/sessions/${sessionId}/messages`);
  check("messages: 200", status === 200, String(status));
  check("messages: массив", Array.isArray(json?.messages));
}

// ─── Preview ─────────────────────────────────────────────────────────────────

{
  const { status, json } = await call("POST", `/api/sessions/${sessionId}/preview`, {
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    content: "привет",
    params: { temperature: 0.7, reasoning_effort: "xhigh" },
  });

  check("preview: 200", status === 200, String(status));
  check("preview: форма ответа",
    hasKeys(json, ["raw_request", "effective_params", "warnings"]));
  check("preview: тело — строка с JSON", typeof json?.raw_request === "string");
  check("preview: тело отформатировано", json?.raw_request?.includes("\n  "));
  check("preview: в теле есть model и messages", (() => {
    try {
      const body = JSON.parse(json.raw_request);
      return typeof body.model === "string" && Array.isArray(body.messages);
    } catch { return false; }
  })());
  check("preview: effective_params полные", hasKeys(json?.effective_params, PARAM_KEYS));
  check("preview: warnings — массив", Array.isArray(json?.warnings));
}

// Нормализация под модель: шкалы усилий у провайдеров разные.
{
  const { json } = await call("POST", `/api/sessions/${sessionId}/preview`, {
    provider_id: "kimi",
    model_id: "k3.1-pro",
    content: "привет",
    params: { reasoning_effort: "xhigh" },
  });
  check("preview: недопустимое усилие заменено",
    json?.effective_params?.reasoning_effort !== "xhigh",
    json?.effective_params?.reasoning_effort);
  check("preview: о замене предупредили", json?.warnings?.length > 0,
    json?.warnings?.[0]);
}

// Модель без рассуждений не должна получать эти поля.
{
  const { json } = await call("POST", `/api/sessions/${sessionId}/preview`, {
    provider_id: "veai",
    model_id: "Anthropic/haiku-4.5",
    content: "привет",
    params: { reasoning_effort: "high" },
  });
  check("preview: reasoning отброшен для неподдерживающей модели",
    json?.effective_params?.reasoning_effort === null &&
    !json?.raw_request.includes("reasoning"),
    String(json?.effective_params?.reasoning_effort));
}

// ─── Send ────────────────────────────────────────────────────────────────────

let userMessageId;

{
  const { status, json } = await call("POST", `/api/sessions/${sessionId}/send`, {
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    content: "проверка контракта",
    params: { temperature: 0.5 },
  });

  check("send: 200", status === 200, String(status));
  check("send: пара user + assistant", hasKeys(json, ["user", "assistant", "warnings"]));
  check("send: форма сообщения user", hasKeys(json?.user, MESSAGE_KEYS));
  check("send: форма сообщения assistant", hasKeys(json?.assistant, MESSAGE_KEYS));

  check("send: роли расставлены",
    json?.user?.role === "user" && json?.assistant?.role === "assistant");
  check("send: seq идут подряд", json?.assistant?.seq === json?.user?.seq + 1,
    `${json?.user?.seq} → ${json?.assistant?.seq}`);

  // Ключевое для наблюдаемости: сырые тела сохраняются по разные стороны пары.
  check("send: тело запроса у user", typeof json?.user?.raw_request === "string");
  check("send: тело ответа у assistant", typeof json?.assistant?.raw_response === "string");
  check("send: ключ API не попал в сохранённое тело",
    !json?.user?.raw_request?.toLowerCase().includes("bearer") &&
    !json?.user?.raw_request?.includes("test-key"));

  check("send: http_status у ответа", typeof json?.assistant?.http_status === "number");
  check("send: latency_ms у ответа", typeof json?.assistant?.latency_ms === "number");
  check("send: снимок параметров сохранён",
    json?.assistant?.params?.temperature === 0.5,
    String(json?.assistant?.params?.temperature));

  userMessageId = json?.user?.id;
}

// Независимость запросов: история не передаётся.
{
  const { json } = await call("POST", `/api/sessions/${sessionId}/send`, {
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    content: "второй вопрос",
  });
  const body = JSON.parse(json.user.raw_request);
  check("send: история не передаётся (режим запрос-ответ)",
    body.messages.length === 1, `messages: ${body.messages.length}`);
}

// Ручная правка тела уходит провайдеру как есть.
{
  const { json } = await call("POST", `/api/sessions/${sessionId}/send`, {
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    content: "игнорируется",
    raw_request_override: JSON.stringify({
      model: "РУЧНАЯ",
      messages: [{ role: "user", content: "из ручного тела" }],
    }),
  });
  check("send: override помечен флагом", json?.user?.hand_edited === true);
  check("send: override ушёл без изменений",
    json?.user?.raw_request?.includes("РУЧНАЯ"));
}

// ─── Сбой провайдера не роняет сервер ────────────────────────────────────────

{
  const { status, json } = await call("POST", `/api/sessions/${sessionId}/send`, {
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    content: "ошибка",
  });

  check("send(ошибка): HTTP всё равно 200", status === 200, String(status));
  check("send(ошибка): статус сообщения error",
    json?.assistant?.status === "error", json?.assistant?.status);
  check("send(ошибка): текст ошибки заполнен",
    typeof json?.assistant?.error === "string" && json.assistant.error.length > 0);
  check("send(ошибка): сырое тело сохранено",
    typeof json?.assistant?.raw_response === "string");
  check("send(ошибка): код статуса провайдера сохранён",
    json?.assistant?.http_status === 429, String(json?.assistant?.http_status));
}

// ─── Удаление обмена ─────────────────────────────────────────────────────────

{
  const before = (await call("GET", `/api/sessions/${sessionId}/messages`))
    .json.messages.length;

  const { status, json } =
    await call("DELETE", `/api/sessions/${sessionId}/messages/${userMessageId}`);

  check("delete message: 200", status === 200, String(status));
  check("delete message: вернул список удалённых", Array.isArray(json?.deleted));
  check("delete message: удалена пара", json?.deleted?.length === 2,
    String(json?.deleted?.length));

  const after = (await call("GET", `/api/sessions/${sessionId}/messages`))
    .json.messages.length;
  check("delete message: в БД стало на 2 меньше", after === before - 2,
    `${before} → ${after}`);
}

// ─── Ошибки клиента ──────────────────────────────────────────────────────────

const errorShape = (json) =>
  hasKeys(json, ["error"]) && hasKeys(json.error, ["code", "message"]);

{
  const { status, json } = await call("GET", "/api/sessions/нет-такой/messages");
  check("404 на неизвестную сессию", status === 404, String(status));
  check("404: единый формат ошибки", errorShape(json), JSON.stringify(json));
}

{
  const { status, json } = await call("POST", `/api/sessions/${sessionId}/preview`, {
    provider_id: "veai", model_id: "Anthropic/sonnet-5", content: "   ",
  });
  check("400 на пустое сообщение", status === 400, String(status));
  check("400: код ошибки осмысленный", json?.error?.code === "empty_content",
    json?.error?.code);
}

{
  const { status, json } = await call("POST", `/api/sessions/${sessionId}/preview`, {
    provider_id: "veai", model_id: "нет-такой", content: "привет",
  });
  check("400 на неизвестную модель", status === 400, String(status));
  check("400: код unknown_model", json?.error?.code === "unknown_model",
    json?.error?.code);
}

{
  const { status, json } = await call("POST", `/api/sessions/${sessionId}/preview`, {
    provider_id: "veai", model_id: "Anthropic/sonnet-5", content: "привет",
    raw_request_override: "{ не json",
  });
  check("400 на битый override", status === 400, String(status));
  check("400: код invalid_override", json?.error?.code === "invalid_override",
    json?.error?.code);
}

{
  const { status, json } = await call("POST", "/api/sessions", { title: 42 });
  check("400 на неверный тип поля", status === 400, String(status));
  check("400: сказано, какое поле не так",
    typeof json?.error?.message === "string" && json.error.message.length > 0,
    json?.error?.message);
}

{
  const { status } = await call("PATCH", `/api/sessions/${sessionId}/messages/x`, {});
  check("405 на неразрешённый метод", status === 405, String(status));
}

{
  const { status } = await call("GET", "/api/нет-такого");
  check("404 на неизвестный маршрут", status === 404, String(status));
}

// ─── Удаление сессии ─────────────────────────────────────────────────────────

{
  const { status } = await call("DELETE", `/api/sessions/${sessionId}`);
  check("delete session: 204", status === 204, String(status));

  const after = await call("GET", `/api/sessions/${sessionId}`);
  check("delete session: больше не доступна", after.status === 404,
    String(after.status));
}

// ─── Отчёт ───────────────────────────────────────────────────────────────────

console.log("=== Контракт HTTP API ===");
let failed = 0;
for (const [name, ok, detail] of results) {
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? `  [${detail}]` : ""}`);
  if (!ok) failed++;
}
process.exit(failed ? 1 : 0);
