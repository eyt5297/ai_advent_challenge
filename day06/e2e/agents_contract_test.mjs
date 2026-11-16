// Контракт HTTP API агентов и заданий.
//
// Отдельно от api_contract_test.mjs: тот фиксирует границу, существовавшую
// до агентов, и должен оставаться неизменным. Этот описывает добавленное.
//
// Запуск: ./e2e/run.sh agents_contract

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
    // Часть проверок как раз о том, что ответ — JSON.
  }
  return { status: response.status, json };
}

function hasKeys(object, keys) {
  if (!object || typeof object !== "object") return false;
  return keys.every((key) => key in object);
}

const AGENT_KEYS = [
  "id", "name", "description", "system_prompt", "provider_id", "model_id",
  "params", "max_steps", "tools", "created_at", "updated_at",
];

const TASK_KEYS = [
  "id", "session_id", "seq", "prompt", "result", "status", "error",
  "steps", "created_at", "finished_at",
];

// ─── Создание агента ─────────────────────────────────────────────────────────

let agentId;

{
  const { status, json } = await call("POST", "/api/agents", {
    name: "Рецензент",
    description: "разбирает текст по критериям",
    system_prompt: "Ты строгий редактор.",
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    params: { temperature: 0.3 },
    max_steps: 5,
    tools: ["now"],
  });

  check("create agent: 201", status === 201, String(status));
  check("create agent: форма агента", hasKeys(json, AGENT_KEYS));
  check("create agent: промпт сохранён",
    json?.system_prompt === "Ты строгий редактор.", json?.system_prompt);
  check("create agent: параметры сохранены", json?.params?.temperature === 0.3,
    String(json?.params?.temperature));
  check("create agent: лимит шагов сохранён", json?.max_steps === 5,
    String(json?.max_steps));
  check("create agent: инструменты — массив", Array.isArray(json?.tools),
    JSON.stringify(json?.tools));

  agentId = json?.id;
}

// Минимальный агент: обязательны только имя, провайдер и модель.
{
  const { status, json } = await call("POST", "/api/agents", {
    name: "Минимальный", provider_id: "veai", model_id: "Anthropic/sonnet-5",
  });
  check("create agent: хватает трёх полей", status === 201, String(status));
  check("create agent: по умолчанию один шаг", json?.max_steps === 1,
    String(json?.max_steps));
  check("create agent: по умолчанию без инструментов",
    Array.isArray(json?.tools) && json.tools.length === 0,
    JSON.stringify(json?.tools));
}

// ─── Чтение ──────────────────────────────────────────────────────────────────

{
  const { status, json } = await call("GET", "/api/agents");
  check("list agents: 200", status === 200, String(status));
  check("list agents: массив", Array.isArray(json?.agents));
  check("list agents: форма строки",
    hasKeys(json?.agents?.[0], ["id", "name", "model_id", "session_count"]));
}

{
  const { status, json } = await call("GET", `/api/agents/${agentId}`);
  check("get agent: 200", status === 200, String(status));
  check("get agent: форма агента", hasKeys(json, AGENT_KEYS));
}

// ─── Обновление ──────────────────────────────────────────────────────────────

{
  const { status, json } = await call("PATCH", `/api/agents/${agentId}`, {
    name: "Рецензент v2",
  });
  check("patch agent: 200", status === 200, String(status));
  check("patch agent: имя применено", json?.name === "Рецензент v2", json?.name);
  check("patch agent: промпт не затёрт",
    json?.system_prompt === "Ты строгий редактор.", json?.system_prompt);
  check("patch agent: шаги не затёрты", json?.max_steps === 5,
    String(json?.max_steps));
}

// ─── Запуск экземпляра ───────────────────────────────────────────────────────

let sessionId;

{
  const { status, json } = await call(
    "POST", `/api/agents/${agentId}/sessions`, {});

  check("start session: 201", status === 201, String(status));
  check("start session: сессия знает агента", json?.agent_id === agentId,
    json?.agent_id);
  check("start session: модель унаследована от агента",
    json?.model_id === "Anthropic/sonnet-5", json?.model_id);

  sessionId = json?.id;
}

{
  const { status, json } = await call("GET", `/api/agents/${agentId}/sessions`);
  check("list runs: 200", status === 200, String(status));
  check("list runs: только запуски этого агента",
    json?.sessions?.every((s) => s.agent_id === agentId),
    String(json?.sessions?.length));
}

