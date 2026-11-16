// Память агента между заданиями.
//
// Проверяется то, ради чего всё делалось: во втором задании агент видит
// первое. И то, без чего это опасно: бюджет, изоляция сессий, выключенная
// память как поведение по умолчанию для старых агентов.
//
// Мок на «что ты помнишь» отвечает содержимым полученной истории —
// поэтому видно не наши намерения, а то, что реально ушло в модель.

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

const newAgent = async (memory, overrides = {}) =>
  (await call("POST", "/api/agents", {
    name: "Помнящий " + Math.random().toString(36).slice(2, 7),
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    max_steps: 5,
    tools: ["remember", "forget"],
    memory,
    ...overrides,
  })).json;

const startSession = async (agentId) =>
  (await call("POST", `/api/agents/${agentId}/sessions`, {})).json;

const runTask = async (sessionId, prompt) =>
  (await call("POST", `/api/sessions/${sessionId}/tasks`, { prompt })).json;

const outcomes = (tasks) => ({
  window: "outcomes",
  window_tasks: tasks,
  summary_every: 0,
  facts: false,
  budget_chars: 0,
});

// ─── Без памяти: прежнее поведение ───────────────────────────────────────────

{
  const agent = await newAgent({
    window: "none", summary_every: 0, facts: false, budget_chars: 0,
  });
  const session = await startSession(agent.id);

  await runTask(session.id, "первое задание про числа");
  const { task } = await runTask(session.id, "что ты помнишь");

  check("без памяти прошлое не передаётся",
    !task.result?.includes("первое задание"), task.result?.slice(0, 80));
}

// ─── Агент без поля memory ведёт себя как раньше ─────────────────────────────

{
  const { json } = await call("POST", "/api/agents", {
    name: "Старый " + Math.random().toString(36).slice(2, 7),
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
  });

  // Молча менять поведение существующих агентов нельзя.
  check("умолчание — без памяти", json?.memory?.window === "none",
    json?.memory?.window);
  check("умолчание — без пересказа", json?.memory?.summary_every === 0,
    String(json?.memory?.summary_every));
}

// ─── Окно: задание и итог ────────────────────────────────────────────────────

{
  const agent = await newAgent(outcomes(10));
  const session = await startSession(agent.id);

  await runTask(session.id, "первое задание про числа");
  await runTask(session.id, "второе задание про буквы");
  const { task } = await runTask(session.id, "что ты помнишь");

  // Ради этого всё и делалось.
  check("прошлые задания дошли до модели",
    task.result?.includes("первое задание") &&
    task.result?.includes("второе задание"),
    task.result?.slice(0, 120));
  check("итоги прошлых заданий тоже",
    task.result?.includes("Связь есть"), "");
  // Шаги не передаются: в окне «задание и итог» их быть не должно.
  check("шаги прошлых заданий не передаются",
    !task.result?.includes("tool:"), task.result?.slice(0, 120));
}

// ─── Окно ограничено ─────────────────────────────────────────────────────────

{
  const agent = await newAgent(outcomes(1));
  const session = await startSession(agent.id);

  // Слова не должны быть подстроками друг друга: «давнее» входит
  // в «недавнее», и проверка прошла бы по ошибке.
  await runTask(session.id, "позапрошлое задание");
  await runTask(session.id, "свежее задание");
  const { task } = await runTask(session.id, "что ты помнишь");

  // Недавнее важнее давнего: вытесняется с головы.
  check("за окно не выходит",
    !task.result?.includes("позапрошлое"), task.result?.slice(0, 120));
  check("последнее задание осталось",
    task.result?.includes("свежее задание"), task.result?.slice(0, 120));
}

// ─── Память не течёт между сессиями ──────────────────────────────────────────

{
  const agent = await newAgent(outcomes(10));
  const mine = await startSession(agent.id);
  const other = await startSession(agent.id);

  await runTask(mine.id, "секрет первой сессии");
  const { task } = await runTask(other.id, "что ты помнишь");

  check("чужая сессия не видна",
    !task.result?.includes("секрет первой"), task.result?.slice(0, 100));
}

// ─── Факты ───────────────────────────────────────────────────────────────────

{
  const agent = await newAgent({
    window: "none", summary_every: 0, facts: true, budget_chars: 0,
  });
  const session = await startSession(agent.id);

  const first = await runTask(session.id, "запомни про меня");
  check("инструмент remember сработал", first.task.status === "done",
    first.task.status);

  const { json } = await call("GET", `/api/sessions/${session.id}/memory`);
  check("факт сохранён", json?.facts?.length === 1,
    JSON.stringify(json?.facts ?? []));
  check("текст факта на месте",
    json?.facts?.[0]?.text?.includes("Пётр"), json?.facts?.[0]?.text);

  const { task } = await runTask(session.id, "что ты помнишь");
  // Память окна выключена, а факт всё равно дошёл — это разные слои.
  check("факт передан модели даже без окна",
    task.result?.includes("Пётр"), task.result?.slice(0, 120));
  check("факты идут ролью system",
    task.result?.includes("system:"), task.result?.slice(0, 120));
}

