//// Нижняя панель: ввод сообщения, выбор модели, параметры, редактор JSON.

import client/format
import client/model.{type Model, type Msg}
import client/ui/params
import client/update
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute.{
  type Attribute, attribute as attr, class, disabled, id, value,
}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/types.{type ModelGroup, type ModelInfo, type ProviderStatus}

pub fn view(state: Model) -> Element(Msg) {
  html.section([class("composer")], [
    params.view(state),
    json_editor(state),
    html.div([class("composer-input")], [textarea(state)]),
    html.div([class("composer-bar")], [
      provider_select(state),
      model_select(state),
      params_button(state),
      json_button(state),
      html.span([class("bar-spacer")], []),
      model_info_hint(state),
      send_button(state),
    ]),
  ])
}

// ─── Поле ввода ──────────────────────────────────────────────────────────────

fn textarea(state: Model) -> Element(Msg) {
  html.textarea(
    [
      id(update.composer_id),
      class("draft"),
      attr("rows", "2"),
      attr("placeholder", placeholder(state)),
      disabled(state.sending || state.active == None),
      event.on_input(model.DraftChanged),
      // Enter отправляет, Shift+Enter переносит строку.
      enter_to_send(),
    ],
    state.draft,
  )
}

fn placeholder(state: Model) -> String {
  case state.active {
    None -> "Создайте сессию, чтобы начать"
    Some(_) ->
      case model.provider_available(state) {
        False -> "Провайдер недоступен: на сервере не задан ключ"
        True ->
          case model.is_agent_session(state) {
            True -> "Опишите задание…   (Enter — выдать, Shift+Enter — перенос)"
            False ->
              "Введите сообщение…   (Enter — отправить, Shift+Enter — перенос)"
          }
      }
  }
}

/// Enter отправляет, Shift+Enter переносит строку.
///
/// Используем `event.advanced`, чтобы отменять поведение по умолчанию
/// только для Enter: безусловный `prevent_default` сломал бы ввод текста.
fn enter_to_send() -> Attribute(Msg) {
  let handler = {
    use key <- decode.field("key", decode.string)
    use shift <- decode.field("shiftKey", decode.bool)
    case key, shift {
      "Enter", False ->
        decode.success(event.handler(
          dispatch: model.SendClicked,
          prevent_default: True,
          stop_propagation: False,
        ))
      // Прочие клавиши пропускаем дальше — их обработает on_input.
      _, _ ->
        decode.failure(
          event.handler(
            dispatch: model.SendClicked,
            prevent_default: False,
            stop_propagation: False,
          ),
          "Enter",
        )
    }
  }

  event.advanced("keydown", handler)
}

// ─── Выбор провайдера и модели ───────────────────────────────────────────────

fn provider_select(state: Model) -> Element(Msg) {
  html.select(
    [
      class("select provider-select"),
      disabled(state.sending),
      event.on_change(model.ProviderChanged),
      attr("title", "Провайдер"),
      // Выбор задаём на самом select: атрибут `selected` у option
      // синхронизируется с фактическим выбором не во всех реализациях DOM.
      value(state.provider_id),
    ],
    list.map(state.catalog, provider_option),
  )
}

fn provider_option(status: ProviderStatus) -> Element(Msg) {
  html.option(
    [
      value(status.provider.id),
      // Провайдер без ключа выбрать нельзя — сразу видно, что он не настроен.
      disabled(!status.available),
    ],
    case status.available {
      True -> status.provider.title
      False -> status.provider.title <> " (нет ключа)"
    },
  )
}

