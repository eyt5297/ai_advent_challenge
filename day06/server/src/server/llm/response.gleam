//// ★ ТОЧКА РАСШИРЕНИЯ №2 — разбор ответа провайдера.
////
//// Сигнатура `parse_response_body` заморожена. Разбор намеренно
//// снисходителен: сырое тело всегда сохраняется в БД и видно в UI, поэтому
//// лучше вернуть частичный результат, чем ошибку.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import shared/types.{type Provider, type ToolCall, type Usage, ToolCall, Usage}

pub type ParsedResponse {
  ParsedResponse(
    /// Текст для показа в диалоге.
    content: String,
    /// Рассуждения, если провайдер вернул их отдельным полем.
    reasoning: Option(String),
    finish_reason: Option(String),
    usage: Option(Usage),
    /// Запросы на вызов инструментов. Пусто — модель ответила текстом.
    ///
    /// Это и есть честный признак завершения работы агента: пока список
    /// непуст, задание не закончено.
    tool_calls: List(ToolCall),
  )
}

pub type ParseError {
  /// Тело не является JSON.
  InvalidJson(String)
  /// Провайдер вернул ошибку (как по HTTP-статусу, так и в теле с 200).
  ProviderError(code: String, message: String)
  /// JSON разобран, но нужных полей нет.
  UnexpectedShape(String)
}

/// Разбирает сырое тело ответа.
///
/// Оба провайдера OpenAI-совместимы, поэтому ветвления по `provider` пока
/// нет — параметр оставлен в сигнатуре, чтобы его добавление не ломало
/// вызывающий код.
pub fn parse_response_body(
  provider: Provider,
  http_status: Int,
  body: String,
) -> Result(ParsedResponse, ParseError) {
  let _ = provider

  case is_success(http_status) {
    False -> Error(parse_error_body(http_status, body))
    True ->
      case json.parse(body, success_decoder()) {
        Ok(parsed) -> validate(parsed)
        Error(_) ->
          // 200, но тело не разбирается как успешный ответ: возможно,
          // провайдер положил ошибку в тело с кодом 200.
          case json.parse(body, error_decoder()) {
            Ok(#(code, message)) -> Error(ProviderError(code, message))
            Error(_) -> Error(classify_unparsable(body))
          }
      }
  }
}

fn is_success(status: Int) -> Bool {
  status >= 200 && status < 300
}

/// Пустой `content` при отсутствии рассуждений — почти наверняка проблема,
/// и показывать пустой пузырь бессмысленно.
fn validate(parsed: ParsedResponse) -> Result(ParsedResponse, ParseError) {
  // При вызове инструмента пустой content — норма: вся полезная нагрузка
  // лежит в tool_calls.
  case parsed.content, parsed.reasoning, parsed.tool_calls {
    "", None, [] ->
      Error(UnexpectedShape(
        "ответ разобран, но choices[0].message.content пуст",
      ))
    _, _, _ -> Ok(parsed)
  }
}

fn classify_unparsable(body: String) -> ParseError {
  case string.trim(body) {
    "" -> UnexpectedShape("провайдер вернул пустое тело")
    trimmed ->
      case
        string.starts_with(trimmed, "{") || string.starts_with(trimmed, "[")
      {
        // Похоже на JSON, но полей нет — значит форма другая.
        True ->
          UnexpectedShape(
            "в ответе нет choices[0].message.content: " <> preview(trimmed),
          )
        False -> InvalidJson(preview(trimmed))
      }
  }
}

fn preview(body: String) -> String {
  case string.length(body) > 300 {
    True -> string.slice(body, at_index: 0, length: 300) <> "…"
    False -> body
  }
}

// ─── Успешный ответ ──────────────────────────────────────────────────────────

fn success_decoder() -> Decoder(ParsedResponse) {
  use choices <- decode.field("choices", decode.list(choice_decoder()))
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder()),
  )

  case list.first(choices) {
    Ok(#(content, reasoning, tool_calls, finish_reason)) ->
      decode.success(ParsedResponse(
        content:,
        reasoning:,
        finish_reason:,
        usage:,
        tool_calls:,
      ))
    Error(Nil) ->
      decode.failure(
        ParsedResponse("", None, None, None, []),
        "непустой массив choices",
      )
  }
}