// ─── Пересказ ────────────────────────────────────────────────────────────────

{
  const agent = await newAgent({
    window: "outcomes", window_tasks: 1,
    // Низкий порог: иначе пришлось бы гонять двадцать заданий.
    summary_every: 2, facts: false, budget_chars: 0,
  });
  const session = await startSession(agent.id);

  await runTask(session.id, "задание один");
  await runTask(session.id, "задание два");
  await runTask(session.id, "задание три");

  const { json } = await call("GET", `/api/sessions/${session.id}/memory`);
  check("пересказ создан", Boolean(json?.summary),
    JSON.stringify(json?.summary ?? null)?.slice(0, 80));
  check("текст пересказа от модели",
    json?.summary?.text?.includes("ПЕРЕСКАЗ"), json?.summary?.text);
  check("отмечено, докуда пересказано",
    json?.summary?.covers_through_seq > 0,
    String(json?.summary?.covers_through_seq));

  // Главное свойство: сжатие не трогает исходные сообщения.
  const { json: stored } = await call(
    "GET", `/api/sessions/${session.id}/messages`);
  check("исходные сообщения не удалены", stored?.messages?.length >= 6,
    String(stored?.messages?.length));

  const { task } = await runTask(session.id, "что ты помнишь");
  check("пересказ передан модели",
    task.result?.includes("ПЕРЕСКАЗ"), task.result?.slice(0, 120));
}

// ─── Бюджет ──────────────────────────────────────────────────────────────────

{
  const agent = await newAgent({
    window: "everything", summary_every: 0, facts: false,
    // Хватит на пару сообщений, не больше.
    budget_chars: 60,
  });
  const session = await startSession(agent.id);

  await runTask(session.id, "первое очень давнее задание в этой сессии");
  await runTask(session.id, "второе задание");
  const { task } = await runTask(session.id, "что ты помнишь");

  // Срезать лишнее должны мы, а не провайдер отказом.
  check("задание выполнено, несмотря на тесный бюджет",
    task.status === "done", task.status);
  check("давнее вытеснено бюджетом",
    !task.result?.includes("очень давнее"), task.result?.slice(0, 120));
}

// ─── Счётчик токенов ─────────────────────────────────────────────────────────

{
  const agent = await newAgent(outcomes(5));
  const session = await startSession(agent.id);

  const { json: before } = await call(
    "GET", `/api/sessions/${session.id}/memory`);
  check("у пустой сессии ноль токенов", before?.usage?.total_tokens === 0,
    String(before?.usage?.total_tokens));

  await runTask(session.id, "первое задание");
  const { json: after } = await call(
    "GET", `/api/sessions/${session.id}/memory`);

  check("токены посчитаны", after?.usage?.total_tokens > 0,
    String(after?.usage?.total_tokens));
  check("запрос и ответ разделены",
    after?.usage?.prompt_tokens > 0 && after?.usage?.completion_tokens > 0,
    `${after?.usage?.prompt_tokens} + ${after?.usage?.completion_tokens}`);
  check("сумма сходится",
    after.usage.prompt_tokens + after.usage.completion_tokens ===
      after.usage.total_tokens, "");
  check("обмены посчитаны", after?.usage?.exchanges >= 1,
    String(after?.usage?.exchanges));
}

// ─── Настройка через API ─────────────────────────────────────────────────────

{
  const agent = await newAgent(outcomes(7));
  check("память сохранена при создании",
    agent?.memory?.window === "outcomes" && agent.memory.window_tasks === 7,
    JSON.stringify(agent?.memory));

  const { json } = await call("PATCH", `/api/agents/${agent.id}`, {
    memory: {
      window: "transcripts", window_tasks: 3,
      summary_every: 15, facts: true, budget_chars: 1000,
    },
  });

  check("память меняется правкой",
    json?.memory?.window === "transcripts" &&
    json.memory.window_tasks === 3 &&
    json.memory.summary_every === 15 &&
    json.memory.facts === true &&
    json.memory.budget_chars === 1000,
    JSON.stringify(json?.memory));
}

// ─── Отчёт ───────────────────────────────────────────────────────────────────

console.log("=== Память агента ===");
let failed = 0;
for (const [name, ok, detail] of results) {
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? `  [${detail}]` : ""}`);
  if (!ok) failed++;
}
process.exit(failed ? 1 : 0);
