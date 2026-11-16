//// Экран агентов: список, форма настройки и запуск.
////
//// Открывается поверх диалога, а не рядом с ним: агент — это настройка,
//// и смотреть на неё одновременно с перепиской незачем. Закрывается —
//// возвращается прежний интерфейс без изменений.

import client/model.{type Model, type Msg}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import lustre/attribute.{attribute as attr, checked, class, disabled, value}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/api as dto
import shared/types.{type AgentSummary, type ModelGroup, type ModelInfo}

pub fn view(state: Model) -> Element(Msg) {
  case state.agents.open {
    False -> element.none()
    True ->
      html.div([class("agents-screen")], [
        header(),
        case state.agents.form {
          Some(form) -> form_view(state, form)
          None -> list_view(state)
        },
      ])
  }
}

fn header() -> Element(Msg) {
  html.header([class("agents-head")], [
    html.h2([class("agents-title")], [html.text("Агенты")]),
    html.span([class("head-spacer")], []),
    html.button(
      [
        class("icon-btn"),
        attr("title", "Закрыть"),
        attr("aria-label", "Закрыть"),
        event.on_click(model.AgentsClosed),
      ],
      [html.text("×")],
    ),
  ])
}

// ─── Список ──────────────────────────────────────────────────────────────────

fn list_view(state: Model) -> Element(Msg) {
  html.div([class("agents-body")], [
    html.p([class("muted small")], [
      html.text(
        "Агент — настроенный исполнитель: промпт, модель и инструменты "
        <> "задаются один раз. Запуск создаёт сессию, в которой агенту "
        <> "выдают задания.",
      ),
    ]),
    html.button(
      [class("btn btn-new"), event.on_click(model.AgentCreateClicked)],
      [
        html.span([class("btn-icon")], [html.text("+")]),
        html.text("Новый агент"),
      ],
    ),
    case state.agents.list {
      [] -> empty_hint()
      agents -> html.div([class("agent-list")], list.map(agents, agent_row))
    },
  ])
}

fn empty_hint() -> Element(Msg) {
  html.p([class("empty-hint")], [
    html.text("Агентов пока нет. Создайте первого — настройка займёт минуту."),
  ])
}

fn agent_row(agent: AgentSummary) -> Element(Msg) {
  html.div([class("agent-row"), attr("data-agent", agent.id)], [
    html.div([class("agent-main")], [
      html.span([class("agent-name")], [html.text(agent.name)]),
      html.span([class("agent-meta")], [
        html.text(short_model(agent.model_id)),
        case agent.session_count {
          0 -> element.none()
          count ->
            html.span([class("dot-sep")], [
              html.text(" · " <> runs_label(count)),
            ])
        },
      ]),
    ]),
    html.div([class("agent-actions")], [
      html.button(
        [
          class("btn btn-run"),
          event.on_click(model.AgentRunClicked(agent.id)),
          attr("title", "Создать запуск и выдать задание"),
        ],
        [html.text("Запустить")],
      ),
      icon_button("Настроить", "✎", model.AgentEditClicked(agent.id)),
      icon_button("Удалить", "×", model.AgentDeleteClicked(agent.id)),
    ]),
  ])
}

/// `Anthropic/sonnet-5` → `sonnet-5`: вендор виден по группе в списке
/// моделей, а в строке он только занимает место.
fn short_model(model_id: String) -> String {
  case string.split(model_id, "/") {
    [_, name] -> name
    _ -> model_id
  }
}

fn runs_label(count: Int) -> String {
  let word = case count % 100, count % 10 {
    n, _ if n >= 11 && n <= 14 -> "запусков"
    _, 1 -> "запуск"
    _, n if n >= 2 && n <= 4 -> "запуска"
    _, _ -> "запусков"
  }
  int.to_string(count) <> " " <> word
}

// ─── Форма ───────────────────────────────────────────────────────────────────

