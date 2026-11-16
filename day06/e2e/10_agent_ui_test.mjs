// Интерфейс сессии агента: двухуровневая лента.
//
// Проверяется главное отличие от обычного чата: одно задание —
// одна карточка, внутри которой свёрнут обмен с моделью.

import { mount, helpers, suite } from "./harness.mjs";

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

// Готовим агента и его запуск до старта интерфейса: задача теста —
// проверить показ, а не создание.
const agent = (await api("POST", "/api/agents", {
  name: "Помощник",
  system_prompt: "Ты краткий помощник",
  provider_id: "veai",
  model_id: "Anthropic/sonnet-5",
})).json;

const session = (await api("POST", `/api/agents/${agent.id}/sessions`, {})).json;

const { window, document } = await mount();
const { q, qa, click, type } = helpers(window, document);
const t = suite("Интерфейс агента");

t.check("сессия агента открылась", qa(".session-main").length === 1);

// ─── Composer говорит на языке заданий ───────────────────────────────────────

t.check("кнопка предлагает выдать задание",
  q(".btn-send")?.textContent.includes("Выдать задание"),
  q(".btn-send")?.textContent);
t.check("подсказка поля про задание",
  q(".draft")?.getAttribute("placeholder")?.includes("задание"),
  q(".draft")?.getAttribute("placeholder"));

// ─── Выдача задания ──────────────────────────────────────────────────────────

await type(q(".draft"), "проверь связь", 300);
await click(q(".btn-send"), 2500);

t.check("появилась карточка задания", qa(".task").length === 1,
  String(qa(".task").length));
t.check("задание помечено готовым", !!q(".task.done"),
  q(".task")?.className);
t.check("текст задания виден",
  q(".task-prompt")?.textContent.includes("проверь связь"),
  q(".task-prompt")?.textContent);
t.check("итог показан", !!q(".task-outcome"),
  q(".task-outcome")?.textContent?.slice(0, 40));
t.check("поле ввода очистилось", q(".draft")?.value === "", q(".draft")?.value);

// Обмен с моделью скрыт, пока его не раскроют: обычно нужен итог.
t.check("шаги свёрнуты по умолчанию", qa(".step-list").length === 0);
t.check("есть кнопка раскрытия шагов",
  qa(".task .chip-btn").length === 1,
  String(qa(".task .chip-btn").length));

// ─── Наблюдение за обменом ───────────────────────────────────────────────────

await click(qa(".task .chip-btn")[0], 500);

t.check("шаги раскрылись", qa(".step-list").length === 1);
t.check("внутри пара запрос-ответ",
  qa(".step-list .message").length === 2,
  String(qa(".step-list .message").length));

// Главная ценность: видно, что именно ушло модели.
const jsonButtons = qa(".step-list .chip-btn")
  .filter((b) => b.textContent.includes("JSON"));
t.check("у шагов работает кнопка JSON", jsonButtons.length === 2,
  String(jsonButtons.length));

await click(jsonButtons[0], 400);
const raw = q(".step-list .raw-json")?.textContent ?? "";
t.check("в запросе виден системный промпт агента",
  raw.includes("Ты краткий помощник"), raw.slice(0, 60));
await click(jsonButtons[0], 300);

// Шаги по отдельности не удаляются — задание без них невоспроизводимо.
t.check("у шагов нет кнопки удаления",
  qa(".step-list .msg-delete").length === 0,
  String(qa(".step-list .msg-delete").length));
t.check("у задания кнопка удаления есть",
  qa(".task-delete").length === 1);

// ─── Неудачное задание ───────────────────────────────────────────────────────

await type(q(".draft"), "ошибка", 300);
await click(q(".btn-send"), 2500);

t.check("второе задание добавилось", qa(".task").length === 2,
  String(qa(".task").length));
t.check("неудача помечена отдельно", !!q(".task.failed"));
t.check("причина показана в итоге",
  q(".task.failed .task-outcome")?.textContent.includes("ошибк"),
  q(".task.failed .task-outcome")?.textContent?.slice(0, 50));
t.check("баннера ошибки нет: сбой провайдера — это состояние задания",
  !q(".banner.error"), q(".banner-body")?.textContent);

// ─── Удаление задания ────────────────────────────────────────────────────────

await click(qa(".task-delete")[0], 1200);

t.check("карточка исчезла", qa(".task").length === 1,
  String(qa(".task").length));
t.check("осталось неудачное задание", !!q(".task.failed"));

const stored = (await api("GET", `/api/sessions/${session.id}/tasks`)).json;
t.check("на сервере тоже одно задание", stored.tasks.length === 1,
  String(stored.tasks.length));

// Шаги удалённого задания ушли вместе с ним.
const messages = (await api("GET", `/api/sessions/${session.id}/messages`)).json;
t.check("шаги удалённого задания убраны",
  messages.messages.every((m) => !m.content.includes("проверь связь")),
  String(messages.messages.length));

t.report();