// Обычная сессия остаётся без агента — режим до переделки.
{
  const { json } = await call("POST", "/api/sessions", { title: "без агента" });
  check("обычная сессия без агента", json?.agent_id === null,
    String(json?.agent_id));
}

// ─── Задания ─────────────────────────────────────────────────────────────────

{
  const { status, json } = await call("GET", `/api/sessions/${sessionId}/tasks`);
  check("list tasks: 200", status === 200, String(status));
  check("list tasks: массив", Array.isArray(json?.tasks),
    JSON.stringify(json?.tasks));
}

// ─── Защита агента с запусками ───────────────────────────────────────────────

{
  const { status, json } = await call("DELETE", `/api/agents/${agentId}`);
  check("delete agent с запусками: 409", status === 409, String(status));
  check("delete agent: код agent_in_use", json?.error?.code === "agent_in_use",
    json?.error?.code);

  // Агент на месте — отказ не должен быть частичным.
  const after = await call("GET", `/api/agents/${agentId}`);
  check("delete agent: агент не тронут", after.status === 200,
    String(after.status));
}

{
  await call("DELETE", `/api/sessions/${sessionId}`);
  const { status } = await call("DELETE", `/api/agents/${agentId}`);
  check("delete agent без запусков: 204", status === 204, String(status));

  const after = await call("GET", `/api/agents/${agentId}`);
  check("delete agent: больше не доступен", after.status === 404,
    String(after.status));
}

// ─── Ошибки клиента ──────────────────────────────────────────────────────────

const errorShape = (json) =>
  hasKeys(json, ["error"]) && hasKeys(json.error, ["code", "message"]);

{
  const { status, json } = await call("POST", "/api/agents", {
    name: "   ", provider_id: "veai", model_id: "Anthropic/sonnet-5",
  });
  check("400 на пустое имя", status === 400, String(status));
  check("400: код empty_name", json?.error?.code === "empty_name",
    json?.error?.code);
}

{
  const { status, json } = await call("POST", "/api/agents", {
    name: "X", provider_id: "veai", model_id: "нет-такой",
  });
  check("400 на неизвестную модель", status === 400, String(status));
  check("400: код unknown_model", json?.error?.code === "unknown_model",
    json?.error?.code);
}

{
  const { status, json } = await call("POST", "/api/agents", {
    name: "X", provider_id: "нет-такого", model_id: "Anthropic/sonnet-5",
  });
  check("400 на неизвестного провайдера", status === 400, String(status));
  check("400: код unknown_provider", json?.error?.code === "unknown_provider",
    json?.error?.code);
}

{
  const { status, json } = await call("POST", "/api/agents", {
    name: "X", provider_id: "veai", model_id: "Anthropic/sonnet-5",
    max_steps: 999,
  });
  check("400 на запредельный max_steps", status === 400, String(status));
  check("400: код invalid_max_steps",
    json?.error?.code === "invalid_max_steps", json?.error?.code);
}

{
  const { status, json } = await call("POST", "/api/agents", {
    name: "X", provider_id: "veai", model_id: "Anthropic/sonnet-5",
    max_steps: 0,
  });
  check("400 на нулевой max_steps", status === 400, String(status));
  check("400: формат ошибки единый", errorShape(json));
}

// Обязательные поля отсутствуют.
{
  const { status } = await call("POST", "/api/agents", { name: "Без модели" });
  check("400 без провайдера и модели", status === 400, String(status));
}

{
  const { status, json } = await call("GET", "/api/agents/нет-такого");
  check("404 на неизвестного агента", status === 404, String(status));
  check("404: формат ошибки единый", errorShape(json));
}

{
  const { status } = await call(
    "POST", "/api/agents/нет-такого/sessions", {});
  check("404 на запуск неизвестного агента", status === 404, String(status));
}

{
  const { status, json } = await call("GET", "/api/tasks/нет-такого");
  check("404 на неизвестное задание", status === 404, String(status));
  check("404: формат ошибки единый", errorShape(json));
}

{
  const { status } = await call("PATCH", "/api/tasks/x", {});
  check("405 на неразрешённый метод задания", status === 405, String(status));
}

// ─── Отчёт ───────────────────────────────────────────────────────────────────

console.log("=== Контракт API агентов ===");
let failed = 0;
for (const [name, ok, detail] of results) {
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? `  [${detail}]` : ""}`);
  if (!ok) failed++;
}
process.exit(failed ? 1 : 0);
