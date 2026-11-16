// Инструменты агента: цикл «модель просит → инструмент работает →
// результат возвращается модели».
//
// Мок вызывает инструмент на первом шаге и отвечает текстом на втором,
// поэтому проверяется весь протокол, а не только его половина.

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
  } catch {}
  return { status: response.status, json };
}

const newAgent = async (overrides) =>
  (await call("POST", "/api/agents", {
    name: "Мастер",
    system_prompt: "Ты помощник",
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    max_steps: 5,
    tools: ["now", "calc", "roll_dice"],
    ...overrides,
  })).json;

const runTask = async (sessionId, prompt) =>
  (await call("POST", `/api/sessions/${sessionId}/tasks`, { prompt })).json;

const startSession = async (agentId) =>
  (await call("POST", `/api/agents/${agentId}/sessions`, {})).json;

// ─── Каталог инструментов ────────────────────────────────────────────────────

{
  const { status, json } = await call("GET", "/api/tools");
  check("tools: 200", status === 200, String(status));

  const ids = json?.tools?.map((t) => t.id) ?? [];
  // Чистые инструменты идут первыми — этот тест отвечает за них,
  // опасные проверяет 12_sandbox_test.
  check("tools: чистые инструменты в каталоге",
    JSON.stringify(ids.slice(0, 3)) ===
      JSON.stringify(["now", "calc", "roll_dice"]),
    ids.join(","));

  const calc = json.tools.find((t) => t.id === "calc");
  check("tools: есть описание для модели",
    typeof calc?.description === "string" && calc.description.length > 10);
  check("tools: параметры в виде JSON Schema",
    calc?.parameters?.type === "object" &&
    "expression" in (calc.parameters.properties ?? {}),
    JSON.stringify(calc?.parameters?.properties));
  check("tools: обязательные поля перечислены",
    Array.isArray(calc?.parameters?.required) &&
    calc.parameters.required.includes("expression"));
}

// ─── Полный цикл вызова ──────────────────────────────────────────────────────

{
  const agent = await newAgent({});
  const session = await startSession(agent.id);
  const { task, messages } = await runTask(session.id, "брось кубик");

  check("задание выполнено", task.status === "done", task.status);
  check("потребовалось два шага", task.steps === 2, String(task.steps));

  // Модель → вызов → результат → ответ.
  const roles = messages.map((m) => m.role);
  check("цепочка ролей полная",
    JSON.stringify(roles) ===
      JSON.stringify(["user", "assistant", "tool", "user", "assistant"]),
    roles.join(","));

  const request = messages.find((m) => m.tool_calls?.length > 0);
  check("вызов сохранён у ответа модели",
    request?.tool_calls?.[0]?.name === "roll_dice",
    JSON.stringify(request?.tool_calls));

  const toolRow = messages.find((m) => m.role === "tool");
  check("результат привязан к вызову",
    toolRow?.tool_call_id === request.tool_calls[0].id,
    `${toolRow?.tool_call_id} vs ${request.tool_calls[0].id}`);
  check("результат вызова успешен", toolRow?.status === "ok", toolRow?.status);

  // Инструмент должен был реально отработать, а не быть выдуман моделью.
  const payload = JSON.parse(toolRow.content);
  check("кубик брошен дважды", payload.rolls?.length === 2,
    JSON.stringify(payload));
  check("значения в диапазоне 1..6",
    payload.rolls.every((r) => r >= 1 && r <= 6), JSON.stringify(payload.rolls));

  // Наблюдаемость: вызов виден под той же кнопкой JSON, что и всё прочее.
  check("у шага-вызова сохранены аргументы",
    typeof toolRow.raw_request === "string" &&
    toolRow.raw_request.includes("roll_dice"),
    toolRow.raw_request?.slice(0, 50));
  check("итог содержит результат инструмента",
    task.result.includes("rolls"), task.result?.slice(0, 50));
}

// ─── Протокол запроса ────────────────────────────────────────────────────────

