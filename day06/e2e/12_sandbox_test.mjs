// Опасные инструменты: чтение файлов, сеть и вызов другого агента.
//
// Проверяется не механизм, а границы: что агент НЕ может выйти из
// песочницы, НЕ может дотянуться до чужого хоста и НЕ может зациклить
// делегирование. Юнит-тесты проверяют те же запреты на заглушках —
// здесь всё идёт через живой цикл и настоящую БД.
//
// Окружение задаётся в e2e/run.sh: AGENT_FILES_ROOT с одним файлом,
// AGENT_HTTP_ALLOWLIST=example.com, AGENT_MAX_DEPTH=2.

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
    name: "Исследователь",
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    max_steps: 10,
    tools: ["read_file", "http_request", "find_task", "call_agent"],
    ...overrides,
  })).json;

const startSession = async (agentId) =>
  (await call("POST", `/api/agents/${agentId}/sessions`, {})).json;

const runTask = async (sessionId, prompt) =>
  (await call("POST", `/api/sessions/${sessionId}/tasks`, { prompt })).json;

// Результат инструмента: строка JSON, которую вернули модели.
const toolPayload = (messages) => {
  const row = messages.find((m) => m.role === "tool");
  return { row, body: row ? JSON.parse(row.content) : null };
};

// ─── Каталог инструментов ────────────────────────────────────────────────────

{
  const { json } = await call("GET", "/api/tools");
  const ids = (json?.tools ?? []).map((t) => t.id);

  check("каталог отдаёт все девять инструментов", ids.length === 9,
    ids.join(","));
  check("опасные перечислены вместе с прочими",
    ["read_file", "http_request", "call_agent", "find_task"]
      .every((id) => ids.includes(id)),
    ids.join(","));
}

// ─── read_file: внутри песочницы ─────────────────────────────────────────────

{
  const agent = await newAgent({ name: "Читатель" });
  const session = await startSession(agent.id);
  const { task, messages } = await runTask(session.id, "прочитай файл");
  const { row, body } = toolPayload(messages);

  check("файл внутри корня прочитан", row?.status === "ok", row?.status);
  check("содержимое дошло до модели",
    body?.content?.includes("видимое содержимое"), row?.content?.slice(0, 80));
  check("задание завершилось", task.status === "done", task.status);
}

// ─── read_file: выход за пределы ─────────────────────────────────────────────

{
  const agent = await newAgent({ name: "Любопытный" });
  const session = await startSession(agent.id);
  const { task, messages } = await runTask(session.id, "прочитай тайну");
  const { row, body } = toolPayload(messages);

  check("выход через .. отклонён", row?.status === "error", row?.status);
  check("причина названа", body?.error?.includes("за пределы"), body?.error);
  check("содержимое не утекло",
    !JSON.stringify(messages).includes("тайна снаружи"), "");
  // Отказ — обычный ответ инструменту, а не крах задания.
  check("задание продолжилось после отказа", task.status === "done",
    task.status);
}

// ─── http_request: чужой хост ────────────────────────────────────────────────

{
  const agent = await newAgent({ name: "Сетевой" });
  const session = await startSession(agent.id);
  const { messages } = await runTask(session.id, "сходи в сеть");
  const { row, body } = toolPayload(messages);

  check("хост вне списка отклонён", row?.status === "error", row?.status);
  check("список разрешённых показан",
    body?.error?.includes("example.com"), body?.error);
}

// ─── find_task: память о прошлых заданиях ────────────────────────────────────

{
  const agent = await newAgent({ name: "Памятливый" });
  const session = await startSession(agent.id);

  const first = await runTask(session.id, "налоговый отчёт готов?");
  check("первое задание выполнено", first.task.status === "done",
    first.task.status);

  const { messages } = await runTask(session.id, "вспомни");
  const { row, body } = toolPayload(messages);

  check("поиск по истории сработал", row?.status === "ok", row?.status);
  check("найдено ровно прошлое задание", body?.count === 1,
    String(body?.count));
  check("вернулись и задание, и итог",
    body?.tasks?.[0]?.prompt.includes("налоговый") &&
    body.tasks[0].result.includes("Связь есть"),
    JSON.stringify(body?.tasks?.[0] ?? {}).slice(0, 100));
}

