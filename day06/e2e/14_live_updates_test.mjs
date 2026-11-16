// Живое обновление ленты: шаги появляются по мере выполнения задания.
//
// 13_events_test проверяет сам поток, этот — что клиент его применяет.
// Главная проверка: пока задание ещё выполняется, в ленте уже видны шаги.
//
// Вторая по важности — отсутствие удвоения: те же шаги придут второй раз
// в ответе на POST, и без слияния по `id` лента раздвоилась бы.

import { mount, helpers, suite, wait } from "./harness.mjs";

const BASE = process.env.BASE_URL ?? "http://localhost:8099";

const api = async (method, path, body) => {
  const response = await fetch(BASE + path, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, json: text ? JSON.parse(text) : null };
};

const agent = (await api("POST", "/api/agents", {
  name: "Живой",
  system_prompt: "Ты помощник",
  provider_id: "veai",
  model_id: "Anthropic/sonnet-5",
  max_steps: 5,
  tools: ["calc"],
})).json;

const session = (await api("POST", `/api/agents/${agent.id}/sessions`, {})).json;

const { window, document } = await mount();
const { q, qa, click } = helpers(window, document);
const t = suite("Живое обновление ленты");

t.check("сессия агента открыта", qa(".session-main").length === 1);

// ─── Шаги видны до завершения задания ────────────────────────────────────────

// Задание выдаём через API, а смотрим глазами клиента: так проверяется
// именно поток, а не реакция на собственный запрос.
//
// Мок тянет второй шаг 1,2 секунды — за это время лента должна успеть
// показать первый.
const running = api("POST", `/api/sessions/${session.id}/tasks`, {
  prompt: "посчитай это не спеша",
});

await wait(700);

const liveTasks = qa(".task").length;
const liveSteps = qa(".message").length;

t.check("карточка задания появилась сразу", liveTasks === 1, String(liveTasks));
t.check("задание помечено выполняющимся",
  q(".task")?.className.includes("running"), q(".task")?.className);

// Ради этого всё и делалось: полторы минуты тишины превращаются
// в видимую работу.
t.check("шаги видны, пока задание ещё идёт", liveSteps > 0, String(liveSteps));

await running;
await wait(900);

// ─── Завершение ──────────────────────────────────────────────────────────────

t.check("задание отмечено завершённым",
  q(".task")?.className.includes("done"), q(".task")?.className);
t.check("итог показан",
  q(".task-outcome")?.textContent.includes("Инструмент вернул"),
  q(".task-outcome")?.textContent?.slice(0, 60));

// ─── Без удвоения ────────────────────────────────────────────────────────────

const { json: stored } = await api("GET", `/api/sessions/${session.id}/tasks`);
const taskId = stored.tasks[0].id;
const { json: full } = await api("GET", `/api/tasks/${taskId}`);

t.check("карточка по-прежнему одна", qa(".task").length === 1,
  String(qa(".task").length));

// Шаги свёрнуты, поэтому разворачиваем и считаем.
const toggle = qa(".chip-btn").find((b) => b.textContent.includes("Шаги"));
if (toggle) await click(toggle, 300);

const shown = qa(".message").length;
t.check("шагов ровно столько, сколько в базе",
  shown === full.messages.length,
  `в ленте ${shown}, в базе ${full.messages.length}`);

// ─── Второе задание в той же сессии ──────────────────────────────────────────

await api("POST", `/api/sessions/${session.id}/tasks`, { prompt: "привет" });
await wait(900);

// Подписка идёт на сессию, а не на задание, поэтому переподключение
// не требуется.
t.check("второе задание появилось без перезагрузки", qa(".task").length === 2,
  String(qa(".task").length));

const { json: after } = await api("GET", `/api/sessions/${session.id}/tasks`);
t.check("оба задания завершены",
  after.tasks.every((task) => task.status === "done"),
  after.tasks.map((task) => task.status).join(","));

t.report();