fn model_select(state: Model) -> Element(Msg) {
  let groups =
    model.current_provider(state)
    |> option.map(fn(status) { status.provider.groups })
    |> option.unwrap([])

  html.select(
    [
      class("select model-select"),
      disabled(state.sending),
      event.on_change(model.ModelChanged),
      attr("title", "Модель"),
      value(state.model_id),
    ],
    case groups {
      // Единственная группа — заголовок не нужен.
      [single] -> list.map(single.models, model_option)
      many -> list.map(many, model_group)
    },
  )
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

/// Подсказка о возможностях выбранной модели.
fn model_info_hint(state: Model) -> Element(Msg) {
  case model.current_model(state) {
    None -> element.none()
    Some(info) ->
      html.span([class("model-hint muted small")], [
        html.text(
          [
            case format.context_size(info.context_length) {
              "" -> None
              size -> Some(size <> " ctx")
            },
            case info.vision {
              True -> Some("vision")
              False -> None
            },
            case types.supports_reasoning(info) {
              True -> Some("reasoning")
              False -> None
            },
          ]
          |> list.filter_map(option.to_result(_, Nil))
          |> string.join(" · "),
        ),
      ])
  }
}

// ─── Кнопки ──────────────────────────────────────────────────────────────────

fn params_button(state: Model) -> Element(Msg) {
  let count = types.active_option_count(state.params)

  html.button(
    [
      class(case state.params_open {
        True -> "btn btn-ghost active"
        False -> "btn btn-ghost"
      }),
      event.on_click(model.ParamsToggled),
      attr("title", "Параметры запроса"),
    ],
    [
      html.text("⚙"),
      // Счётчик показывает, что запрос не «чистый», не раскрывая панель.
      case count {
        0 -> element.none()
        _ -> html.span([class("badge")], [html.text(int.to_string(count))])
      },
    ],
  )
}

fn json_button(state: Model) -> Element(Msg) {
  html.button(
    [
      class(case state.json_editor {
        Some(_) -> "btn btn-ghost active"
        None -> "btn btn-ghost"
      }),
      event.on_click(model.JsonEditorToggled),
      disabled(state.active == None),
      attr("title", "Редактировать отправляемый JSON"),
    ],
    [html.text("{} Править JSON")],
  )
}

fn send_button(state: Model) -> Element(Msg) {
  let blocked = model.send_blocked_reason(state)

  html.button(
    [
      class("btn btn-send"),
      event.on_click(model.SendClicked),
      disabled(!model.can_send(state)),
      case blocked {
        Some(reason) -> attr("title", reason)
        None ->
          case model.is_agent_session(state) {
            True -> attr("title", "Выдать задание (Enter)")
            False -> attr("title", "Отправить (Enter)")
          }
      },
    ],
    [
      html.text(case state.sending, model.is_agent_session(state) {
        True, True -> "Работает…"
        True, False -> "Отправка…"
        False, True -> "Выдать задание"
        False, False -> "Отправить"
      }),
    ],
  )
}

// ─── Редактор JSON ───────────────────────────────────────────────────────────

fn json_editor(state: Model) -> Element(Msg) {
  case state.json_editor {
    None -> element.none()
    Some(editor) ->
      html.section([class("json-editor")], [
        html.header([class("json-editor-head")], [
          html.span([class("params-title")], [html.text("Тело запроса")]),
          case model.json_hand_edited(state) {
            True ->
              html.span([class("chip warn")], [html.text("изменено вручную")])
            False -> element.none()
          },
          html.span([class("bar-spacer")], []),
          html.button(
            [class("link-btn"), event.on_click(model.JsonEditorReset)],
            [html.text("Сбросить")],
          ),
        ]),
        case editor.loading {
          True ->
            html.div([class("json-loading muted")], [html.text("Сборка тела…")])
          False ->
            html.textarea(
              [
                class(case editor.parse_error {
                  Some(_) -> "json-input invalid"
                  None -> "json-input"
                }),
                attr("spellcheck", "false"),
                attr("rows", "12"),
                event.on_input(model.JsonEditorChanged),
              ],
              editor.text,
            )
        },
        case editor.parse_error {
          Some(message) ->
            html.div([class("json-error")], [
              html.span([class("error-icon")], [html.text("⚠")]),
              html.text(message),
            ])
          None -> element.none()
        },
        html.p([class("muted small")], [
          html.text(
            "Тело уйдёт провайдеру как есть. Параметры из ⚙ при ручной правке "
            <> "не применяются.",
          ),
        ]),
      ])
  }
}