/// Возвращает кортеж, а не запись, чтобы не плодить типы ради одного места.
fn choice_decoder() -> Decoder(
  #(String, Option(String), List(ToolCall), Option(String)),
) {
  use message <- decode.field("message", message_decoder())
  use finish_reason <- decode.optional_field(
    "finish_reason",
    None,
    decode.optional(decode.string),
  )
  let #(content, reasoning, tool_calls) = message
  decode.success(#(content, reasoning, tool_calls, finish_reason))
}

fn message_decoder() -> Decoder(#(String, Option(String), List(ToolCall))) {
  // content может быть null (например, когда модель только рассуждала)
  // либо массивом частей — поддерживаем обе формы.
  use content <- decode.optional_field("content", "", content_decoder())
  use reasoning <- decode.optional_field(
    "reasoning_content",
    None,
    decode.optional(decode.string),
  )
  // Часть провайдеров зовёт это поле просто `reasoning`.
  use reasoning_alt <- decode.optional_field(
    "reasoning",
    None,
    decode.optional(decode.string),
  )
  use tool_calls <- decode.optional_field(
    "tool_calls",
    [],
    decode.list(tool_call_decoder()),
  )
  decode.success(#(content, option.or(reasoning, reasoning_alt), tool_calls))
}

/// Вызов инструмента в формате OpenAI: `{id, type, function: {name, arguments}}`.
///
/// `arguments` не разбираем: модель иногда присылает невалидный JSON, и это
/// должно стать ошибкой конкретного инструмента, а не всего ответа.
fn tool_call_decoder() -> Decoder(ToolCall) {
  use id <- decode.optional_field("id", "", decode.string)
  use function <- decode.optional_field(
    "function",
    #("", ""),
    tool_function_decoder(),
  )
  let #(name, arguments) = function
  decode.success(ToolCall(id:, name:, arguments:))
}

fn tool_function_decoder() -> Decoder(#(String, String)) {
  use name <- decode.optional_field("name", "", decode.string)
  use arguments <- decode.optional_field("arguments", "", decode.string)
  decode.success(#(name, arguments))
}

/// `content` приходит строкой, null или массивом частей `{type, text}`.
fn content_decoder() -> Decoder(String) {
  decode.one_of(decode.string, [
    decode.map(decode.optional(decode.string), option.unwrap(_, "")),
    decode.map(decode.list(content_part_decoder()), string.join(_, "")),
  ])
}

fn content_part_decoder() -> Decoder(String) {
  decode.one_of(decode.string, [
    {
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(text)
    },
  ])
}

fn usage_decoder() -> Decoder(Usage) {
  use prompt_tokens <- decode.optional_field("prompt_tokens", 0, decode.int)
  use completion_tokens <- decode.optional_field(
    "completion_tokens",
    0,
    decode.int,
  )
  use total_tokens <- decode.optional_field("total_tokens", 0, decode.int)
  decode.success(Usage(prompt_tokens:, completion_tokens:, total_tokens:))
}

// ─── Ошибочный ответ ─────────────────────────────────────────────────────────

/// Разбирает тело при не-2xx. Если структура незнакома — отдаём сырой
/// фрагмент, чтобы в UI было что показать.
fn parse_error_body(http_status: Int, body: String) -> ParseError {
  case json.parse(body, error_decoder()) {
    Ok(#(code, message)) -> ProviderError(code, message)
    Error(_) -> {
      let detail = case string.trim(body) {
        "" -> "пустое тело"
        text -> preview(text)
      }
      ProviderError("http_" <> int.to_string(http_status), detail)
    }
  }
}

/// Форматы ошибок: `{error: {message, code|type}}`, `{error: "текст"}`,
/// `{message: "текст"}`.
fn error_decoder() -> Decoder(#(String, String)) {
  decode.one_of(nested_error_decoder(), [
    string_error_decoder(),
    flat_error_decoder(),
  ])
}

fn nested_error_decoder() -> Decoder(#(String, String)) {
  use error <- decode.field("error", {
    use message <- decode.field("message", decode.string)
    use code <- decode.optional_field("code", "", lenient_string())
    use error_type <- decode.optional_field("type", "", lenient_string())
    let resolved = case code, error_type {
      "", "" -> "provider_error"
      "", kind -> kind
      value, _ -> value
    }
    decode.success(#(resolved, message))
  })
  decode.success(error)
}

fn string_error_decoder() -> Decoder(#(String, String)) {
  use message <- decode.field("error", decode.string)
  decode.success(#("provider_error", message))
}

fn flat_error_decoder() -> Decoder(#(String, String)) {
  use message <- decode.field("message", decode.string)
  decode.success(#("provider_error", message))
}

/// Код ошибки приходит то строкой, то числом.
fn lenient_string() -> Decoder(String) {
  decode.one_of(decode.string, [decode.map(decode.int, int.to_string)])
}

// ─── Описание ошибок для UI ──────────────────────────────────────────────────

pub fn describe(error: ParseError) -> String {
  case error {
    InvalidJson(detail) -> "ответ не является JSON: " <> detail
    ProviderError(code, message) ->
      "провайдер вернул ошибку [" <> code <> "]: " <> message
    UnexpectedShape(detail) -> "неожиданная структура ответа: " <> detail
  }
}

/// Короткий код для поля `messages.error` — удобно фильтровать в БД.
pub fn error_code(error: ParseError) -> String {
  case error {
    InvalidJson(_) -> "invalid_json"
    ProviderError(code, _) -> code
    UnexpectedShape(_) -> "unexpected_shape"
  }
}
