//// Правая часть: поток сообщений с разворачиваемым сырым JSON.

import client/format
import client/model.{type Model, type Msg}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{attribute as attr, class, id}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/api
import shared/types.{type Message, type Task}

pub fn view(state: Model) -> Element(Msg) {
  html.div(
    [class("dialog"), id("dialog-scroll")],
    list.append(
      memory_bar(state),
      case state.loading, state.active, state.messages {
        True, _, [] -> [placeholder("Загрузка…")]
        _, None, _ -> [welcome()]
        _, Some(_), [] -> [placeholder_empty()]
        _, Some(_), _ -> {
          let bubbles = feed(state)
          case state.sending {
            True -> list.append(bubbles, [pending_bubble()])
            False -> bubbles
          }
        }
      },
    ),
  )
}

/// Строка расхода токенов со свёрнутой панелью памяти.
///
/// Показывается только в сессии агента: у обычного чата нет ни фактов,
/// ни пересказа, а счётчик без них не стоит занимаемого места.
fn memory_bar(state: Model) -> List(Element(Msg)) {
  case state.memory, model.is_agent_session(state) {
    Some(memory), True -> [
      html.div([class("memory-bar")], [
        html.button(
          [
            class(case state.memory_open {
              True -> "chip-btn expanded"
              False -> "chip-btn"
            }),
            event.on_click(model.MemoryPanelToggled),
            attr("title", "Что агент помнит об этом запуске"),
          ],
          [
            html.text(usage_label(memory.usage)),
            html.span([class("caret")], [
              html.text(case state.memory_open {
                True -> "▾"
                False -> "▸"
              }),
            ]),
          ],
        ),
        case state.memory_open {
          False -> element.none()
          True -> memory_panel(memory)
        },
      ]),
    ]
    _, _ -> []
  }
}

/// Точные числа от провайдера, а не оценка: суммируется `usage`
/// сохранённых обменов.
fn usage_label(usage: api.TokenUsage) -> String {
  case usage.total_tokens {
    0 -> "Память агента"
    total ->
      compact(total)
      <> " токенов за "
      <> int.to_string(usage.exchanges)
      <> exchange_suffix(usage.exchanges)
  }
}

fn exchange_suffix(count: Int) -> String {
  case count % 100, count % 10 {
    n, _ if n >= 11 && n <= 14 -> " обменов"
    _, 1 -> " обмен"
    _, n if n >= 2 && n <= 4 -> " обмена"
    _, _ -> " обменов"
  }
}

/// 12345 → «12.3k»: точное число в этой строке не нужно, важен порядок.
fn compact(value: Int) -> String {
  case value < 1000 {
    True -> int.to_string(value)
    False -> {
      let thousands = value / 1000
      let hundreds = { value % 1000 } / 100
      int.to_string(thousands) <> "." <> int.to_string(hundreds) <> "k"
    }
  }
}

fn memory_panel(memory: api.MemoryResponse) -> Element(Msg) {
  html.div([class("memory-panel")], [
    html.div([class("memory-stats")], [
      stat("Запрос", memory.usage.prompt_tokens),
      stat("Ответ", memory.usage.completion_tokens),
      stat("Всего", memory.usage.total_tokens),
    ]),
    case memory.facts {
      [] -> element.none()
      facts ->
        html.div([class("memory-section")], [
          html.span([class("block-label")], [html.text("Запомнено")]),
          html.ul(
            [class("fact-list")],
            list.map(facts, fn(fact) { html.li([], [html.text(fact.text)]) }),
          ),
        ])
    },
    case memory.summary {
      None -> element.none()
      Some(summary) ->
        html.div([class("memory-section")], [
          html.span([class("block-label")], [
            html.text(
              "Пересказ ранней части ("
              <> int.to_string(summary.message_count)
              <> " сообщений)",
            ),
          ]),
          html.p([class("summary-text")], [html.text(summary.text)]),
        ])
    },
    case memory.facts, memory.summary {
      [], None ->
        html.p([class("muted small")], [
          html.text(
            "Пока ничего не запомнено. Факты появятся, если агент "
            <> "воспользуется инструментом remember, пересказ — когда "
            <> "история перерастёт окно.",
          ),
        ])
      _, _ -> element.none()
    },
  ])
}

fn stat(label: String, value: Int) -> Element(Msg) {
  html.span([class("memory-stat")], [
    html.span([class("muted small")], [html.text(label <> ": ")]),
    html.text(int.to_string(value)),
  ])
}

