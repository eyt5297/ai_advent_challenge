// Поток событий сессии: `GET /api/sessions/:id/events`.
//
// Главное здесь — что шаг виден **до** завершения задания. Всё остальное
// (заголовки, изоляция сессий, живучесть) защищает это свойство.
//
// Читаем поток обычным fetch с разбором тела по частям: браузерный
// EventSource в тестовой среде не нужен, а протокол тот же.

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
    name: "Наблюдаемый",
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    max_steps: 5,
    tools: ["now", "calc"],
    ...overrides,
  })).json;

const startSession = async (agentId) =>
  (await call("POST", `/api/agents/${agentId}/sessions`, {})).json;

// Подписка на поток. Собирает события в массив, пока её не остановят.
function listen(sessionId) {
  const controller = new AbortController();
  const collected = [];
  let headers = null;

  const done = (async () => {
    const response = await fetch(`${BASE}/api/sessions/${sessionId}/events`, {
      signal: controller.signal,
    });
    headers = response.headers;

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });

        // События разделены пустой строкой.
        let boundary;
        while ((boundary = buffer.indexOf("\n\n")) !== -1) {
          const raw = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + 2);

          const name = raw.match(/^event: (.+)$/m)?.[1];
          const data = raw
            .split("\n")
            .filter((line) => line.startsWith("data: "))
            .map((line) => line.slice(6))
            .join("\n");

          if (name) {
            let parsed = null;
            try {
              parsed = JSON.parse(data);
            } catch {}
            collected.push({ name, data: parsed, at: Date.now() });
          }
        }
      }
    } catch {
      // Прерывание подписки — штатное завершение.
    }
  })();

  return {
    events: collected,
    stop: () => {
      controller.abort();
      return done;
    },
    headers: () => headers,
    // Ждёт события с нужным именем, не дольше timeout.
    waitFor: async (name, timeout = 5000) => {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        const found = collected.find((e) => e.name === name);
        if (found) return found;
        await new Promise((r) => setTimeout(r, 25));
      }
      return null;
    },
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ─── Заголовки ───────────────────────────────────────────────────────────────

{
  const agent = await newAgent({ name: "Заголовки" });
  const session = await startSession(agent.id);
  const stream = listen(session.id);
  await sleep(300);

  const headers = stream.headers();
  // Без этих заголовков прокси буферизует поток, и весь этап теряет смысл.
  check("content-type: text/event-stream",
    headers?.get("content-type") === "text/event-stream",
    headers?.get("content-type"));
  check("cache-control: no-cache",
    headers?.get("cache-control") === "no-cache",
    headers?.get("cache-control"));

  await stream.stop();
}

// ─── Шаг виден до завершения задания ─────────────────────────────────────────

{
  const agent = await newAgent({ name: "Пошаговый" });
  const session = await startSession(agent.id);
  const stream = listen(session.id);
  await sleep(300);

  // Задание уходит в фоне, чтобы засечь, что придёт раньше.
  let taskFinishedAt = null;
  // Второй шаг мок тянет 1,2 секунды: без этого всё задание занимает
  // десятки миллисекунд, и проверка «раньше» измеряла бы шум.
  const posting = call("POST", `/api/sessions/${session.id}/tasks`, {
    prompt: "посчитай это не спеша",
  }).then((response) => {
    taskFinishedAt = Date.now();
    return response;
  });

  const step = await stream.waitFor("step");
  // Время берём из самого события: опрос в waitFor идёт с шагом в 25 мс,
  // и на быстром задании это было бы заметной долей измеряемого.
  const stepArrivedAt = step?.at;

  const { json } = await posting;
  await sleep(200);

  check("событие step получено", Boolean(step), "");
  // Ради этого всё и делается: шаг виден до конца работы.
  check("шаг пришёл раньше ответа на POST",
    step && taskFinishedAt && stepArrivedAt < taskFinishedAt,
    `опередил на ${taskFinishedAt - stepArrivedAt} мс`);

  check("в событии есть task_id и номер шага",
    step?.data?.task_id?.startsWith("tsk_") && step.data.step === 1,
    JSON.stringify({ id: step?.data?.task_id, step: step?.data?.step }));

  // Шаг с вызовом инструмента объявляется после записи результатов —
  // иначе подписчик увидел бы его наполовину.
  const roles = (step?.data?.messages ?? []).map((m) => m.role);
  check("шаг приходит целиком, вместе с вызовом инструмента",
    roles.join(",") === "user,assistant,tool", roles.join(","));

  check("сообщения той же формы, что у GET /api/tasks/:id",
    step?.data?.messages?.[0]?.id?.startsWith("msg_") &&
    "raw_request" in step.data.messages[0], "");

  const taskEvents = stream.events.filter((e) => e.name === "task");
  check("о задании сообщено дважды: создано и завершено",
    taskEvents.length >= 2, String(taskEvents.length));
  check("последнее состояние — done",
    taskEvents.at(-1)?.data?.task?.status === "done",
    taskEvents.at(-1)?.data?.task?.status);
  check("итог задания совпадает с ответом на POST",
    taskEvents.at(-1)?.data?.task?.result === json.task.result, "");

  await stream.stop();
}

