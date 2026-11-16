// FFI для вещей, которых нет в stdlib: локальное время, буфер обмена,
// автоскролл и автовысота textarea.

const timeFormat = new Intl.DateTimeFormat("ru-RU", {
  hour: "2-digit",
  minute: "2-digit",
});

const dateTimeFormat = new Intl.DateTimeFormat("ru-RU", {
  day: "2-digit",
  month: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
});

export function formatTime(timestampMs) {
  return timeFormat.format(new Date(timestampMs));
}

export function formatDateTime(timestampMs) {
  return dateTimeFormat.format(new Date(timestampMs));
}

export function formatRelative(timestampMs) {
  const seconds = Math.floor((Date.now() - timestampMs) / 1000);

  if (seconds < 60) return "только что";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} мин назад`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} ч назад`;
  if (seconds < 604800) return `${Math.floor(seconds / 86400)} дн назад`;

  return dateTimeFormat.format(new Date(timestampMs));
}

// Копирование в буфер. Возвращает true при успехе.
export function copyToClipboard(text) {
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
    return true;
  }
  return fallbackCopy(text);
}

function fallbackCopy(text) {
  try {
    const area = document.createElement("textarea");
    area.value = text;
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(area);
    return ok;
  } catch {
    return false;
  }
}

// Прокручивает диалог вниз. Вызывается после отрисовки новых сообщений,
// поэтому откладываем на следующий кадр.
export function scrollDialogToBottom() {
  requestAnimationFrame(() => {
    const dialog = document.getElementById("dialog-scroll");
    if (dialog) dialog.scrollTop = dialog.scrollHeight;
  });
  return null;
}

// Подгоняет высоту textarea под содержимое, но не выше max-height из CSS.
export function autoResize(elementId) {
  requestAnimationFrame(() => {
    const el = document.getElementById(elementId);
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  });
  return null;
}

export function focusElement(elementId) {
  requestAnimationFrame(() => {
    const el = document.getElementById(elementId);
    if (el) {
      el.focus();
      if (el.select) el.select();
    }
  });
  return null;
}

// Проверка JSON на стороне клиента: мгновенная подсветка ошибки в редакторе,
// без похода на сервер. Пустая строка означает «ошибок нет».
export function validateJson(text) {
  if (text.trim() === "") return "тело запроса пустое";

  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return "тело запроса должно быть JSON-объектом";
    }
    return "";
  } catch (error) {
    return translateJsonError(error.message);
  }
}

// Форматирует JSON с отступом в 2 пробела. Неразбираемое тело возвращаем
// как есть: лучше показать сырой текст, чем ничего.
export function prettyJson(raw) {
  try {
    return JSON.stringify(JSON.parse(raw), null, 2);
  } catch {
    return raw;
  }
}

// Сообщения движка приходят по-английски и различаются между V8 (Chrome),
// SpiderMonkey (Firefox) и JSC (Safari), поэтому покрываем все три формата.
function translateJsonError(message) {
  const patterns = [
    // Общее для всех движков
    [/Unexpected end of (JSON input|input)/i, "неожиданный конец JSON"],
    [
      /Unexpected token (.+?)(?:,.*?)? in JSON at position (\d+)/i,
      (m) => `неожиданный символ ${m[1]} в позиции ${m[2]}`,
    ],
    [
      /Expected (.+?) after (.+?) in JSON at position (\d+)/i,
      (m) => `ожидалось ${m[1]} после ${m[2]} в позиции ${m[3]}`,
    ],
    [
      /Unterminated string in JSON at position (\d+)/i,
      (m) => `незакрытая строка в позиции ${m[1]}`,
    ],
    [
      /Bad control character in string literal in JSON at position (\d+)/i,
      (m) => `недопустимый управляющий символ в позиции ${m[1]}`,
    ],
    // JSC / Safari
    [
      /JSON Parse error: Unrecognized token '?(.+?)'?$/i,
      (m) => `недопустимый символ «${m[1]}»`,
    ],
    [
      /JSON Parse error: Expected '(.+?)'/i,
      (m) => `ожидался символ «${m[1]}»`,
    ],
    [/JSON Parse error: Unterminated string/i, "незакрытая строка"],
    [/JSON Parse error: (.+)$/i, (m) => `ошибка разбора: ${m[1]}`],
    // SpiderMonkey / Firefox
    [
      /JSON\.parse: unexpected character at line (\d+) column (\d+)/i,
      (m) => `неожиданный символ в строке ${m[1]}, столбец ${m[2]}`,
    ],
    [
      /JSON\.parse: unterminated string at line (\d+) column (\d+)/i,
      (m) => `незакрытая строка в строке ${m[1]}, столбец ${m[2]}`,
    ],
    [
      /JSON\.parse: expected (.+?) at line (\d+) column (\d+)/i,
      (m) => `ожидалось ${m[1]} в строке ${m[2]}, столбец ${m[3]}`,
    ],
    [/JSON\.parse: (.+?) at line (\d+)/i, (m) => `${m[1]} в строке ${m[2]}`],
  ];

  for (const [pattern, replacement] of patterns) {
    const match = message.match(pattern);
    if (match) {
      return typeof replacement === "function" ? replacement(match) : replacement;
    }
  }

  return message;
}

// ─── Поток событий сессии ────────────────────────────────────────────────────

// Открытая подписка. Одна на всё приложение: сессия активна ровно одна,
// а оставленный поток продолжал бы слать события закрытой сессии.
let eventStream = null;

// Подписывается на события сессии и зовёт onEvent(имя, разобранное_тело).
//
// EventSource переподключается сам, поэтому обработка обрыва тут не
// нужна: на время паузы остаётся прежнее поведение — результат придёт
// с ответом на POST.
export function openEventStream(sessionId, onEvent) {
  closeEventStream();

  if (typeof EventSource === "undefined") return false;

  try {
    const source = new EventSource(`/api/sessions/${sessionId}/events`);

    for (const name of ["step", "task"]) {
      source.addEventListener(name, (message) => {
        try {
          onEvent(name, JSON.parse(message.data));
        } catch {
          // Нечитаемое событие пропускаем: состояние всё равно
          // подтвердится ответом на запрос.
        }
      });
    }

    eventStream = source;
    return true;
  } catch {
    return false;
  }
}

export function closeEventStream() {
  if (eventStream) {
    eventStream.close();
    eventStream = null;
  }
}
