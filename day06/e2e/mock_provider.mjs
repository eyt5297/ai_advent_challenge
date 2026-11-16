// Фейковый OpenAI-совместимый провайдер: проверяем полный цикл запрос-ответ,
// включая reasoning_content и ошибки, не тратя токены.
Bun.serve({
  port: 8777,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname.endsWith("/models")) {
      return Response.json({ data: [{ id: "Anthropic/sonnet-5" }] });
    }
    const body = await req.json();
    console.log("← запрос:", JSON.stringify(body));

    // Спецсценарии по тексту сообщения
    const text = body.messages?.at(-1)?.content ?? "";

    // ─── Инструменты ────────────────────────────────────────────────────
    // Модель «решает» вызвать инструмент на первом шаге, а получив
    // результат ролью tool — отвечает текстом. Так проверяется весь цикл.

    const toolResults = body.messages?.filter((m) => m.role === "tool") ?? [];
    // Текущее задание — ПОСЛЕДНЕЕ сообщение пользователя, а не первое.
    // С появлением памяти первыми идут прошлые задания, и поиск с начала
    // выбирал бы сценарий по чужому тексту.
    const userMessages = (body.messages ?? []).filter((m) => m.role === "user");
    const first = userMessages.at(-1)?.content ?? "";

    if (first.includes("кубик") || first.includes("посчитай") || first.includes("время")) {
      if (toolResults.length === 0) {
        const call = first.includes("кубик")
          ? { name: "roll_dice", arguments: '{"count":2,"sides":6}' }
          : first.includes("посчитай")
            ? { name: "calc", arguments: '{"expression":"(2+3)*4"}' }
            : { name: "now", arguments: "{}" };

        return Response.json({
          choices: [{
            message: {
              role: "assistant",
              content: "",
              tool_calls: [{ id: "call_1", type: "function", function: call }],
            },
            finish_reason: "tool_calls",
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
        });
      }

      // Второй шаг идёт долго — так проверяется, что первый уже виден
      // в потоке событий, пока задание ещё выполняется.
      if (first.includes("не спеша")) {
        await new Promise((resolve) => setTimeout(resolve, 1200));
      }

      // Второй шаг: подтверждаем, что результат инструмента дошёл.
      return Response.json({
        choices: [{
          message: {
            role: "assistant",
            content: "Инструмент вернул: " + toolResults.at(-1).content,
          },
          finish_reason: "stop",
        }],
        usage: { prompt_tokens: 20, completion_tokens: 10, total_tokens: 30 },
      });
    }

    // Память: модель просит запомнить факт, затем отвечает текстом.
    if (first.includes("запомни")) {
      if (toolResults.length === 0) {
        return Response.json({
          choices: [{
            message: {
              role: "assistant",
              content: "",
              tool_calls: [{
                id: "call_m",
                type: "function",
                function: {
                  name: "remember",
                  arguments: JSON.stringify({ fact: "пользователя зовут Пётр" }),
                },
              }],
            },
            finish_reason: "tool_calls",
          }],
          usage: { prompt_tokens: 15, completion_tokens: 5, total_tokens: 20 },
        });
      }
      return Response.json({
        choices: [{
          message: { role: "assistant", content: "Запомнил." },
          finish_reason: "stop",
        }],
        usage: { prompt_tokens: 25, completion_tokens: 5, total_tokens: 30 },
      });
    }

    // Проверка памяти: отвечаем тем, что видим в истории. Так тест
    // убеждается, что прошлое действительно дошло до модели.
    if (first.includes("что ты помнишь")) {
      const seen = (body.messages ?? [])
        .map((m) => `${m.role}:${(m.content ?? "").slice(0, 60)}`)
        .join(" | ");
      return Response.json({
        choices: [{
          message: { role: "assistant", content: "Видел: " + seen },
          finish_reason: "stop",
        }],
        usage: { prompt_tokens: 40, completion_tokens: 20, total_tokens: 60 },
      });
    }

    // Сжатие: запрос приходит с инструкцией пересказа и без инструментов.
    if (text.includes("Изложи её кратко")) {
      return Response.json({
        choices: [{
          message: { role: "assistant", content: "ПЕРЕСКАЗ: говорили о числах." },
          finish_reason: "stop",
        }],
        usage: { prompt_tokens: 50, completion_tokens: 10, total_tokens: 60 },
      });
    }

    // Опасные инструменты: мок просит ровно то, что проверяет тест.
    // Ключ — текст задания, аргументы заданы заранее.
    const sandboxCalls = [
      ["прочитай файл", "read_file", { path: "note.txt" }],
      ["прочитай тайну", "read_file", { path: "../outside.txt" }],
      ["сходи в сеть", "http_request", { url: "https://evil.test/x" }],
      ["вспомни", "find_task", { query: "налог" }],
    ];
    const sandbox = sandboxCalls.find(([key]) => first.includes(key));
    if (sandbox) {
      if (toolResults.length === 0) {
        return Response.json({
          choices: [{
            message: {
              role: "assistant",
              content: "",
              tool_calls: [{
                id: "call_s",
                type: "function",
                function: {
                  name: sandbox[1],
                  arguments: JSON.stringify(sandbox[2]),
                },
              }],
            },
            finish_reason: "tool_calls",
          }],
        });
      }
      return Response.json({
        choices: [{
          message: {
            role: "assistant",
            content: "Инструмент вернул: " + toolResults.at(-1).content,
          },
          finish_reason: "stop",
        }],
      });
    }

    // Цепочка делегирования: каждый агент зовёт следующего по номеру.
    // Нужна, чтобы упереться в предел глубины живым путём, а не заглушкой.
    const chain = first.match(/^цепочка (\d+)/);
    if (chain) {
      const next = Number(chain[1]);
      if (toolResults.length === 0) {
        return Response.json({
          choices: [{
            message: {
              role: "assistant",
              content: "",
              tool_calls: [{
                id: "call_c",
                type: "function",
                function: {
                  name: "call_agent",
                  arguments: JSON.stringify({
                    name: "Ц" + next,
                    task: "цепочка " + (next + 1),
                  }),
                },
              }],
            },
            finish_reason: "tool_calls",
          }],
        });
      }
      return Response.json({
        choices: [{
          message: {
            role: "assistant",
            content: "Звено " + next + ": " + toolResults.at(-1).content,
          },
          finish_reason: "stop",
        }],
      });
    }

    // Делегирование: первый агент поручает работу второму.
    if (first.includes("делегируй") || first.includes("рекурсия")) {
      if (toolResults.length === 0) {
        const target = first.includes("рекурсия") ? "Первый" : "Второй";
        return Response.json({
          choices: [{
            message: {
              role: "assistant",
              content: "",
              tool_calls: [{
                id: "call_d",
                type: "function",
                function: {
                  name: "call_agent",
                  arguments: JSON.stringify({ name: target, task: "сделай часть" }),
                },
              }],
            },
            finish_reason: "tool_calls",
          }],
        });
      }
      return Response.json({
        choices: [{
          message: { role: "assistant", content: "Готово: " + toolResults.at(-1).content },
          finish_reason: "stop",
        }],
      });
    }

    // Зацикливание: модель всегда просит инструмент и никогда не отвечает.
    // Нужно, чтобы проверить предел шагов.
    if (first.includes("зациклись")) {
      return Response.json({
        choices: [{
          message: {
            role: "assistant",
            content: "",
            tool_calls: [{
              id: "call_" + (toolResults.length + 1),
              type: "function",
              function: { name: "now", arguments: "{}" },
            }],
          },
          finish_reason: "tool_calls",
        }],
        usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 },
      });
    }

    // Запрос инструмента, которого агенту не давали.
    if (first.includes("запрещённый")) {
      if (toolResults.length === 0) {
        return Response.json({
          choices: [{
            message: {
              role: "assistant",
              content: "",
              tool_calls: [{
                id: "call_x",
                type: "function",
                function: { name: "read_file", arguments: '{"path":"/etc/passwd"}' },
              }],
            },
            finish_reason: "tool_calls",
          }],
        });
      }
      return Response.json({
        choices: [{
          message: { role: "assistant", content: "Понял: " + toolResults.at(-1).content },
          finish_reason: "stop",
        }],
      });
    }
    if (text.includes("ошибка")) {
      return Response.json(
        { error: { message: "искусственная ошибка провайдера", type: "test_error" } },
        { status: 429 },
      );
    }
    if (text.includes("мусор")) {
      return new Response("<html>не json</html>", { status: 200 });
    }
    // Медленный ответ — для проверки параллельной работы: пока он идёт,
    // соседние запросы должны обслуживаться, а не ждать очереди.
    if (text.includes("медленно")) {
      await new Promise((resolve) => setTimeout(resolve, 1500));
      return Response.json({
        choices: [{ message: { role: "assistant", content: "не спеша" },
                    finish_reason: "stop" }],
        usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
      });
    }
    // Многоабзацный ответ — для проверки, что пузырь не обрезает текст.
    if (text.includes("длинный")) {
      return Response.json({
        choices: [{
          message: {
            role: "assistant",
            content: [
              "Первый абзац ответа, в котором довольно много слов.",
              "Второй абзац продолжает мысль и тоже занимает строку.",
              "Третий абзац:",
              "- первый пункт списка",
              "- второй пункт списка",
              "- третий пункт списка",
              "Четвёртый абзац подводит итог.",
              "конец ответа",
            ].join("\n\n"),
          },
          finish_reason: "stop",
        }],
        usage: { prompt_tokens: 20, completion_tokens: 120, total_tokens: 140 },
      });
    }
    return Response.json({
      id: "chatcmpl-test",
      choices: [{
        message: {
          role: "assistant",
          content: "Связь есть. Модель: " + body.model,
          reasoning_content: "Пользователь проверяет связь, отвечаю кратко.",
        },
        finish_reason: "stop",
      }],
      usage: { prompt_tokens: 12, completion_tokens: 8, total_tokens: 20 },
    });
  },
});
console.log("mock провайдер на :8777");