// ─── Изоляция сессий ─────────────────────────────────────────────────────────

{
  const agent = await newAgent({ name: "Изолированный" });
  const mine = await startSession(agent.id);
  const foreign = await startSession(agent.id);

  const listener = listen(foreign.id);
  await sleep(300);

  await call("POST", `/api/sessions/${mine.id}/tasks`, { prompt: "привет" });
  await sleep(500);

  // Утечка между сессиями означала бы показ чужой переписки.
  check("события чужой сессии не приходят", listener.events.length === 0,
    listener.events.map((e) => e.name).join(","));

  await listener.stop();
}

// ─── Несколько подписчиков ───────────────────────────────────────────────────

{
  const agent = await newAgent({ name: "Многооконный" });
  const session = await startSession(agent.id);

  const first = listen(session.id);
  const second = listen(session.id);
  await sleep(300);

  await call("POST", `/api/sessions/${session.id}/tasks`, { prompt: "привет" });
  await sleep(500);

  // Две вкладки на одну сессию — обычное дело.
  check("оба окна получили события",
    first.events.length > 0 && second.events.length > 0,
    `${first.events.length} / ${second.events.length}`);

  await first.stop();
  await second.stop();
}

// ─── Отвал подписчика ────────────────────────────────────────────────────────

{
  const agent = await newAgent({ name: "Брошенный" });
  const session = await startSession(agent.id);

  const abandoned = listen(session.id);
  await sleep(300);
  await abandoned.stop();
  await sleep(200);

  // Браузер закрывают посреди задания — это норма, а не сбой.
  const { status, json } = await call(
    "POST", `/api/sessions/${session.id}/tasks`, { prompt: "привет" });

  check("задание выполняется после ухода подписчика", status === 200,
    String(status));
  check("и завершается успешно", json?.task?.status === "done",
    json?.task?.status);

  // Поток продолжает обслуживать новых подписчиков.
  const fresh = listen(session.id);
  await sleep(300);
  await call("POST", `/api/sessions/${session.id}/tasks`, { prompt: "ещё раз" });
  const step = await fresh.waitFor("step", 4000);

  check("новая подписка работает после отвала прежней", Boolean(step), "");
  await fresh.stop();
}

// ─── Контракт не сломан ──────────────────────────────────────────────────────

{
  const { status, json } = await call("GET", "/api/sessions");
  check("обычные эндпоинты отвечают как прежде",
    status === 200 && Array.isArray(json?.sessions), String(status));

  const { status: missing } = await call(
    "GET", "/api/sessions/нет-такой/tasks");
  check("404 на неизвестную сессию сохранился", missing === 404,
    String(missing));
}

// ─── Отчёт ───────────────────────────────────────────────────────────────────

console.log("=== Поток событий ===");
let failed = 0;
for (const [name, ok, detail] of results) {
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? `  [${detail}]` : ""}`);
  if (!ok) failed++;
}
process.exit(failed ? 1 : 0);
