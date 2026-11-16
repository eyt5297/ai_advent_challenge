//// ★ ТОЧКА РАСШИРЕНИЯ №3 — транспорт до провайдера.
////
//// Намеренно ничего не знает о формате тела: получает готовую строку и
//// возвращает сырой ответ. Переход на стриминг затронет только этот модуль.

import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import server/config.{type ProviderConfig}
import server/ids

/// Сырой обмен: ровно то, что ушло и что пришло.
pub type RawExchange {
  RawExchange(
    request_body: String,
    response_body: String,
    http_status: Int,
    latency_ms: Int,
  )
}

pub type TransportError {
  /// Нет ключа в окружении или не настроен base URL.
  NotConfigured(String)
  /// base URL не разбирается как адрес.
  BadUrl(String)
  /// Сеть недоступна, таймаут, обрыв соединения.
  Network(String)
}

/// Отправляет готовое тело провайдеру.
///
/// Засекает время вокруг самого запроса — latency в БД отражает именно
/// работу провайдера, без учёта сборки JSON и записи в базу.
pub fn send(
  entry: ProviderConfig,
  body: String,
  timeout_ms: Int,
) -> Result(RawExchange, TransportError) {
  use api_key <- result.try(require_key(entry))
  use base <- result.try(parse_url(entry))

  let http_request =
    base
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    // Ключ живёт только здесь и никогда не попадает в raw_request.
    |> request.set_header("authorization", "Bearer " <> api_key)
    |> request.set_header("accept", "application/json")
    |> request.set_body(body)

  let started = ids.now_ms()

  let outcome =
    httpc.configure()
    |> httpc.timeout(timeout_ms)
    |> httpc.dispatch(http_request)

  let latency_ms = ids.now_ms() - started

  case outcome {
    Ok(response.Response(status:, body: response_body, ..)) ->
      Ok(RawExchange(
        request_body: body,
        response_body:,
        http_status: status,
        latency_ms:,
      ))
    Error(error) -> Error(Network(describe_httpc(error, timeout_ms)))
  }
}

fn require_key(entry: ProviderConfig) -> Result(String, TransportError) {
  case entry.api_key {
    Some(key) -> Ok(key)
    None ->
      Error(NotConfigured(
        "для провайдера "
        <> entry.provider.title
        <> " не задан ключ в окружении",
      ))
  }
}

fn parse_url(
  entry: ProviderConfig,
) -> Result(request.Request(String), TransportError) {
  config.chat_url(entry)
  |> request.to
  |> result.replace_error(BadUrl(
    entry.provider.title <> ": некорректный адрес " <> config.chat_url(entry),
  ))
}

fn describe_httpc(error: httpc.HttpError, timeout_ms: Int) -> String {
  case error {
    httpc.InvalidUtf8Response -> "ответ провайдера не в UTF-8"
    httpc.FailedToConnect(ip4:, ip6:) ->
      "не удалось соединиться (ipv4: "
      <> string.inspect(ip4)
      <> ", ipv6: "
      <> string.inspect(ip6)
      <> ")"
    httpc.ResponseTimeout ->
      "провайдер не ответил за " <> int.to_string(timeout_ms) <> " мс"
  }
}

pub fn describe(error: TransportError) -> String {
  case error {
    NotConfigured(message) -> message
    BadUrl(message) -> message
    Network(message) -> message
  }
}