/// Лента: сначала задания агента карточками, затем сообщения вне заданий.
///
/// Два уровня нужны потому, что одно задание порождает несколько обменов
/// с моделью: показывать их вперемешку значило бы потерять границу между
/// «что я попросил» и «как агент к этому шёл».
///
/// У сессии без агента заданий нет, и лента остаётся плоской — ровно
/// такой, какой была до появления агентов.
fn feed(state: Model) -> List(Element(Msg)) {
  let cards = list.map(state.tasks, task_view(state, _))
  let loose = list.map(model.loose_messages(state), message_view(state, _))
  list.append(cards, loose)
}

fn placeholder(text: String) -> Element(Msg) {
  html.div([class("dialog-placeholder")], [html.text(text)])
}

fn welcome() -> Element(Msg) {
  html.div([class("dialog-placeholder welcome")], [
    html.h2([], [html.text("Чат с LLM")]),
    html.p([], [
      html.text("Создайте сессию слева, выберите модель и задайте вопрос."),
    ]),
    html.p([class("muted small")], [
      html.text(
        "Каждый запрос независим: история диалога пока не передаётся модели.",
      ),
    ]),
  ])
}

fn placeholder_empty() -> Element(Msg) {
  html.div([class("dialog-placeholder")], [
    html.p([], [html.text("Сессия пуста. Задайте первый вопрос.")]),
  ])
}

/// Пузырь-заглушка, пока ждём ответ.
fn pending_bubble() -> Element(Msg) {
  html.article([class("message assistant pending")], [
    html.header([class("message-head")], [
      html.span([class("role")], [html.text("Модель")]),
    ]),
    html.div([class("message-body")], [
      html.span([class("typing")], [
        html.span([], []),
        html.span([], []),
        html.span([], []),
      ]),
    ]),
  ])
}

// ─── Задание ─────────────────────────────────────────────────────────────────

/// Карточка задания: что попросили, как агент к этому шёл, что вышло.
///
/// Шаги свёрнуты по умолчанию — обычно нужен итог, а обмен с моделью
/// разворачивают, когда результат вызывает вопросы.
///
/// Исключение — выполняющееся задание: пока итога нет, смотреть больше
/// не на что, и свёрнутая лента показывала бы только крутилку. Ровно от
/// этого и избавляет поток событий.
fn task_view(state: Model, task: Task) -> Element(Msg) {
  let steps = model.steps_of(state, task.id)
  let expanded =
    model.is_task_expanded(state, task.id) || task.status == types.Running

  html.article(
    [
      class("task " <> task_status_class(task.status)),
      attr("data-task", task.id),
    ],
    [
      task_header(task),
      html.div([class("task-prompt")], [html.text(task.prompt)]),
      steps_block(state, task, steps, expanded),
      task_outcome(task),
    ],
  )
}

fn task_header(task: Task) -> Element(Msg) {
  html.header([class("task-head")], [
    html.span([class("task-badge")], [html.text(task_status_label(task.status))]),
    html.span([class("role")], [
      html.text("Задание " <> int.to_string(task.seq)),
    ]),
    html.span([class("head-meta")], [html.text(format.time(task.created_at))]),
    meta_chip(task_duration(task)),
    html.span([class("head-spacer")], []),
    html.button(
      [
        class("icon-btn task-delete"),
        attr("title", "Удалить задание со всеми шагами"),
        attr("aria-label", "Удалить задание"),
        event.on_click(model.TaskDeleteClicked(task.id)),
      ],
      [html.text("×")],
    ),
  ])
}

/// Шаги задания — то самое «наблюдение за обменом между агентом и LLM».
/// Внутри обычные пузыри сообщений, поэтому кнопка `{} JSON` работает
/// здесь без каких-либо доработок.
fn steps_block(
  state: Model,
  task: Task,
  steps: List(Message),
  expanded: Bool,
) -> Element(Msg) {
  case steps {
    [] -> element.none()
    _ ->
      html.div([class("task-steps")], [
        toggle_button(
          step_label(list.length(steps), task.steps),
          expanded,
          model.TaskExpandToggled(task.id),
        ),
        case expanded {
          True ->
            html.div(
              [class("step-list")],
              list.map(steps, message_view(state, _)),
            )
          False -> element.none()
        },
      ])
  }
}

/// Подпись сворачивалки: обменов с моделью и сколько из них шагов.
fn step_label(messages: Int, steps: Int) -> String {
  let exchanges = messages / 2
  case steps <= 1 && exchanges <= 1 {
    True -> "Обмен с моделью"
    False -> "Шаги: " <> int.to_string(int.max(steps, exchanges))
  }
}

