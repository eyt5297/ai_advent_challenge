// Восстановление состояния сессии после перезагрузки страницы.
//
// Разные сессии держат разные настройки — удобно иметь рядом «холодную»
// и «творческую».

import { mount, helpers, suite, createSession } from "./harness.mjs";

const t = suite("Персистентность сессий");

// Готовим две сессии с разными настройками прямо через API.
await createSession({
  title: "Холодная",
  provider_id: "veai",
  model_id: "Anthropic/opus-5",
  params: { temperature: 0.1, max_tokens: 1024 },
});

await createSession({
  title: "Творческая kimi",
  provider_id: "kimi",
  model_id: "k3",
  params: { temperature: 1.4, reasoning_effort: "max" },
});

// Загружаем приложение «с нуля».
const { window, document } = await mount();
const { q, qa, click, button, paramRow } = helpers(window, document);

t.check("обе сессии в списке", qa(".session-item").length === 2,
  String(qa(".session-item").length));

// ─── Творческая (создана последней, значит верхняя) ────────────────────────

const creative = qa(".session-main").find((b) => b.textContent.includes("Творческая"));
t.check("сессия kimi найдена", !!creative);
await click(creative, 1500);

t.check("провайдер восстановлен", q(".provider-select").value === "kimi",
  q(".provider-select").value);
t.check("модель восстановлена", q(".model-select").value === "k3",
  q(".model-select").value);

await click(button("⚙"), 600);
t.check("temperature восстановлена",
  paramRow("temperature").querySelector(".num-sm").value === "1.4",
  paramRow("temperature").querySelector(".num-sm").value);
t.check("счётчик параметров = 2", q(".badge")?.textContent === "2",
  q(".badge")?.textContent);
t.check("усилие max выбрано",
  qa(".segment.selected")[0]?.textContent === "max",
  qa(".segment.selected").map((s) => s.textContent).join(","));
t.check("шкала kimi из 3 значений", qa(".segment").length === 3);

// ─── Переключение на холодную: всё меняется ────────────────────────────────

const cold = qa(".session-main").find((b) => b.textContent.includes("Холодная"));
await click(cold, 1500);

t.check("провайдер переключился на veai", q(".provider-select").value === "veai",
  q(".provider-select").value);
t.check("модель переключилась на opus-5", q(".model-select").value === "Anthropic/opus-5",
  q(".model-select").value);
t.check("temperature другая",
  paramRow("temperature").querySelector(".num-sm").value === "0.1",
  paramRow("temperature").querySelector(".num-sm").value);
t.check("max_tokens восстановлен",
  paramRow("max_tokens").querySelector(".num").value === "1024",
  paramRow("max_tokens").querySelector(".num").value);
t.check("рассуждения не отмечены (их не задавали)",
  qa(".segment").length === 0 || !qa(".segment.selected").length,
  String(qa(".segment").length));
t.check("шкала veai снова из 5 значений",
  paramRow("reasoning").className.includes("off") || qa(".segment").length === 5,
  String(qa(".segment").length));

t.report();
