// Управление сессиями: создание, выбор, переименование, удаление.

import { mount, helpers, suite, wait } from "./harness.mjs";

const { window, document } = await mount();
const { q, qa, click, type } = helpers(window, document);
const t = suite("Сессии");

const html = () => document.body.innerHTML;

t.check("на пустой базе показана подсказка", !!q(".empty-hint"));

// Создание
await click(q(".btn-new"), 900);
t.check("сессия создана", qa(".session-item").length === 1);
t.check("заголовок по умолчанию", html().includes("Новый чат"));
t.check("поле ввода разблокировалось", !q(".draft").disabled);

await click(q(".btn-new"), 900);
t.check("вторая сессия создана", qa(".session-item").length === 2);
t.check("активна ровно одна", qa(".session-item.active").length === 1);

// Новая сессия встаёт наверх списка и сразу активна.
t.check("активна верхняя (самая свежая)",
  qa(".session-item")[0].className.includes("active"));

// Переключение
await click(qa(".session-main")[1], 900);
t.check("переключились на вторую",
  qa(".session-item")[1].className.includes("active"));

// Переименование
await click(qa(".session-item")[1].querySelector(".icon-btn"), 500);
t.check("появилось поле переименования", !!q(".rename-input"));
await type(q(".rename-input"), "Мой чат", 200);
q(".rename-input").dispatchEvent(
  new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }),
);
await wait(900);
t.check("имя сохранилось", html().includes("Мой чат"), html().includes("Мой чат") ? "" : "нет");
t.check("поле переименования закрылось", !q(".rename-input"));

// Автозаголовок не должен затирать ручное имя — проверяем на уровне API
const sessions = await (await fetch("/api/sessions")).json();
t.check("на сервере имя тоже обновилось",
  sessions.sessions.some((s) => s.title === "Мой чат"));

// Удаление
const before = qa(".session-item").length;
const deleteButton = qa(".session-item")[0].querySelectorAll(".icon-btn")[1];
await click(deleteButton, 900);
t.check("сессия удалена", qa(".session-item").length === before - 1,
  `${before} → ${qa(".session-item").length}`);

t.report();
