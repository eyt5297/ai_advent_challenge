//// Общее для HTTP-слоя: контекст, middleware, формирование ответов.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/string
import server/config.{type Config}
import shared/codec
import sqlight.{type Connection}
import wisp.{type Request, type Response}

/// Всё, что нужно обработчикам. Передаётся явно, без глобального состояния.
pub type Context {
  Context(config: Config, db: Connection)
}

/// Базовые middleware для всех запросов.
pub fn middleware(
  request: Request,
  context: Context,
  handler: fn(Request) -> Response,
) -> Response {
  let request = wisp.method_override(request)
  use <- wisp.log_request(request)
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use <- wisp.serve_static(
    request,
    under: "/static",
    from: context.config.static_dir,
  )
  handler(request)
}

// ─── Ответы ──────────────────────────────────────────────────────────────────

pub fn json_ok(body: Json) -> Response {
  body |> json.to_string |> wisp.json_response(200)
}

pub fn json_created(body: Json) -> Response {
  body |> json.to_string |> wisp.json_response(201)
}

/// Ответ с произвольным статусом — например, 202 для принятого задания.
pub fn json_response(status: Int, body: Json) -> Response {
  body |> json.to_string |> wisp.json_response(status)
}

pub fn no_content() -> Response {
  wisp.response(204)
}

/// Ошибка в едином формате `{ "error": { code, message } }`.
pub fn error(status: Int, code: String, message: String) -> Response {
  codec.error_to_json(code, message)
  |> json.to_string
  |> wisp.json_response(status)
}

pub fn bad_request(code: String, message: String) -> Response {
  error(400, code, message)
}

pub fn not_found(message: String) -> Response {
  error(404, "not_found", message)
}

pub fn server_error(message: String) -> Response {
  error(500, "internal_error", message)
}

// ─── Разбор тела ─────────────────────────────────────────────────────────────

/// Читает JSON-тело и декодирует его, отвечая 400 при несоответствии.
///
/// Сообщение об ошибке включает путь до проблемного поля — иначе отладка
/// клиента превращается в угадайку.
pub fn require_decoded(
  request: Request,
  decoder: Decoder(a),
  next: fn(a) -> Response,
) -> Response {
  use body <- wisp.require_json(request)
  case decode.run(body, decoder) {
    Ok(value) -> next(value)
    Error(errors) -> bad_request("invalid_body", describe_errors(body, errors))
  }
}

fn describe_errors(_body: Dynamic, errors: List(decode.DecodeError)) -> String {
  case errors {
    [] -> "тело запроса не соответствует ожидаемому формату"
    [first, ..] -> {
      let path = case first.path {
        [] -> "корень"
        segments -> string.join(segments, ".")
      }
      "поле "
      <> path
      <> ": ожидалось "
      <> first.expected
      <> ", получено "
      <> first.found
    }
  }
}
