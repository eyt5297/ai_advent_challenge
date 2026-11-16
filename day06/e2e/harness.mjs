// Общая обвязка для UI-тестов.
//
// Полноценного браузера в окружении нет, поэтому поднимаем DOM через happy-dom
// и исполняем в нём собранный бандл. Этого достаточно, чтобы проверить
// реальные переходы состояния, запросы к серверу и отрисовку.

import { Window } from "happy-dom";
import { writeFileSync } from "fs";

export const BASE = process.env.BASE_URL ?? "http://localhost:8099";

/// Поднимает DOM, подменяет глобалы и исполняет бандл клиента.
export async function mount({ wait: initialWait = 1500 } = {}) {
  const window = new Window({ url: BASE + "/" });
  const document = window.document;

  Object.assign(globalThis, {
    window,
    document,
    navigator: window.navigator,
    // rsvp резолвит относительные URL через location — без него все
    // запросы падают с BadUrl.
    location: window.location,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    requestAnimationFrame: (cb) => setTimeout(() => cb(Date.now()), 0),
    // happy-dom не реализует EventSource, а клиент на нём держит поток
    // событий. Подменяем своей реализацией поверх fetch: протокол тот же,
    // проверяется именно клиентский код.
    EventSource: makeEventSource(),
  });

  document.body.innerHTML = '<div id="app"></div>';

  // Бандл грузим с сервера и кладём во временный файл: динамический
  // import() из data:-URL ломается на кириллице.
  const code = await (await fetch(BASE + "/static/client.js")).text();
  const path = `/tmp/opencode/bundle-${process.pid}.mjs`;
  writeFileSync(path, code);

  const originalFetch = globalThis.fetch;
  globalThis.fetch = (url, options) =>
    originalFetch(
      typeof url === "string" && url.startsWith("/") ? BASE + url : url,
      options,
    );

  await import(path);
  await wait(initialWait);

  return { window, document };
}

export const wait = (ms = 500) => new Promise((r) => setTimeout(r, ms));

/// Минимальный EventSource поверх fetch: разбор потока `text/event-stream`.
///
/// Переподключения нет намеренно — в тестах оно только маскировало бы
/// обрыв, который как раз и хочется заметить.
function makeEventSource() {
  return class EventSource {
    constructor(url) {
      this.listeners = {};
      this.controller = new AbortController();

      (async () => {
        const response = await fetch(BASE + url, {
          signal: this.controller.signal,
        });
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        try {
          while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });

            let edge;
            while ((edge = buffer.indexOf("\n\n")) !== -1) {
              const raw = buffer.slice(0, edge);
              buffer = buffer.slice(edge + 2);

              const name = raw.match(/^event: (.+)$/m)?.[1] ?? "message";
              const data = raw
                .split("\n")
                .filter((line) => line.startsWith("data: "))
                .map((line) => line.slice(6))
                .join("\n");

              for (const handler of this.listeners[name] ?? []) {
                handler({ data });
              }
            }
          }
        } catch {
          // Подписку прервали — штатное завершение.
        }
      })();
    }

    addEventListener(name, handler) {
      (this.listeners[name] ??= []).push(handler);
    }

    close() {
      this.controller.abort();
    }
  };
}

/// Фабрика помощников, привязанных к конкретному окну.
export function helpers(window, document) {
  const q = (selector) => document.querySelector(selector);
  const qa = (selector) => [...document.querySelectorAll(selector)];

  const fire = (el, type) =>
    el.dispatchEvent(new window.Event(type, { bubbles: true }));

  return {
    q,
    qa,
    /// Кнопка по видимому тексту — устойчивее к правкам вёрстки, чем селектор.
    button: (text) => qa("button").find((b) => b.textContent.includes(text)),
    link: (text) => qa(".link-btn").find((b) => b.textContent.includes(text)),
    click: async (el, ms) => {
      fire(el, "click");
      await wait(ms);
    },
    type: async (el, value, ms) => {
      el.value = value;
      fire(el, "input");
      await wait(ms);
    },
    change: async (el, value, ms) => {
      el.value = value;
      fire(el, "change");
      await wait(ms);
    },
    check: async (el, ms) => {
      el.checked = !el.checked;
      fire(el, "change");
      await wait(ms);
    },
    /// Строка панели параметров по имени параметра.
    paramRow: (name) => qa(".param-row").find((r) => r.textContent.includes(name)),
  };
}

/// Простейший сборщик результатов.
export function suite(title) {
  const results = [];

  return {
    check(name, ok, detail = "") {
      results.push([name, Boolean(ok), detail]);
    },
    report() {
      console.log(`=== ${title} ===`);
      let failed = 0;
      for (const [name, ok, detail] of results) {
        console.log(`${ok ? "✓" : "✗"} ${name}${detail ? `  [${detail}]` : ""}`);
        if (!ok) failed++;
      }
      process.exit(failed ? 1 : 0);
    },
  };
}

/// Создаёт сессию напрямую через API — когда тесту нужна подготовленная среда.
export async function createSession(patch = {}) {
  const session = await (
    await fetch(BASE + "/api/sessions", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    })
  ).json();

  if (Object.keys(patch).length) {
    await fetch(BASE + "/api/sessions/" + session.id, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(patch),
    });
  }

  return session;
}
