//// Точка входа SPA.

import client/model.{type Model, type Msg}
import client/ui/agents
import client/ui/composer
import client/ui/dialog
import client/ui/sidebar
import client/update
import gleam/list
import gleam/option.{None, Some}
import lustre
import lustre/attribute.{type Attribute, attribute, class}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub fn main() -> Nil {
  let app = lustre.application(update.init, update.update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn view(state: Model) -> Element(Msg) {
  html.div([class("layout")], [
    sidebar.view(state),
    html.main([class("main")], [
      notifications(state),
      // Экран агентов перекрывает диалог: настройка и переписка нужны
      // не одновременно.
      case state.agents.open {
        True -> agents.view(state)
        False -> element.fragment([dialog.view(state), composer.view(state)])
      },
    ]),
  ])
}

/// Предупреждения нормализации и ошибки верхнего уровня.
fn notifications(state: Model) -> Element(Msg) {
  case state.error, state.warnings {
    None, [] -> element.none()
    _, _ ->
      html.div([class("notifications")], [
        case state.error {
          Some(message) -> banner("error", "⚠", message, model.ErrorDismissed)
          None -> element.none()
        },
        case state.warnings {
          [] -> element.none()
          warnings ->
            html.div([class("banner warning")], [
              html.span([class("banner-icon")], [html.text("ⓘ")]),
              html.div([class("banner-body")], [
                html.div([class("banner-title")], [
                  html.text("Параметры скорректированы под модель"),
                ]),
                html.ul(
                  [class("warning-list")],
                  list.map(warnings, fn(text) { html.li([], [html.text(text)]) }),
                ),
              ]),
              dismiss_button(model.WarningsDismissed),
            ])
        },
      ])
  }
}

fn banner(
  kind: String,
  icon: String,
  message: String,
  on_close: Msg,
) -> Element(Msg) {
  html.div([class("banner " <> kind)], [
    html.span([class("banner-icon")], [html.text(icon)]),
    html.div([class("banner-body")], [html.text(message)]),
    dismiss_button(on_close),
  ])
}

fn dismiss_button(msg: Msg) -> Element(Msg) {
  html.button([class("banner-close"), event.on_click(msg), title("Скрыть")], [
    html.text("×"),
  ])
}

fn title(text: String) -> Attribute(Msg) {
  attribute("title", text)
}
