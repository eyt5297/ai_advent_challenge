//// Панель параметров запроса.
////
//// Главный принцип: у каждого параметра есть чекбокс «использовать».
//// Снятый чекбокс означает `None` — ключ не уходит в запрос вовсе, решает
//// провайдер. Это прямое отображение `Option(..)` в UI и единственный
//// способ отличить «temperature = 0» от «температуру не трогали».

import client/format
import client/model.{type Model, type Msg}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute.{
  attribute as attr, checked, class, disabled, type_, value,
}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/types.{type ModelInfo}

pub fn view(state: Model) -> Element(Msg) {
  case state.params_open {
    False -> element.none()
    True ->
      html.section([class("params-panel")], [
        head(state),
        case model.json_hand_edited(state) {
          True -> locked_notice()
          False -> controls(state)
        },
      ])
  }
}

fn head(state: Model) -> Element(Msg) {
  html.header([class("params-head")], [
    html.span([class("params-title")], [html.text("Параметры запроса")]),
    html.button(
      [
        class("link-btn"),
        event.on_click(model.ParamsReset),
        disabled(types.active_option_count(state.params) == 0),
      ],
      [html.text("Сбросить всё")],
    ),
  ])
}

/// Если JSON правили руками, параметры к нему не применяются —
/// честнее сказать об этом прямо, чем молча игнорировать.
fn locked_notice() -> Element(Msg) {
  html.div([class("params-locked")], [
    html.p([], [
      html.text("JSON отредактирован вручную — параметры не применяются."),
    ]),
    html.button([class("link-btn"), event.on_click(model.JsonEditorReset)], [
      html.text("Вернуться к параметрам"),
    ]),
  ])
}

fn controls(state: Model) -> Element(Msg) {
  let current = model.current_model(state)

  html.div([class("params-grid")], [
    temperature_row(state),
    max_tokens_row(state, current),
    reasoning_rows(state, current),
    system_prompt_row(state),
  ])
}

// ─── temperature ─────────────────────────────────────────────────────────────

fn temperature_row(state: Model) -> Element(Msg) {
  let enabled = option.is_some(state.params.temperature)
  let current = option.unwrap(state.params.temperature, 0.7)

  param_row(
    "temperature",
    enabled,
    model.TemperatureToggled,
    [
      html.input([
        class("slider"),
        type_("range"),
        attr("min", "0"),
        attr("max", "2"),
        attr("step", "0.05"),
        value(format.trim_float(current)),
        disabled(!enabled),
        event.on_input(model.TemperatureChanged),
      ]),
      html.input([
        class("num num-sm"),
        type_("number"),
        attr("min", "0"),
        attr("max", "2"),
        attr("step", "0.05"),
        value(format.trim_float(current)),
        disabled(!enabled),
        event.on_input(model.TemperatureChanged),
      ]),
    ],
    hint: "0 — предсказуемо, 2 — творчески",
  )
}

// ─── max_tokens ──────────────────────────────────────────────────────────────

fn max_tokens_row(state: Model, current: Option(ModelInfo)) -> Element(Msg) {
  let enabled = option.is_some(state.params.max_tokens)
  let limit =
    current
    |> option.map(fn(info) { info.max_output_tokens })
    |> option.unwrap(0)
  let shown = option.unwrap(state.params.max_tokens, 4096)

  param_row(
    "max_tokens",
    enabled,
    model.MaxTokensToggled,
    [
      html.input([
        class("num"),
        type_("number"),
        attr("min", "1"),
        case limit {
          0 -> attr("data-no-max", "")
          _ -> attr("max", int.to_string(limit))
        },
        attr("step", "256"),
        value(int.to_string(shown)),
        disabled(!enabled),
        event.on_input(model.MaxTokensChanged),
      ]),
      html.span([class("limit-hint")], [
        html.text(case limit {
          // kimi лимит вывода не сообщает — честно пишем «не указан».
          0 -> "лимит не указан"
          _ -> "/ " <> format.thousands(limit)
        }),
      ]),
    ],
    hint: "максимум токенов в ответе",
  )
}

// ─── reasoning ───────────────────────────────────────────────────────────────

/// Блок рассуждений перестраивается под выбранную модель: у моделей без
/// рассуждений он скрыт целиком, у kimi тумблер «вкл/выкл» неактивен,
/// а шкала усилий берётся из каталога.
fn reasoning_rows(state: Model, current: Option(ModelInfo)) -> Element(Msg) {
  case current {
    None -> element.none()
    Some(info) ->
      case types.supports_reasoning(info) {
        False -> unsupported_notice()
        True -> {
          let enabled =
            option.is_some(state.params.reasoning_enabled)
            || option.is_some(state.params.reasoning_effort)

          html.div([class("param-group")], [
            param_row(
              "reasoning",
              enabled,
              model.ReasoningToggled,
              [toggle_control(state, info, enabled)],
              hint: reasoning_hint(info),
            ),
            case enabled {
              True -> effort_row(state, info)
              False -> element.none()
            },
          ])
        }
      }
  }
}

