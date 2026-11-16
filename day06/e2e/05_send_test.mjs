// Полный цикл запрос-ответ и разворачивание сырого JSON.
//
// Отвечает мок-провайдер из mock_provider.mjs, поэтому ответы
// предсказуемы и не стоят токенов.

import { mount, helpers, suite } from "./harness.mjs";

const { window, document } = await mount();
const { q, qa, click, type, change, button } = helpers(window, document);
const t = suite("Отправка и диалог");

const html = () => document.body.innerHTML;

await click(q(".btn-new"), 900);
await change(q(".provider-select"), "veai", 600);
await change(q(".model-select"), "Anthropic/sonnet-5", 600);

// ─── Успешный обмен ────────────────────────────────────────────────────────

await type(q(".draft"), "проверка из UI", 300);
t.check("кнопка активна", !q(".btn-send").disabled, q(".btn-send").title);

await click(q(".btn-send"), 2000);

t.check("появилась пара сообщений", qa(".message").length === 2,
  String(qa(".message").length));
t.check("виден вопрос", html().includes("проверка из UI"));
t.check("виден ответ", html().includes("Связь есть"));
t.check("поле очищено", q(".draft").value === "");
t.check("нет ошибок", !q(".banner.error"), q(".banner-body")?.textContent);

// Шапка ответа
t.check("показана модель", html().includes("sonnet-5"));
t.check("показана длительность", /\d+ мс|[\d.]+ с/.test(html()));
t.check("показаны токены", html().includes("20 токенов"));
t.check("вопрос и ответ визуально различаются",
  !!q(".message.user") && !!q(".message.assistant"));

// ─── Сырой JSON ────────────────────────────────────────────────────────────

const jsonButtons = qa(".chip-btn").filter((b) => b.textContent.includes("JSON"));
t.check("кнопка JSON у обоих сообщений", jsonButtons.length === 2,
  String(jsonButtons.length));

await click(jsonButtons[0], 500);
t.check("тело запроса развернулось", !!q(".raw-json"));
t.check("подписано «Тело запроса»", html().includes("Тело запроса"));
t.check("в теле видна модель", q(".raw-json").textContent.includes("Anthropic/sonnet-5"));
t.check("ключ API не попал в сохранённое тело",
  !q(".raw-json").textContent.toLowerCase().includes("bearer") &&
  !html().includes("e2e-test-key"));

await click(jsonButtons[1], 500);
t.check("ответ провайдера развернулся", qa(".raw-json").length === 2);
t.check("подписано «Ответ провайдера»", html().includes("Ответ провайдера"));
t.check("показан HTTP-статус", html().includes("HTTP 200"));
t.check("ответ отформатирован", qa(".raw-json")[1].textContent.includes("\n  "));

await click(jsonButtons[0], 400);
t.check("блок сворачивается обратно", qa(".raw-json").length === 1);

// ─── Рассуждения ───────────────────────────────────────────────────────────

const reasoningButton = qa(".chip-btn").find((b) => b.textContent.includes("Рассуждения"));
t.check("есть кнопка рассуждений", !!reasoningButton);
await click(reasoningButton, 500);
t.check("рассуждения развернулись", !!q(".reasoning-text"),
  q(".reasoning-text")?.textContent.slice(0, 40));

// ─── Независимость запросов ────────────────────────────────────────────────

// В режиме «запрос-ответ» история не передаётся: в теле второго запроса
// должно быть ровно одно сообщение.
await type(q(".draft"), "второй вопрос", 300);
await click(q(".btn-send"), 2000);
t.check("сообщений стало 4", qa(".message").length === 4, String(qa(".message").length));

const secondRequest = qa(".chip-btn").filter((b) => b.textContent.includes("JSON"))[2];
await click(secondRequest, 500);
const body = JSON.parse(qa(".raw-json").at(-1).textContent);
t.check("история не передана: одно сообщение в запросе",
  body.messages.length === 1, `messages: ${body.messages.length}`);
t.check("в запросе только текущий вопрос",
  body.messages[0].content === "второй вопрос", body.messages[0].content);

t.report();