fn form_view(state: Model, form: model.AgentForm) -> Element(Msg) {
  let editing = form.id != None

  html.div([class("agents-body agent-form")], [
    html.h3([class("form-title")], [
      html.text(case editing {
        True -> "Настройка агента"
        False -> "Новый агент"
      }),
    ]),
    field(
      "Имя",
      "Как называть агента: «Рецензент», «Переводчик»",
      html.input([
        class("text-input"),
        value(form.name),
        attr("placeholder", "Рецензент"),
        event.on_input(model.AgentNameChanged),
      ]),
    ),
    field(
      "Описание",
      "Необязательно: для чего он нужен",
      html.input([
        class("text-input"),
        value(form.description),
        attr("placeholder", "Проверяет тексты на ошибки"),
        event.on_input(model.AgentDescriptionChanged),
      ]),
    ),
    field(
      "Системный промпт",
      "Определяющее свойство агента: на уровне запуска не переопределяется",
      html.textarea(
        [
          class("text-input prompt-input"),
          attr("rows", "5"),
          attr("placeholder", "Ты внимательный редактор. Отвечай кратко."),
          event.on_input(model.AgentPromptChanged),
        ],
        form.system_prompt,
      ),
    ),
    html.div([class("form-row")], [
      field(
        "Провайдер",
        "",
        html.select(
          [
            class("select"),
            value(form.provider_id),
            event.on_change(model.AgentProviderChanged),
          ],
          list.map(state.catalog, fn(status) {
            html.option(
              [value(status.provider.id), disabled(!status.available)],
              case status.available {
                True -> status.provider.title
                False -> status.provider.title <> " (нет ключа)"
              },
            )
          }),
        ),
      ),
      field(
        "Модель",
        "",
        html.select(
          [
            class("select"),
            value(form.model_id),
            event.on_change(model.AgentModelChanged),
          ],
          case groups_of(state, form.provider_id) {
            [single] -> list.map(single.models, model_option)
            many -> list.map(many, model_group)
          },
        ),
      ),
    ]),
    field(
      "Предел шагов",
      "Сколько раз агент может обратиться к модели в одном задании. "
        <> "1 — обычный ответ без инструментов; защита от зацикливания",
      html.input([
        class("num"),
        attr("type", "number"),
        attr("min", "1"),
        attr("max", "50"),
        value(form.max_steps),
        event.on_input(model.AgentMaxStepsChanged),
      ]),
    ),
    tools_field(state, form),
    memory_field(form),
    html.div([class("form-actions")], [
      html.button(
        [
          class("btn btn-send"),
          disabled(!can_submit(state, form)),
          event.on_click(model.AgentFormSubmitted),
        ],
        [
          html.text(case state.agents.saving, editing {
            True, _ -> "Сохранение…"
            False, True -> "Сохранить"
            False, False -> "Создать"
          }),
        ],
      ),
      html.button(
        [class("btn btn-ghost"), event.on_click(model.AgentFormCancelled)],
        [html.text("Отмена")],
      ),
    ]),
  ])
}

/// Настройка памяти.
///
/// Четыре независимых переключателя, а не один режим: «вся история» и
/// «факты» — разные вещи, и запрещать их сочетание незачем.
fn memory_field(form: model.AgentForm) -> Element(Msg) {
  let windowed =
    form.memory_window != "none" && form.memory_window != "everything"

  html.div([class("form-field")], [
    html.label([class("field-label")], [html.text("Память между заданиями")]),
    html.span([class("field-hint muted small")], [
      html.text(
        "Что агент берёт из прошлого, начиная новое задание. Без памяти "
        <> "каждое задание начинается с чистого листа.",
      ),
    ]),
    html.div([class("memory-grid")], [
      window_option(form, "none", "Ничего", "каждое задание независимо"),
      window_option(
        form,
        "outcomes",
        "Задание и итог",
        "дёшево по контексту, обычно достаточно",
      ),
      window_option(
        form,
        "transcripts",
        "Весь обмен",
        "со всеми вызовами инструментов",
      ),
      window_option(
        form,
        "everything",
        "Всю историю",
        "может упереться в предел модели",
      ),
    ]),
    case windowed {
      False -> element.none()
      True ->
        html.div([class("memory-row")], [
          html.span([class("muted small")], [html.text("Последних заданий:")]),
          html.input([
            class("num num-sm"),
            attr("type", "number"),
            attr("min", "1"),
            value(form.memory_tasks),
            event.on_input(model.AgentMemoryTasksChanged),
          ]),
        ])
    },
    html.div([class("memory-row")], [
      checkbox_row(
        form.memory_summary_every != "0",
        model.AgentMemorySummaryChanged(case form.memory_summary_every {
          "0" -> "20"
          _ -> "0"
        }),
        "Сжимать вытесненное",
      ),
      case form.memory_summary_every != "0" {
        False -> element.none()
        True ->
          html.span([class("memory-inline")], [
            html.text("каждые"),
            html.input([
              class("num num-sm"),
              attr("type", "number"),
              attr("min", "1"),
              value(form.memory_summary_every),
              event.on_input(model.AgentMemorySummaryChanged),
            ]),
            html.text("сообщений"),
          ])
      },
    ]),
    html.div([class("memory-row")], [
      checkbox_row(
        form.memory_facts,
        model.AgentMemoryFactsToggled,
        "Подставлять запомненные факты (инструменты remember и forget)",
      ),
    ]),
    html.div([class("memory-row")], [
      html.span([class("muted small")], [html.text("Предел истории:")]),
      html.input([
        class("num"),
        attr("type", "number"),
        attr("min", "0"),
        value(form.memory_budget),
        event.on_input(model.AgentMemoryBudgetChanged),
      ]),
      html.span([class("muted small")], [
        html.text("символов, 0 — четверть контекста модели"),
      ]),
    ]),
  ])
}

