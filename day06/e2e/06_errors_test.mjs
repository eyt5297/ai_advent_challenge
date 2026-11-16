// Обработка сбоев провайдера.
//
// Мок отвечает ошибкой на слово «ошибка» и мусором на «мусор».
// Главное требование: сбой не роняет сервер и не теряет сырое тело.

import { mount, helpers, suite } from "./harness.mjs";

const { window, document } = await mount();
const { q, qa, click, type, change } = helpers(window, document);
const t = suite("Ошибки провайдера");

const html = () => document.body.innerHTML;

await click(q(".btn-new"), 900);
await change(q(".provider-select"), "veai", 600);
await change(q(".model-select"), "Anthropic/sonnet-5", 600);

// ─── HTTP 429 с телом ошибки ───────────────────────────────────────────────

await type(q(".draft"), "ошибка", 300);
await click(q(".btn-send"), 2000);

t.check("пара сообщений сохранена", qa(".message").length === 2,
  String(qa(".message").length));
t.check("ответ помечен как неудачный", !!q(".message.failed"));
t.check("показан текст ошибки провайдера",
  html().includes("искусственная ошибка провайдера"));
t.check("виден код ошибки", html().includes("test_error"));

// Даже у неудачного ответа сырое тело должно быть доступно — в этом
// основная отладочная ценность каркаса.
const failedJson = qa(".message.failed .chip-btn").find((b) => b.textContent.includes("JSON"));
t.check("у неудачного ответа есть кнопка JSON", !!failedJson);
await click(failedJson, 500);
t.check("сырой ответ сохранён", !!q(".message.failed .raw-json"));
t.check("показан статус 429", html().includes("HTTP 429"));

// ─── Не-JSON в ответе ──────────────────────────────────────────────────────

await type(q(".draft"), "мусор", 300);
await click(q(".btn-send"), 2000);

t.check("сообщений стало 4", qa(".message").length === 4, String(qa(".message").length));
t.check("второй сбой тоже помечен", qa(".message.failed").length === 2);
t.check("объяснено, что ответ не JSON", html().includes("не является JSON"));

const lastJson = qa(".message.failed").at(-1)
  .querySelectorAll(".chip-btn");
await click([...lastJson].find((b) => b.textContent.includes("JSON")), 500);
t.check("сырой мусор сохранён", html().includes("не json"));

// ─── Сервер жив и продолжает работать ──────────────────────────────────────

await type(q(".draft"), "обычный вопрос", 300);
await click(q(".btn-send"), 2000);
t.check("после сбоев обмен снова успешен", html().includes("Связь есть"));
t.check("успешный ответ не помечен ошибкой", qa(".message.failed").length === 2);

const health = await (await fetch("/api/health")).json();
t.check("сервер не упал", health.status === "ok");
t.check("БД на месте", health.db === "connected");

t.report();