// ─── call_agent: делегирование ───────────────────────────────────────────────

{
  const boss = await newAgent({ name: "Первый" });
  await newAgent({ name: "Второй", tools: ["now"] });
  const session = await startSession(boss.id);
  const { task, messages } = await runTask(session.id, "делегируй работу");
  const { row, body } = toolPayload(messages);

  check("подзадача выполнена", row?.status === "ok", row?.status);
  check("имя исполнителя сохранено", body?.agent === "Второй", body?.agent);
  check("итог исполнителя вернулся вызывающему",
    body?.result?.includes("Связь есть"), body?.result);
  check("родительское задание завершилось", task.status === "done",
    task.status);

  // Вложенный запуск виден отдельной сессией — иначе работа подагента
  // осталась бы невидимой, а наблюдаемость здесь главная ценность.
  const { json } = await call("GET", "/api/sessions");
  const nested = json.sessions.find((s) => s.title === "Второй ← Первый");
  check("вложенный запуск виден в списке сессий", Boolean(nested),
    json.sessions.map((s) => s.title).join(" | "));
  check("у вложенной сессии есть переписка",
    nested && nested.message_count >= 2, String(nested?.message_count));
}

// ─── call_agent: рекурсия ────────────────────────────────────────────────────

{
  const agent = (await call("GET", "/api/agents")).json.agents
    .find((a) => a.name === "Первый");
  const session = await startSession(agent.id);
  const { task, messages } = await runTask(session.id, "рекурсия");
  const { row, body } = toolPayload(messages);

  check("вызов самого себя отклонён", row?.status === "error", row?.status);
  check("названа причина — цикл",
    body?.error?.includes("цепочке вызовов"), body?.error);
  check("задание не повисло", task.status === "done", task.status);
}

// ─── call_agent: предел глубины ──────────────────────────────────────────────

{
  // AGENT_MAX_DEPTH=2: корень зовёт Ц1, Ц1 зовёт Ц2, а Ц2 уже упирается.
  const root = await newAgent({ name: "Корень" });
  for (const name of ["Ц1", "Ц2", "Ц3"]) await newAgent({ name });

  const session = await startSession(root.id);
  const { task } = await runTask(session.id, "цепочка 1");

  check("цепочка дошла до конца без зависания", task.status === "done",
    task.status);
  check("глубина ограничена", task.result?.includes("глубина"),
    task.result?.slice(0, 160));

  const { json } = await call("GET", "/api/sessions");
  const nested = json.sessions.filter((s) => s.title.includes("←"));
  check("созданы ровно два вложенных запуска цепочки",
    nested.filter((s) => s.title.startsWith("Ц")).length === 2,
    nested.map((s) => s.title).join(" | "));
}

// ─── Доступ выдаётся явно ────────────────────────────────────────────────────

{
  const agent = await newAgent({ name: "Безоружный", tools: [] });
  const session = await startSession(agent.id);
  const { messages } = await runTask(session.id, "прочитай файл");
  const { row, body } = toolPayload(messages);

  check("инструмент без разрешения недоступен", row?.status === "error",
    row?.status);
  check("отказ объяснён моделью понятно",
    body?.error?.includes("недоступен") || body?.error?.includes("не выдан"),
    body?.error);
}

// ─── Отчёт ───────────────────────────────────────────────────────────────────

console.log("=== Песочница и делегирование ===");
let failed = 0;
for (const [name, ok, detail] of results) {
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? `  [${detail}]` : ""}`);
  if (!ok) failed++;
}
process.exit(failed ? 1 : 0);