fn window_option(
  form: model.AgentForm,
  id: String,
  label: String,
  hint: String,
) -> Element(Msg) {
  html.label([class("memory-option")], [
    html.input([
      attr("type", "radio"),
      attr("name", "memory-window"),
      checked(form.memory_window == id),
      event.on_check(fn(_) { model.AgentMemoryWindowChanged(id) }),
    ]),
    html.span([class("memory-option-name")], [html.text(label)]),
    html.span([class("tool-option-hint")], [html.text(hint)]),
  ])
}

fn checkbox_row(on: Bool, msg: Msg, label: String) -> Element(Msg) {
  html.label([class("memory-check")], [
    html.input([
      attr("type", "checkbox"),
      checked(on),
      event.on_check(fn(_) { msg }),
    ]),
    html.span([], [html.text(label)]),
  ])
}

/// Выбор инструментов.
///
/// Чекбоксы, а не мультиселект: описание инструмента важнее компактности —
/// от него зависит, догадается ли модель вызвать нужный.
fn tools_field(state: Model, form: model.AgentForm) -> Element(Msg) {
  html.div([class("form-field")], [
    html.label([class("field-label")], [html.text("Инструменты")]),
    // Подсказка над списком, а не под ним: после семи строк с описаниями
    // её уже не прочитают, а предупреждение о доступе к файлам и сети
    // должно попасться на глаза до того, как ставят галочку.
    html.span([class("field-hint muted small")], [
      html.text(
        "По умолчанию не выдан ни один. Доступ к файлам и сети "
        <> "дополнительно ограничен переменными окружения на сервере.",
      ),
    ]),
    case state.agents.tools {
      [] -> html.p([class("muted small")], [html.text("каталог не загружен")])
      tools ->
        html.div(
          [class("tool-grid")],
          list.map(tools, fn(tool) { tool_checkbox(form, tool) }),
        )
    },
  ])
}

fn tool_checkbox(form: model.AgentForm, tool: dto.ToolInfo) -> Element(Msg) {
  html.label([class("tool-option")], [
    // Именно `attribute.checked`, а не `attr("checked", …)`: второй
    // задаёт атрибут, который считается присутствующим даже с пустым
    // значением, и все инструменты выглядели бы выбранными.
    html.input([
      attr("type", "checkbox"),
      checked(set.contains(form.tools, tool.id)),
      event.on_check(fn(_) { model.AgentToolToggled(tool.id) }),
    ]),
    html.span([class("tool-option-name")], [html.text(tool.id)]),
    html.span([class("tool-option-hint")], [html.text(tool.description)]),
  ])
}

/// Имя обязательно, модель должна быть выбрана. Остальное проверяет
/// сервер — его сообщения точнее, и дублировать их здесь незачем.
fn can_submit(state: Model, form: model.AgentForm) -> Bool {
  !state.agents.saving && string.trim(form.name) != "" && form.model_id != ""
}

// ─── Мелочи ──────────────────────────────────────────────────────────────────

fn field(label: String, hint: String, control: Element(Msg)) -> Element(Msg) {
  html.div([class("form-field")], [
    html.label([class("field-label")], [html.text(label)]),
    control,
    case hint {
      "" -> element.none()
      _ -> html.span([class("field-hint muted small")], [html.text(hint)])
    },
  ])
}

fn groups_of(state: Model, provider_id: String) -> List(ModelGroup) {
  state.catalog
  |> list.find(fn(entry) { entry.provider.id == provider_id })
  |> result_to_option
  |> option.map(fn(entry) { entry.provider.groups })
  |> option.unwrap([])
}

fn result_to_option(result: Result(a, b)) -> Option(a) {
  case result {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn model_group(group: ModelGroup) -> Element(Msg) {
  html.optgroup(
    [attr("label", group.title)],
    list.map(group.models, model_option),
  )
}

fn model_option(info: ModelInfo) -> Element(Msg) {
  html.option([value(info.id)], info.title)
}

fn icon_button(title: String, glyph: String, msg: Msg) -> Element(Msg) {
  html.button(
    [
      class("icon-btn"),
      attr("title", title),
      attr("aria-label", title),
      event.on_click(msg),
    ],
    [html.text(glyph)],
  )
}
