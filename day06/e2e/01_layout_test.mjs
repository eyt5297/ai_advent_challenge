// Базовая отрисовка: монтирование, каталог моделей, статус провайдеров.

import { mount, helpers, suite } from "./harness.mjs";

const { window, document } = await mount();
const { q, qa, button } = helpers(window, document);
const t = suite("Раскладка и каталог");

const html = () => document.body.innerHTML;

t.check("приложение смонтировалось", html().length > 200);
t.check("нет ошибок загрузки", !q(".banner.error"), q(".banner-body")?.textContent);

t.check("есть кнопка «Новый чат»", !!q(".btn-new"));
t.check("есть селект провайдера", !!q(".provider-select"));
t.check("есть селект модели", !!q(".model-select"));
t.check("есть кнопка параметров", !!button("⚙"));
t.check("есть кнопка «Править JSON»", !!button("Править JSON"));
t.check("есть кнопка «Отправить»", !!button("Отправить"));

// Каталог приезжает с сервера, поэтому проверяем конкретные числа:
// 36 моделей veai в 8 группах — ровно то, что лежит в modeles.txt.
t.check("36 моделей veai", qa(".model-select option").length === 36,
  String(qa(".model-select option").length));
t.check("8 групп по вендорам", qa(".model-select optgroup").length === 8,
  qa(".model-select optgroup").map((g) => g.getAttribute("label")).join(","));
t.check("группа «Авто» первая",
  qa(".model-select optgroup")[0]?.getAttribute("label") === "Авто");

t.check("оба провайдера в списке", qa(".provider-select option").length === 2);
t.check("провайдер без ключа помечен и заблокирован",
  !!qa(".provider-select option").find((o) => o.disabled && o.textContent.includes("нет ключа")));

t.check("по умолчанию выбран sonnet-5", q(".model-select").value === "Anthropic/sonnet-5",
  q(".model-select").value);
t.check("подсказка о модели показана", !!q(".model-hint")?.textContent.includes("ctx"),
  q(".model-hint")?.textContent);

// Без сессии писать некуда — поле и отправка заблокированы.
t.check("поле ввода заблокировано без сессии", q(".draft").disabled);
t.check("кнопка отправки объясняет, чего не хватает",
  q(".btn-send").title.includes("сессию"), q(".btn-send").title);

t.report();