fn unsupported_notice() -> Element(Msg) {
  html.div([class("param-row disabled-row")], [
    html.span([class("param-name")], [html.text("reasoning")]),
    html.span([class("muted small")], [
      html.text("модель не поддерживает рассуждения"),
    ]),
  ])
}

fn reasoning_hint(info: ModelInfo) -> String {
  case types.can_disable_reasoning(info) {
    True -> "можно включать и выключать"
    False -> "модель рассуждает всегда"
  }
}

fn toggle_control(
  state: Model,
  info: ModelInfo,
  enabled: Bool,
) -> Element(Msg) {
  case types.can_disable_reasoning(info) {
    // kimi: выключить нельзя, показываем это явно.
    False ->
      html.span([class("pill pill-static")], [html.text("всегда включены")])

    True -> {
      let on = option.unwrap(state.params.reasoning_enabled, True)
      html.div([class("radio-pair")], [
        radio(
          "reasoning-on",
          "вкл",
          on,
          enabled,
          model.ReasoningEnabledChanged(True),
        ),
        radio(
          "reasoning-off",
          "выкл",
          !on,
          enabled,
          model.ReasoningEnabledChanged(False),
        ),
      ])
    }
  }
}

fn radio(
  key: String,
  label: String,
  selected: Bool,
  enabled: Bool,
  msg: Msg,
) -> Element(Msg) {
  html.label(
    [
      class(case selected {
        True -> "radio selected"
        False -> "radio"
      }),
    ],
    [
      html.input([
        type_("radio"),
        attr("name", "reasoning-enabled"),
        attr("value", key),
        checked(selected),
        disabled(!enabled),
        event.on_check(fn(_) { msg }),
      ]),
      html.span([], [html.text(label)]),
    ],
  )
}

/// Шкала усилий строго из каталога модели: у veai пять значений,
/// у kimi три. Хардкодить их нельзя.
fn effort_row(state: Model, info: ModelInfo) -> Element(Msg) {
  let efforts = types.reasoning_efforts(info)
  let selected =
    state.params.reasoning_effort
    |> option.lazy_or(fn() { types.default_effort(info) })

  case efforts {
    [] -> element.none()
    _ ->
      html.div([class("param-row sub-row")], [
        html.span([class("param-name sub")], [html.text("└ effort")]),
        html.div(
          [class("segmented")],
          list.map(efforts, effort_button(_, selected)),
        ),
      ])
  }
}

fn effort_button(effort: String, selected: Option(String)) -> Element(Msg) {
  html.button(
    [
      class(case selected == Some(effort) {
        True -> "segment selected"
        False -> "segment"
      }),
      event.on_click(model.EffortChanged(effort)),
    ],
    [html.text(effort)],
  )
}

// ─── system prompt ───────────────────────────────────────────────────────────

fn system_prompt_row(state: Model) -> Element(Msg) {
  let enabled = option.is_some(state.params.system_prompt)
  let text = option.unwrap(state.params.system_prompt, "")

  html.div([class("param-group")], [
    param_row(
      "system",
      enabled,
      model.SystemPromptToggled,
      [],
      hint: "инструкция перед вопросом",
    ),
    case enabled {
      True ->
        html.div([class("param-row sub-row")], [
          html.textarea(
            [
              class("system-input"),
              attr("rows", "3"),
              attr("placeholder", "Например: отвечай кратко, по-русски"),
              event.on_input(model.SystemPromptChanged),
            ],
            text,
          ),
        ])
      False -> element.none()
    },
  ])
}

// ─── Общая строка параметра ──────────────────────────────────────────────────

fn param_row(
  name: String,
  enabled: Bool,
  on_toggle: fn(Bool) -> Msg,
  controls: List(Element(Msg)),
  hint hint: String,
) -> Element(Msg) {
  html.div(
    [
      class(case enabled {
        True -> "param-row"
        False -> "param-row off"
      }),
    ],
    [
      html.label([class("param-check")], [
        html.input([
          type_("checkbox"),
          checked(enabled),
          event.on_check(on_toggle),
        ]),
        html.span([class("param-name")], [html.text(name)]),
      ]),
      html.div([class("param-controls")], controls),
      html.span([class("param-hint")], [html.text(hint)]),
    ],
  )
}
