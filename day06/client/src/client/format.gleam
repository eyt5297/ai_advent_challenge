//// Форматирование значений для отображения.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import shared/types.{type RequestOptions, type Usage}

/// Время в формате ЧЧ:ММ по локальной зоне браузера.
@external(javascript, "../client_ffi.mjs", "formatTime")
pub fn time(timestamp_ms: Int) -> String

/// Дата и время — для подписи в списке сессий.
@external(javascript, "../client_ffi.mjs", "formatDateTime")
pub fn date_time(timestamp_ms: Int) -> String

/// Относительное время: «5 мин назад».
@external(javascript, "../client_ffi.mjs", "formatRelative")
pub fn relative(timestamp_ms: Int) -> String

/// Длительность запроса.
pub fn duration(ms: Int) -> String {
  case ms < 1000 {
    True -> int.to_string(ms) <> " мс"
    False -> {
      let seconds = int.to_float(ms) /. 1000.0
      float_round(seconds, 1) <> " с"
    }
  }
}

fn float_round(value: Float, places: Int) -> String {
  let factor = case places {
    1 -> 10.0
    2 -> 100.0
    _ -> 1.0
  }
  let rounded = int.to_float(float.round(value *. factor)) /. factor
  trim_float(rounded)
}

/// Крупные числа с разделителем: 1 048 576.
pub fn thousands(value: Int) -> String {
  value
  |> int.to_string
  |> string.to_graphemes
  |> list.reverse
  |> list.index_map(fn(digit, index) {
    case index > 0 && index % 3 == 0 {
      True -> digit <> " "
      False -> digit
    }
  })
  |> list.reverse
  |> string.join("")
}

/// Размер контекста компактно: «1M», «256K».
pub fn context_size(tokens: Int) -> String {
  case tokens {
    0 -> ""
    _ if tokens >= 1_000_000 -> int.to_string(tokens / 1_000_000) <> "M"
    _ if tokens >= 1000 -> int.to_string(tokens / 1024) <> "K"
    _ -> int.to_string(tokens)
  }
}

/// Компактная строка параметров для шапки сообщения:
/// `t=0.7 · 4096 · effort=medium`.
pub fn params_summary(params: Option(RequestOptions)) -> String {
  case params {
    None -> ""
    Some(options) ->
      [
        option.map(options.temperature, fn(value) { "t=" <> trim_float(value) }),
        option.map(options.max_tokens, int.to_string),
        option.map(options.reasoning_effort, fn(value) { "effort=" <> value }),
        case options.system_prompt {
          Some(_) -> Some("system")
          None -> None
        },
      ]
      |> list.filter_map(option.to_result(_, Nil))
      |> string.join(" · ")
  }
}

/// Float без лишнего нуля: 0.7 вместо 0.70.
pub fn trim_float(value: Float) -> String {
  let text = float.to_string(value)
  case string.ends_with(text, ".0") {
    True -> string.drop_end(text, 2)
    False -> text
  }
}

pub fn usage_summary(usage: Option(Usage)) -> String {
  case usage {
    None -> ""
    Some(value) ->
      int.to_string(value.prompt_tokens)
      <> " + "
      <> int.to_string(value.completion_tokens)
      <> " = "
      <> int.to_string(value.total_tokens)
      <> " токенов"
  }
}
