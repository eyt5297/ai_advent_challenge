// Параллельная работа: несколько отправок одновременно.
//
// Регрессия: номер сообщения вычислялся отдельным SELECT, а вставка
// происходила уже после ответа провайдера — через секунды. Параллельные
// отправки читали один и тот же максимум и получали одинаковый seq.
//
// Тест без UI: проверяется сервер, а интерфейс отправку всё равно
// блокирует на время запроса.

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
  return { status: response.status, json: text ? JSON.parse(text) : null };
}

const send = (sessionId, content) =>
  call("POST", `/api/sessions/${sessionId}/send`, {
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    content,
  });

const newSession = async (title) =>
  (await call("POST", "/api/sessions", { title })).json.id;

// ─── Разные сессии работают одновременно ─────────────────────────────────────

{
  const ids = await Promise.all([1, 2, 3, 4].map((n) => newSession(`пар-${n}`)));

  // Мок держит ответ 1.5 с. Последовательное исполнение заняло бы ~6 с.
  const started = Date.now();
  await Promise.all(ids.map((id) => send(id, "медленно")));
  const elapsed = Date.now() - started;

  check("4 запроса по 1.5 с выполнились параллельно", elapsed < 4000,
    `${elapsed} мс`);

  for (const id of ids) {
    const { messages } = (await call("GET", `/api/sessions/${id}/messages`)).json;
    check(`сессия ${id.slice(0, 8)}: ровно пара`, messages.length === 2,
      String(messages.length));
  }
}

// ─── Одна сессия: номера не должны дублироваться ─────────────────────────────

{
  const id = await newSession("гонка");
  const count = 6;

  await Promise.all(
    Array.from({ length: count }, (_, n) => send(id, `запрос ${n + 1}`)),
  );

  const { messages } = (await call("GET", `/api/sessions/${id}/messages`)).json;

  check("сохранились все пары", messages.length === count * 2,
    `${messages.length} из ${count * 2}`);

  const seqs = messages.map((m) => m.seq);
  check("номера уникальны", new Set(seqs).size === seqs.length,
    `уникальных ${new Set(seqs).size} из ${seqs.length}`);
  check("номера идут подряд с единицы",
    seqs.every((s, i) => s === i + 1), seqs.join(","));

  // Главное следствие параллельности: пара больше не соседствует по seq,
  // поэтому связь хранится явно.
  const answers = messages.filter((m) => m.role === "assistant");
  check("у каждого ответа указан запрос",
    answers.every((m) => typeof m.reply_to === "string"),
    `${answers.filter((m) => m.reply_to).length} из ${answers.length}`);

  const questionIds = new Set(messages.filter((m) => m.role === "user").map((m) => m.id));
  check("ссылки ведут на существующие запросы",
    answers.every((m) => questionIds.has(m.reply_to)));
  check("каждый ответ на свой запрос",
    new Set(answers.map((m) => m.reply_to)).size === answers.length);

  // Удаление должно находить пару по ссылке, а не по соседству номеров.
  const scattered = answers.find((m) => {
    const question = messages.find((q) => q.id === m.reply_to);
    return Math.abs(m.seq - question.seq) > 1;
  });
  check("есть пара с несоседними номерами", !!scattered,
    scattered ? `seq ${scattered.seq}` : "все пары оказались рядом");

  if (scattered) {
    const before = messages.length;
    const { json } = await call(
      "DELETE", `/api/sessions/${id}/messages/${scattered.id}`);
    check("удалена ровно пара", json?.deleted?.length === 2,
      String(json?.deleted?.length));

    const after = (await call("GET", `/api/sessions/${id}/messages`)).json.messages;
    check("в БД стало на 2 меньше", after.length === before - 2,
      `${before} → ${after.length}`);
    check("сирот не осталось",
      after.filter((m) => m.role === "assistant")
        .every((m) => after.some((q) => q.id === m.reply_to)));
  }
}

// ─── Отчёт ───────────────────────────────────────────────────────────────────

console.log("=== Параллельная работа ===");
let failed = 0;
for (const [name, ok, detail] of results) {
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? `  [${detail}]` : ""}`);
  if (!ok) failed++;
}
process.exit(failed ? 1 : 0);