fn task_outcome(task: Task) -> Element(Msg) {
  case task.status, task.result, task.error {
    types.Running, _, _ ->
      html.div([class("task-outcome running")], [
        html.span([class("typing")], [
          html.span([], []),
          html.span([], []),
          html.span([], []),
        ]),
      ])

    _, _, Some(error) ->
      html.div([class("task-outcome failed")], [
        html.span([class("outcome-label")], [html.text("Не выполнено")]),
        html.div([class("message-body")], [html.text(error)]),
      ])

    _, Some(result), _ ->
      html.div([class("task-outcome")], [
        html.span([class("outcome-label")], [html.text("Итог")]),
        html.div([class("message-body")], [html.text(result)]),
      ])

    _, _, _ -> element.none()
  }
}

fn task_status_class(status: types.TaskStatus) -> String {
  case status {
    types.Running -> "running"
    types.TaskDone -> "done"
    types.TaskFailed -> "failed"
    types.Cancelled -> "cancelled"
  }
}

fn task_status_label(status: types.TaskStatus) -> String {
  case status {
    types.Running -> "выполняется"
    types.TaskDone -> "готово"
    types.TaskFailed -> "ошибка"
    types.Cancelled -> "отменено"
  }
}

/// Сколько заняло задание — считается по времени завершения, а не по
/// сумме латентностей: ожидание между шагами тоже часть работы.
fn task_duration(task: Task) -> Option(String) {
  case task.finished_at {
    Some(finished) -> Some(format.duration(finished - task.created_at))
    None -> None
  }
}

// ─── Сообщение ───────────────────────────────────────────────────────────────

fn message_view(state: Model, message: Message) -> Element(Msg) {
  let role_class = case message.role {
    types.User -> "user"
    types.Assistant -> "assistant"
    types.System -> "system"
    types.Tool -> "tool"
  }
  let status_class = case message.status {
    types.Failed -> " failed"
    types.Pending -> " pending"
    types.Done -> ""
  }

  html.article([class("message " <> role_class <> status_class)], [
    header(state, message),
    body(message),
    reasoning_block(state, message),
    raw_block(state, message),
  ])
}

fn header(state: Model, message: Message) -> Element(Msg) {
  let raw = raw_payload(message)

  html.header([class("message-head")], [
    html.span([class("role")], [html.text(role_label(message))]),
    html.span([class("head-meta")], [html.text(format.time(message.created_at))]),
    meta_chip(option.map(message.latency_ms, format.duration)),
    meta_chip(non_empty(format.params_summary(message.params))),
    meta_chip(non_empty(format.usage_summary(message.usage))),
    case message.hand_edited {
      True ->
        html.span(
          [
            class("chip warn"),
            attr("title", "тело запроса отредактировано вручную"),
          ],
          [html.text("JSON вручную")],
        )
      False -> element.none()
    },
    html.span([class("head-spacer")], []),
    case message.reasoning {
      Some(_) ->
        toggle_button(
          "Рассуждения",
          model.is_reasoning_expanded(state, message.id),
          model.ReasoningExpandToggled(message.id),
        )
      None -> element.none()
    },
    case raw {
      Some(_) ->
        toggle_button(
          "{} JSON",
          model.is_expanded(state, message.id),
          model.RawToggled(message.id),
        )
      None -> element.none()
    },
    delete_button(message),
  ])
}

/// Удаление обмена. Кнопка есть у обоих сообщений пары — сервер всё равно
/// удалит их вместе, поэтому неважно, за какое из них потянули.
///
/// У шагов задания её нет: шаги связаны историей, и задание без части
/// шагов невоспроизводимо. Там удаляется задание целиком.
fn delete_button(message: Message) -> Element(Msg) {
  case message.task_id {
    Some(_) -> element.none()
    None ->
      html.button(
        [
          class("icon-btn msg-delete"),
          attr("title", "Удалить вопрос и ответ"),
          attr("aria-label", "Удалить сообщение"),
          event.on_click(model.MessageDeleteClicked(message.id)),
        ],
        [html.text("×")],
      )
  }
}

