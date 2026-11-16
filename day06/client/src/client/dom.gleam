//// Побочные эффекты в DOM, обёрнутые в Lustre Effect.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}
import lustre/effect.{type Effect}

@external(javascript, "../client_ffi.mjs", "scrollDialogToBottom")
fn do_scroll_to_bottom() -> Nil

@external(javascript, "../client_ffi.mjs", "autoResize")
fn do_auto_resize(element_id: String) -> Nil

@external(javascript, "../client_ffi.mjs", "focusElement")
fn do_focus(element_id: String) -> Nil

@external(javascript, "../client_ffi.mjs", "copyToClipboard")
fn do_copy(text: String) -> Bool

/// Проверка JSON средствами движка: мгновенно и без похода на сервер.
/// Пустая строка означает «ошибок нет».
@external(javascript, "../client_ffi.mjs", "validateJson")
fn do_validate_json(text: String) -> String

/// Описание ошибки разбора или None, если JSON корректен.
pub fn validate_json(text: String) -> Option(String) {
  case do_validate_json(text) {
    "" -> None
    message -> Some(message)
  }
}

pub fn scroll_dialog_to_bottom() -> Effect(msg) {
  effect.from(fn(_dispatch) { do_scroll_to_bottom() })
}

pub fn auto_resize(element_id: String) -> Effect(msg) {
  effect.from(fn(_dispatch) { do_auto_resize(element_id) })
}

pub fn focus(element_id: String) -> Effect(msg) {
  effect.from(fn(_dispatch) { do_focus(element_id) })
}

pub fn copy(text: String) -> Effect(msg) {
  effect.from(fn(_dispatch) {
    let _ = do_copy(text)
    Nil
  })
}

// ─── Поток событий сессии ────────────────────────────────────────────────────

@external(javascript, "../client_ffi.mjs", "openEventStream")
fn do_open_stream(
  session_id: String,
  on_event: fn(String, Dynamic) -> Nil,
) -> Bool

@external(javascript, "../client_ffi.mjs", "closeEventStream")
fn do_close_stream() -> Nil

/// Подписывается на события сессии.
///
/// Поток **дополняет** загрузку, а не заменяет её: при открытии сессии
/// данные по-прежнему приходят запросом, SSE даёт только изменения.
/// Поэтому неудача подписки ничего не ломает — интерфейс просто работает
/// как раньше.
pub fn open_event_stream(
  session_id: String,
  on_event: fn(String, Dynamic) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    let _ =
      do_open_stream(session_id, fn(name, payload) {
        dispatch(on_event(name, payload))
      })
    Nil
  })
}

pub fn close_event_stream() -> Effect(msg) {
  effect.from(fn(_dispatch) { do_close_stream() })
}
