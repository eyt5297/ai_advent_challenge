// Панель параметров: чекбоксы «использовать», адаптация под модель,
// расхождение шкал усилий между провайдерами.

import { mount, helpers, suite } from "./harness.mjs";

const { window, document } = await mount();
const { q, qa, click, change, check: toggle, button, link, paramRow } =
  helpers(window, document);
const t = suite("Параметры запроса");

const html = () => document.body.innerHTML;

await click(q(".btn-new"), 900);
await click(button("⚙"), 400);

t.check("панель раскрылась", !!q(".params-panel"));
t.check("есть temperature", !!paramRow("temperature"));
t.check("есть max_tokens", !!paramRow("max_tokens"));
t.check("есть reasoning", !!paramRow("reasoning"));
t.check("есть system", !!paramRow("system"));

// Пока ничего не отмечено — счётчика нет, сброс недоступен.
t.check("счётчика нет при пустых параметрах", !q(".badge"));
t.check("«Сбросить всё» недоступен", link("Сбросить всё").disabled);

// ─── temperature ───────────────────────────────────────────────────────────

const temperature = paramRow("temperature");
t.check("контролы temperature выключены", temperature.className.includes("off"));
t.check("слайдер заблокирован", temperature.querySelector(".slider").disabled);

await toggle(temperature.querySelector('input[type="checkbox"]'), 600);
t.check("счётчик появился", q(".badge")?.textContent === "1", q(".badge")?.textContent);
t.check("слайдер разблокирован", !paramRow("temperature").querySelector(".slider").disabled);
t.check("значение по умолчанию 0.7",
  paramRow("temperature").querySelector(".num-sm").value === "0.7",
  paramRow("temperature").querySelector(".num-sm").value);

// ─── max_tokens: лимит берётся из каталога ─────────────────────────────────

await toggle(paramRow("max_tokens").querySelector('input[type="checkbox"]'), 600);
t.check("счётчик стал 2", q(".badge")?.textContent === "2", q(".badge")?.textContent);
t.check("лимит sonnet-5 показан", paramRow("max_tokens").textContent.includes("65 536"),
  paramRow("max_tokens").textContent.match(/\/ [\d ]+/)?.[0]);

// ─── reasoning: главное расхождение провайдеров ────────────────────────────

await toggle(paramRow("reasoning").querySelector('input[type="checkbox"]'), 600);

const veaiEfforts = qa(".segment").map((s) => s.textContent);
t.check("шкала veai из 5 значений", veaiEfforts.length === 5, veaiEfforts.join(","));
t.check("veai знает xhigh", veaiEfforts.includes("xhigh"));
t.check("veai знает medium", veaiEfforts.includes("medium"));
t.check("у veai есть тумблер вкл/выкл", !!q(".radio-pair"));
t.check("по умолчанию выбран medium",
  qa(".segment.selected")[0]?.textContent === "medium",
  qa(".segment.selected").map((s) => s.textContent).join(","));

// Выбираем xhigh — значение, которого у kimi нет.
await click(qa(".segment").find((s) => s.textContent === "xhigh"), 500);
t.check("xhigh выбран", qa(".segment.selected")[0]?.textContent === "xhigh");

// Переключаемся на kimi: шкала обязана сузиться, а значение — замениться.
await change(q(".provider-select"), "kimi", 1000);
const kimiEfforts = qa(".segment").map((s) => s.textContent);
t.check("шкала kimi из 3 значений", kimiEfforts.length === 3, kimiEfforts.join(","));
t.check("kimi не знает xhigh", !kimiEfforts.includes("xhigh"));
t.check("усилие заменено на допустимое",
  !!qa(".segment.selected").length && kimiEfforts.includes(qa(".segment.selected")[0].textContent),
  qa(".segment.selected")[0]?.textContent);
t.check("у kimi выключить рассуждения нельзя", !q(".radio-pair") && !!q(".pill-static"),
  q(".pill-static")?.textContent);
t.check("kimi не сообщает лимит вывода",
  paramRow("max_tokens").textContent.includes("лимит не указан"),
  paramRow("max_tokens").textContent.match(/лимит[^<]*/)?.[0]);

// ─── Модель без рассуждений ────────────────────────────────────────────────

await change(q(".provider-select"), "veai", 800);
await change(q(".model-select"), "Anthropic/haiku-4.5", 800);
t.check("для haiku-4.5 блок reasoning скрыт",
  html().includes("не поддерживает рассуждения"));
t.check("шкала усилий исчезла", qa(".segment").length === 0);

// ─── Сброс ─────────────────────────────────────────────────────────────────

await click(link("Сбросить всё"), 600);
t.check("сброс убрал счётчик", !q(".badge"));
t.check("контролы снова выключены",
  paramRow("temperature").className.includes("off"));

t.report();