{
  const agent = await newAgent({ tools: ["calc"] });
  const session = await startSession(agent.id);
  const { messages } = await runTask(session.id, "посчитай выражение");

  const firstBody = JSON.parse(messages[0].raw_request);
  check("инструменты объявлены в запросе",
    firstBody.tools?.length === 1, String(firstBody.tools?.length));
  check("объявлен только выданный инструмент",
    firstBody.tools[0].function.name === "calc",
    firstBody.tools[0].function.name);
  check("tool_choice=auto", firstBody.tool_choice === "auto",
    firstBody.tool_choice);

  // Второй шаг обязан вернуть модели её вызов и результат.
  const secondBody = JSON.parse(
    messages.filter((m) => m.role === "user").at(-1).raw_request);
  const roles = secondBody.messages.map((m) => m.role);
  check("история содержит assistant и tool",
    roles.includes("assistant") && roles.includes("tool"), roles.join(","));
  check("вызов возвращён модели",
    secondBody.messages.some((m) => m.tool_calls?.length > 0));
  check("результат сослался на вызов",
    secondBody.messages.some((m) => m.role === "tool" && m.tool_call_id));

  // Задание не повторяется: иначе модель сочла бы его новой просьбой.
  const prompts = secondBody.messages.filter(
    (m) => m.role === "user" && m.content.includes("посчитай"));
  check("задание отправлено один раз", prompts.length === 1,
    String(prompts.length));

  const toolRow = messages.find((m) => m.role === "tool");
  check("вычисление верное", JSON.parse(toolRow.content).result === 20,
    toolRow.content);
}

// ─── Защита от зацикливания ──────────────────────────────────────────────────

{
  const agent = await newAgent({ max_steps: 3 });
  const session = await startSession(agent.id);
  const { task, messages } = await runTask(session.id, "зациклись");

  check("зацикленное задание остановлено", task.status === "failed",
    task.status);
  check("израсходован ровно лимит", task.steps === 3, String(task.steps));
  check("причина названа", task.error?.includes("лимит"), task.error);
  // Шаги сохранены: без них непонятно, на чём агент застрял.
  check("шаги сохранены для разбора", messages.length === 9,
    String(messages.length));
}

// ─── Недоступный инструмент ──────────────────────────────────────────────────

{
  const agent = await newAgent({ tools: ["now"] });
  const session = await startSession(agent.id);
  const { task, messages } = await runTask(session.id, "запрещённый вызов");

  const toolRow = messages.find((m) => m.role === "tool");
  check("вызов отклонён", toolRow?.status === "error", toolRow?.status);
  check("модели объяснили причину",
    JSON.parse(toolRow.content).ok === false, toolRow.content);
  // Отказ не ломает задание: модель получает ответ и продолжает.
  check("задание всё равно завершилось", task.status === "done", task.status);
}

// ─── Валидация при сохранении агента ─────────────────────────────────────────

{
  const { status, json } = await call("POST", "/api/agents", {
    name: "X", provider_id: "veai", model_id: "Anthropic/sonnet-5",
    tools: ["now", "телепортация", "взлом"],
  });

  check("400 на неизвестный инструмент", status === 400, String(status));
  check("код unknown_tool", json?.error?.code === "unknown_tool",
    json?.error?.code);
  // Сообщить обо всех сразу полезнее, чем по одному.
  check("перечислены все неизвестные",
    json?.error?.message.includes("телепортация") &&
    json.error.message.includes("взлом"),
    json?.error?.message);
}

{
  const { status } = await call("POST", "/api/agents", {
    name: "Чистый", provider_id: "veai", model_id: "Anthropic/sonnet-5",
  });
  check("агент без инструментов допустим", status === 201, String(status));
}

// ─── Отчёт ───────────────────────────────────────────────────────────────────

console.log("=== Инструменты агента ===");
let failed = 0;
for (const [name, ok, detail] of results) {
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? `  [${detail}]` : ""}`);
  if (!ok) failed++;
}
process.exit(failed ? 1 : 0);
