// Видимость длинного содержимого и удаление сообщений.
//
// Регрессия: в flex-колонке пузыри сжимались, и `overflow: hidden`
// срезал текст — в диалоге было видно только первую строку ответа.

import { mount, helpers, suite } from "./harness.mjs";

const { window, document } = await mount();
const { q, qa, click, type, change, button } = helpers(window, document);
const t = suite("Содержимое сообщений и удаление");

const html = () => document.body.innerHTML;

await click(q(".btn-new"), 900);
await change(q(".provider-select"), "veai", 600);
await change(q(".model-select"), "Anthropic/sonnet-5", 600);

// Мок отвечает многоабзацным текстом на слово «длинный».
await type(q(".draft"), "длинный", 300);
await click(q(".btn-send"), 2000);

t.check("обмен состоялся", qa(".message").length === 2, String(qa(".message").length));

// ─── Текст виден целиком ───────────────────────────────────────────────────

const answer = q(".message.assistant .message-body");
t.check("ответ многострочный", (answer.textContent.match(/\n/g) ?? []).length >= 5,
  `переносов: ${(answer.textContent.match(/\n/g) ?? []).length}`);

t.check("последняя строка присутствует в DOM",
  answer.textContent.trim().endsWith("конец ответа"),
  answer.textContent.trim().slice(-20));

// Обрезка была чисто визуальной (flex-shrink + overflow: hidden), а
// happy-dom не вычисляет layout — проверить высоту здесь нельзя.
// Поэтому убеждаемся, что защита от сжатия осталась в стилях.
const css = await (await fetch("/static/app.css")).text();
const messageRule = css.match(/\.message \{[^}]*\}/)?.[0] ?? "";
t.check("пузырь защищён от сжатия flex-колонкой",
  messageRule.includes("flex-shrink: 0"), messageRule.replace(/\s+/g, " "));
t.check("у раскрытого JSON нет жёсткого лимита высоты",
  !/\.raw-json[^{]*\{[^}]*max-height:\s*\d+px/.test(css));

// ─── Многострочный вопрос ──────────────────────────────────────────────────

await type(q(".draft"), "первая строка\nвторая строка\nтретья строка", 300);
await click(q(".btn-send"), 2000);
const question = qa(".message.user .message-body").at(-1);
t.check("вопрос сохранил переносы", question.textContent.includes("\nтретья"),
  JSON.stringify(question.textContent));

// ─── Сырой JSON виден целиком ──────────────────────────────────────────────

const jsonButton = qa(".message.assistant .chip-btn")
  .filter((b) => b.textContent.includes("JSON"))[0];
await click(jsonButton, 500);

const raw = q(".raw-json");
t.check("JSON развернулся", !!raw);
t.check("JSON содержит закрывающую скобку", raw.textContent.trim().endsWith("}"),
  raw.textContent.trim().slice(-20));
t.check("в JSON виден usage", raw.textContent.includes("total_tokens"));

await click(jsonButton, 300);

// ─── Удаление ──────────────────────────────────────────────────────────────

t.check("у сообщений есть кнопка удаления",
  qa(".msg-delete").length === qa(".message").length,
  `${qa(".msg-delete").length} / ${qa(".message").length}`);

const before = qa(".message").length;
// Удаляем за ответ — пара должна уйти целиком.
await click(qa(".message.assistant .msg-delete")[0], 1200);

t.check("удалены оба сообщения пары", qa(".message").length === before - 2,
  `${before} → ${qa(".message").length}`);
t.check("остался второй обмен", html().includes("третья строка"));
t.check("удалённый текст исчез", !html().includes("конец ответа"));
t.check("ошибок нет", !q(".banner.error"), q(".banner-body")?.textContent);

// Удаление за вопрос работает так же.
const remaining = qa(".message").length;
await click(qa(".message.user .msg-delete")[0], 1200);
t.check("удаление за вопрос тоже убирает пару",
  qa(".message").length === remaining - 2,
  `${remaining} → ${qa(".message").length}`);
t.check("диалог опустел", qa(".message").length === 0);

// Изменения дошли до сервера, а не только до экрана.
const sessionId = (await (await fetch("/api/sessions")).json()).sessions[0].id;
const stored = await (await fetch(`/api/sessions/${sessionId}/messages`)).json();
t.check("на сервере сообщений не осталось", stored.messages.length === 0,
  String(stored.messages.length));

t.report();
