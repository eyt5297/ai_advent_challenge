// Редактор отправляемого JSON: загрузка тела с сервера, валидация,
// взаимодействие с панелью параметров.

import { mount, helpers, suite } from "./harness.mjs";

const { window, document } = await mount();
const { q, qa, click, type, button, link } = helpers(window, document);
const t = suite("Редактор JSON");

const html = () => document.body.innerHTML;

await click(q(".btn-new"), 900);
await type(q(".draft"), "проверка связи", 300);

// ─── Открытие: тело собирает сервер ────────────────────────────────────────

await click(button("Править JSON"), 1200);
t.check("редактор раскрылся", !!q(".json-editor"));

const editor = q(".json-input");
t.check("тело загружено", !!editor && editor.value.length > 10);
t.check("содержит выбранную модель", editor.value.includes("Anthropic/sonnet-5"));
t.check("содержит текст сообщения", editor.value.includes("проверка связи"));
t.check("отформатировано с отступами", editor.value.includes("\n  "));
t.check("незаданные параметры отсутствуют", !editor.value.includes("temperature"),
  editor.value.match(/"temperature"[^,\n]*/)?.[0] ?? "");

// ─── Валидация ─────────────────────────────────────────────────────────────

await type(editor, "{ это не json", 400);
t.check("ошибка показана", !!q(".json-error"), q(".json-error")?.textContent.trim());
t.check("ошибка на русском", /[а-яА-Я]/.test(q(".json-error")?.textContent ?? ""));
t.check("поле подсвечено красным", q(".json-input").className.includes("invalid"));
t.check("отправка заблокирована", q(".btn-send").disabled);
t.check("причина на кнопке", q(".btn-send").title.includes("JSON"), q(".btn-send").title);

// Массив — валидный JSON, но не объект запроса.
await type(q(".json-input"), "[1, 2, 3]", 400);
t.check("массив отклонён", !!q(".json-error"), q(".json-error")?.textContent.trim());

await type(q(".json-input"), '{"model":"x","messages":[]}', 400);
t.check("валидный JSON принят", !q(".json-error"));
t.check("отправка разблокирована", !q(".btn-send").disabled);
t.check("помечено «изменено вручную»", html().includes("изменено вручную"));

// ─── Панель параметров при ручной правке ───────────────────────────────────

await click(button("⚙"), 500);
t.check("панель параметров заблокирована", !!q(".params-locked"));
t.check("объяснено почему", q(".params-locked").textContent.includes("не применяются"));
t.check("контролов параметров нет", !q(".param-row"));

// ─── Сброс возвращает сгенерированное тело ─────────────────────────────────

await click(link("Вернуться к параметрам"), 1300);
t.check("тело снова сгенерировано",
  q(".json-input")?.value.includes("Anthropic/sonnet-5"),
  q(".json-input")?.value.slice(0, 40).replace(/\n/g, " "));
t.check("метка ручной правки снята", !html().includes("изменено вручную"));
t.check("панель параметров снова активна", !q(".params-locked") && !!q(".param-row"));

// ─── Правка параметра перегенерирует тело ──────────────────────────────────

const temperature = qa(".param-row").find((r) => r.textContent.includes("temperature"));
temperature.querySelector('input[type="checkbox"]').checked = true;
temperature.querySelector('input[type="checkbox"]')
  .dispatchEvent(new window.Event("change", { bubbles: true }));
await new Promise((r) => setTimeout(r, 1300));
t.check("temperature появилась в теле",
  q(".json-input")?.value.includes('"temperature"'),
  q(".json-input")?.value.match(/"temperature":[^,\n]*/)?.[0] ?? "нет");

// ─── Закрытие ──────────────────────────────────────────────────────────────

await click(button("Править JSON"), 400);
t.check("редактор свернулся", !q(".json-editor"));

t.report();
