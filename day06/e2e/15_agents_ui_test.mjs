// Экран агентов: создание, правка, запуск.
//
// Проверяется путь целиком — от пустого списка до выполненного задания,
// без единого обращения к API руками. Именно этого не хватало: бэкенд
// умел всё, а дотянуться до него из браузера было нельзя.

import { mount, helpers, suite, wait } from "./harness.mjs";

const BASE = process.env.BASE_URL ?? "http://localhost:8099";

const { window, document } = await mount();
const { q, qa, click, type } = helpers(window, document);
const t = suite("Экран агентов");

const byText = (text) => qa("button").find((b) => b.textContent.includes(text));

// Чекбокс: в браузере клик меняет `checked` и шлёт `change`.
const toggleTool = async (id) => {
  const box = qa(".tool-option")
    .find((l) => l.querySelector(".tool-option-name")?.textContent === id)
    ?.querySelector("input");
  box.checked = !box.checked;
  box.dispatchEvent(new window.Event("change", { bubbles: true }));
  await wait(150);
};

// ─── Вход ────────────────────────────────────────────────────────────────────

t.check("в панели есть кнопка «Агенты»", !!byText("Агенты"));

await click(byText("Агенты"), 800);

t.check("экран открылся", qa(".agents-screen").length === 1);
t.check("диалог скрыт, пока открыт экран", qa(".dialog").length === 0,
  String(qa(".dialog").length));
t.check("пустой список объяснён",
  q(".agents-body .empty-hint")?.textContent.includes("Агентов пока нет"),
  q(".agents-body .empty-hint")?.textContent);

// ─── Форма ───────────────────────────────────────────────────────────────────

await click(byText("Новый агент"), 500);

const toolNames = qa(".tool-option-name").map((e) => e.textContent);
t.check("показаны все девять инструментов", toolNames.length === 9,
  toolNames.join(","));
t.check("у инструментов есть описание для модели",
  qa(".tool-option-hint").every((e) => e.textContent.length > 10));
// Включение read_file или http_request должно быть осознанным действием.
t.check("по умолчанию не выбран ни один",
  qa(".tool-option input").every((i) => !i.checked));

t.check("без имени создать нельзя", q(".btn-send")?.disabled === true,
  String(q(".btn-send")?.disabled));

await type(q(".text-input"), "Рецензент", 200);
const textareas = qa("textarea");
await type(textareas[textareas.length - 1], "Ты внимательный редактор", 200);
await type(q(".num"), "5", 200);
await toggleTool("calc");

t.check("отмечен ровно один инструмент",
  qa(".tool-option input").filter((i) => i.checked).length === 1);
t.check("с именем кнопка разблокирована", q(".btn-send")?.disabled === false);

await click(q(".btn-send"), 1200);

// ─── Список ──────────────────────────────────────────────────────────────────

t.check("агент появился в списке", qa(".agent-row").length === 1,
  String(qa(".agent-row").length));
t.check("показано имя", q(".agent-name")?.textContent === "Рецензент",
  q(".agent-name")?.textContent);
// Вендор виден по группе в списке моделей, в строке он только мешает.
t.check("модель показана коротким именем",
  q(".agent-meta")?.textContent.includes("sonnet-5") &&
  !q(".agent-meta")?.textContent.includes("Anthropic/"),
  q(".agent-meta")?.textContent);

// ─── Правка ──────────────────────────────────────────────────────────────────

await click(qa(".agent-row .icon-btn")[0], 800);

t.check("форма открылась заполненной",
  q(".text-input")?.value === "Рецензент", q(".text-input")?.value);
t.check("предел шагов подставлен", q(".num")?.value === "5", q(".num")?.value);
// Список агентов не содержит промпта — он догружается отдельным запросом.
t.check("системный промпт подтянут",
  qa("textarea").at(-1)?.value === "Ты внимательный редактор",
  qa("textarea").at(-1)?.value);
t.check("выбранный инструмент отмечен",
  qa(".tool-option input").filter((i) => i.checked).length === 1);
t.check("заголовок говорит о настройке",
  q(".form-title")?.textContent.includes("Настройка"),
  q(".form-title")?.textContent);

await click(byText("Отмена"), 400);
t.check("отмена возвращает к списку", qa(".agent-row").length === 1);

// ─── Запуск ──────────────────────────────────────────────────────────────────

await click(byText("Запустить"), 1500);

t.check("экран закрылся после запуска", qa(".agents-screen").length === 0);
t.check("открылся диалог", qa(".dialog").length === 1);
// Главный признак: сессия запущена агентом, а не создана «Новым чатом».
t.check("composer перешёл на язык заданий",
  q(".btn-send")?.textContent.includes("Выдать задание"),
  q(".btn-send")?.textContent);
t.check("сессия появилась в списке слева", qa(".session-item").length === 1,
  String(qa(".session-item").length));

// ─── Задание проходит через инструмент ───────────────────────────────────────

await type(q(".draft"), "посчитай это", 300);
await click(q(".btn-send"), 2500);

t.check("появилась карточка задания", qa(".task").length === 1,
  String(qa(".task").length));
// Инструмент был выбран чекбоксом — проверяем, что выбор доехал до агента.
t.check("выбранный в форме инструмент сработал",
  q(".task-outcome")?.textContent.includes('"result":20.0'),
  q(".task-outcome")?.textContent?.slice(0, 70));

// ─── Удаление запрещено, пока есть запуски ───────────────────────────────────

await click(byText("Агенты"), 800);
await click(qa(".agent-row .icon-btn")[1], 800);

t.check("агент с запусками не удалён", qa(".agent-row").length === 1,
  String(qa(".agent-row").length));
t.check("причина объяснена сервером",
  q(".banner.error")?.textContent.includes("у агента есть запуски"),
  q(".banner.error")?.textContent?.slice(0, 80));

t.report();
