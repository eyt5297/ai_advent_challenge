//// Левая панель: список сессий и создание новой.

import client/format
import client/model.{type Model, type Msg}
import client/update
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre/attribute.{attribute as attr, class, id, value}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/types.{type SessionSummary}

pub fn view(state: Model) -> Element(Msg) {
  html.aside([class("sidebar")], [
    html.div([class("sidebar-head")], [
      html.button(
        [class("btn btn-new"), event.on_click(model.NewSessionClicked)],
        [
          html.span([class("btn-icon")], [html.text("+")]),
          html.text("Новый чат"),
        ],
      ),
      // Вход на экран агентов. Отдельной кнопкой, а не пунктом в списке
      // сессий: агент — это настройка, а не переписка.
      html.button(
        [
          class("btn btn-agents"),
          event.on_click(model.AgentsOpened),
          attr("title", "Агенты: настроить и запустить"),
        ],
        [html.span([class("btn-icon")], [html.text("⌬")]), html.text("Агенты")],
      ),
    ]),
    html.nav([class("session-list")], case state.sessions {
      [] -> [empty_hint()]
      sessions -> list.map(sessions, session_item(state, _))
    }),
    html.div([class("sidebar-foot")], [
      html.span([class("muted small")], [
        html.text(session_count_label(list.length(state.sessions))),
      ]),
    ]),
  ])
}

fn empty_hint() -> Element(Msg) {
  html.p([class("empty-hint")], [
    html.text("Пока нет ни одной сессии. Нажмите «Новый чат», чтобы начать."),
  ])
}

fn session_count_label(count: Int) -> String {
  let word = case count % 100, count % 10 {
    n, _ if n >= 11 && n <= 14 -> "сессий"
    _, 1 -> "сессия"
    _, n if n >= 2 && n <= 4 -> "сессии"
    _, _ -> "сессий"
  }
  int.to_string(count) <> " " <> word
}

fn session_item(state: Model, session: SessionSummary) -> Element(Msg) {
  let active = state.active == Some(session.id)

  // Во время переименования строка превращается в поле ввода.
  let renaming = case state.renaming {
    Some(rename) if rename.session_id == session.id -> Some(rename.title)
    _ -> None
  }

  case renaming {
    Some(title) -> rename_row(title)
    None -> row(session, active)
  }
}

fn rename_row(title: String) -> Element(Msg) {
  html.div([class("session-item renaming")], [
    html.input([
      id(update.rename_id),
      class("rename-input"),
      value(title),
      event.on_input(model.RenameChanged),
      // Enter подтверждает, Escape отменяет.
      event.on_keydown(fn(key) {
        case key {
          "Enter" -> model.RenameSubmitted
          "Escape" -> model.RenameCancelled
          _ -> model.RenameChanged(title)
        }
      }),
      event.on_blur(model.RenameSubmitted),
    ]),
  ])
}

fn row(session: SessionSummary, active: Bool) -> Element(Msg) {
  html.div(
    [
      class(case active {
        True -> "session-item active"
        False -> "session-item"
      }),
    ],
    [
      html.button(
        [
          class("session-main"),
          event.on_click(model.SessionSelected(session.id)),
          attr("title", session.title),
        ],
        [
          html.span([class("session-title")], [html.text(session.title)]),
          html.span([class("session-meta")], [
            html.text(format.relative(session.updated_at)),
            case session.message_count {
              0 -> element.none()
              count ->
                html.span([class("dot-sep")], [
                  html.text(" · " <> int.to_string(count)),
                ])
            },
          ]),
        ],
      ),
      html.div([class("session-actions")], [
        icon_button(
          "Переименовать",
          "✎",
          model.RenameStarted(session.id, session.title),
        ),
        icon_button("Удалить", "×", model.SessionDeleteClicked(session.id)),
      ]),
    ],
  )
}

fn icon_button(title: String, glyph: String, msg: Msg) -> Element(Msg) {
  html.button(
    [
      class("icon-btn"),
      attr("title", title),
      attr("aria-label", title),
      // stop_propagation, иначе клик по иконке ещё и выберет сессию.
      event.on_click(msg) |> event.stop_propagation,
    ],
    [html.text(glyph)],
  )
}