fn role_label(message: Message) -> String {
  case message.role {
    // Внутри задания запрос инициирует не человек, а цикл агента:
    // после вызова инструментов он продолжает разговор сам.
    types.User ->
      case message.task_id, message.content {
        Some(_), "" -> "Агент → модель"
        _, _ -> "Вы"
      }
    types.System -> "Система"
    types.Tool -> "Инструмент"
    types.Assistant ->
      case message.model_id {
        // Для ответа показываем конкретную модель — так проще сравнивать.
        Some(id) -> short_model_name(id)
        None -> "Модель"
      }
  }
}

/// `Anthropic/sonnet-5` → `sonnet-5`: префикс вендора в ленте только мешает.
fn short_model_name(id: String) -> String {
  case string.split(id, "/") {
    [_vendor, name] -> name
    _ -> id
  }
}

fn meta_chip(text: Option(String)) -> Element(Msg) {
  case text {
    Some(value) -> html.span([class("chip")], [html.text(value)])
    None -> element.none()
  }
}

fn non_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    text -> Some(text)
  }
}

fn toggle_button(label: String, expanded: Bool, msg: Msg) -> Element(Msg) {
  html.button(
    [
      class(case expanded {
        True -> "chip-btn expanded"
        False -> "chip-btn"
      }),
      event.on_click(msg),
    ],
    [
      html.text(label),
      html.span([class("caret")], [
        html.text(case expanded {
          True -> "▾"
          False -> "▸"
        }),
      ]),
    ],
  )
}

fn body(message: Message) -> Element(Msg) {
  case message.status, message.content {
    types.Failed, _ ->
      html.div([class("message-body error-body")], [
        html.span([class("error-icon")], [html.text("⚠")]),
        html.span([], [
          html.text(option.unwrap(message.error, "неизвестная ошибка")),
        ]),
      ])

    // Модель не ответила текстом, а запросила инструменты: показываем,
    // какие именно — это и есть содержание шага.
    _, "" ->
      case message.tool_calls {
        // Продолжение разговора после вызова инструментов: нового текста
        // здесь нет по замыслу, и подсказка про JSON только сбивала бы.
        [] ->
          case message.role, message.task_id {
            types.User, Some(_) ->
              html.div([class("message-body muted")], [
                html.text("продолжение после вызова инструментов"),
              ])
            _, _ ->
              html.div([class("message-body muted")], [
                html.text(
                  "(пустой ответ — разверните JSON, чтобы увидеть детали)",
                ),
              ])
          }
        calls ->
          html.div(
            [class("message-body tool-calls")],
            list.map(calls, fn(call) {
              html.div([class("tool-call")], [
                html.span([class("tool-name")], [html.text(call.name)]),
                html.span([class("tool-args")], [html.text(call.arguments)]),
              ])
            }),
          )
      }

    _, content -> html.div([class("message-body")], [html.text(content)])
  }
}

/// Рассуждения модели — отдельный сворачиваемый блок.
fn reasoning_block(state: Model, message: Message) -> Element(Msg) {
  case message.reasoning, model.is_reasoning_expanded(state, message.id) {
    Some(text), True ->
      html.div([class("reasoning-block")], [
        html.div([class("block-label")], [html.text("Рассуждения модели")]),
        html.pre([class("reasoning-text")], [html.text(text)]),
      ])
    _, _ -> element.none()
  }
}

/// Сырой JSON: у запроса — тело, у ответа — то, что вернул провайдер.
fn raw_block(state: Model, message: Message) -> Element(Msg) {
  case raw_payload(message), model.is_expanded(state, message.id) {
    Some(#(label, payload)), True ->
      html.div([class("raw-block")], [
        html.div([class("block-head")], [
          html.span([class("block-label")], [html.text(label)]),
          case message.http_status {
            Some(status) ->
              html.span([class("chip")], [html.text(status_label(status))])
            None -> element.none()
          },
        ]),
        html.pre([class("raw-json")], [html.code([], [html.text(payload)])]),
      ])
    _, _ -> element.none()
  }
}

fn status_label(status: Int) -> String {
  "HTTP " <> int.to_string(status)
}

/// Что показывать в блоке «сырой JSON» для этого сообщения.
fn raw_payload(message: Message) -> Option(#(String, String)) {
  case message.raw_request, message.raw_response {
    Some(request), _ -> Some(#("Тело запроса", request))
    _, Some(response) -> Some(#("Ответ провайдера", pretty(response)))
    _, _ -> None
  }
}

/// Форматирование делаем на клиенте: в БД сырое тело лежит как есть,
/// без лишних отступов.
@external(javascript, "../../client_ffi.mjs", "prettyJson")
fn pretty(raw: String) -> String
