//// Оркестрация обмена с провайдером.
////
//// Связывает три точки расширения в один сценарий и сохраняет результат.
//// Сами точки расширения (request / response / client) об этом модуле
//// ничего не знают — менять их можно независимо.

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/config.{type Config, type ProviderConfig}
import server/llm/client
import server/llm/request
import server/llm/response
import server/repo/messages
import server/repo/sessions
import shared/types.{
  type Message, type ModelInfo, type RequestOptions, type Session,
}
import sqlight.{type Connection}

pub type ChatError {
  UnknownProvider(String)
  UnknownModel(provider_id: String, model_id: String)
  ProviderUnavailable(String)
  EmptyContent
  /// raw_request_override не является JSON.
  InvalidOverride(String)
  Storage(String)
}

/// Подготовленный, но ещё не отправленный запрос.
pub type Prepared {
  Prepared(
    entry: ProviderConfig,
    model: ModelInfo,
    /// Параметры после нормализации — именно они пишутся в БД.
    effective_params: RequestOptions,
    /// Тело запроса в отформатированном виде.
    body: String,
    /// Правил ли пользователь тело руками.
    hand_edited: Bool,
    warnings: List(String),
  )
}

// ─── Подготовка (общая для preview и send) ───────────────────────────────────

/// Собирает тело запроса, не отправляя его.
///
/// `override` уходит провайдеру как есть — проверяется только разбираемость.
/// Так «править JSON руками» не ограничено структурой.
pub fn prepare(
  config: Config,
  provider_id: String,
  model_id: String,
  content: Option(String),
  params: RequestOptions,
  override: Option(String),
  history: List(Message),
  tools: List(Json),
) -> Result(Prepared, ChatError) {
  use entry <- result.try(
    config.provider_config(config, provider_id)
    |> result.replace_error(UnknownProvider(provider_id)),
  )
  use model <- result.try(
    types.find_model(entry.provider, model_id)
    |> result.replace_error(UnknownModel(provider_id, model_id)),
  )

  case override {
    // Ручной JSON: параметры не применяем, они уже вшиты в тело.
    Some(raw) -> {
      use formatted <- result.try(reformat_json(raw))
      Ok(
        Prepared(
          entry:,
          model:,
          effective_params: params,
          body: formatted,
          hand_edited: True,
          warnings: [],
        ),
      )
    }

    None -> {
      use trimmed <- result.try(require_content(content))
      let #(effective_params, warnings) =
        request.normalize_options(entry.provider, model, params)

      let body =
        request.RequestContext(
          provider: entry.provider,
          model:,
          user_content: trimmed,
          history:,
          options: effective_params,
          tools:,
        )
        |> request.build_request_body
        |> json.to_string

      Ok(Prepared(
        entry:,
        model:,
        effective_params:,
        body: pretty(body),
        hand_edited: False,
        warnings: list.map(warnings, fn(warning) { warning.message }),
      ))
    }
  }
}

/// None допустимо: это продолжение истории после вызова инструментов,
/// где нового сообщения от пользователя нет.
fn require_content(
  content: Option(String),
) -> Result(Option(String), ChatError) {
  case content {
    None -> Ok(None)
    Some(text) ->
      case string.trim(text) {
        "" -> Error(EmptyContent)
        trimmed -> Ok(Some(trimmed))
      }
  }
}

/// Проверяет, что строка — валидный JSON-объект, и возвращает её как есть.
///
/// Переформатировать не пытаемся: пользователь мог специально оформить тело
/// по-своему, и подменять его невежливо.
fn reformat_json(raw: String) -> Result(String, ChatError) {
  case json.parse(raw, decode.dynamic) {
    Ok(_) -> Ok(raw)
    Error(error) -> Error(InvalidOverride(describe_json_error(error)))
  }
}

fn describe_json_error(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "неожиданный конец ввода"
    json.UnexpectedByte(byte) -> "неожиданный символ " <> byte
    json.UnexpectedSequence(seq) -> "неожиданная последовательность " <> seq
    json.UnableToDecode(_) -> "структура не разобрана"
  }
}

// ─── Отправка ────────────────────────────────────────────────────────────────

/// Результат обмена: пара сообщений для диалога.
pub type Exchange {
  Exchange(user: Message, assistant: Message, warnings: List(String))
}

/// Чей это обмен.
///
/// Отдельный тип вместо пары необязательных аргументов: так нельзя
/// случайно задать номер шага без задания или наоборот.
pub type Attribution {
  /// Обмен сам по себе — ручная отправка в сессии без агента.
  Standalone
  /// Шаг внутри задания агента.
  Step(task_id: String, step: Int)
}

/// Отправляет подготовленный запрос и сохраняет обе строки в БД.
///
/// Любая неудача провайдера становится сообщением со `status = error`,
/// а не ошибкой HTTP-ответа: диалог должен сохранить след неудачной попытки
/// вместе с сырым телом.
pub fn send(
  connection: Connection,
  config: Config,
  session: Session,
  prepared: Prepared,
  content: Option(String),
  attribution: Attribution,
) -> Result(Exchange, ChatError) {
  let provider_id = prepared.entry.provider.id
  let model_id = prepared.model.id

  let #(task_id, step) = case attribution {
    Standalone -> #(None, None)
    Step(task_id:, step:) -> #(Some(task_id), Some(step))
  }

  // Строка-запрос существует всегда: в ней лежит raw_request, ради
  // которого каркас и строился. При продолжении истории текст пуст —
  // видно, что шаг инициирован не человеком, а циклом агента.
  let request_text = case content {
    Some(text) -> string.trim(text)
    None -> ""
  }

  // Номера строкам присваивает insert — здесь они неизвестны и не нужны.
  use user_message <- result.try(
    messages.NewMessage(
      ..messages.new(session.id, types.User, request_text),
      provider_id: Some(provider_id),
      model_id: Some(model_id),
      params: Some(prepared.effective_params),
      hand_edited: prepared.hand_edited,
      raw_request: Some(prepared.body),
      task_id:,
      step:,
    )
    |> messages.insert(connection, _)
    |> map_repo_error,
  )

  let outcome =
    client.send(prepared.entry, prepared.body, config.request_timeout_ms)

  let assistant_draft = case outcome {
    // Транспорт не дошёл до провайдера: сырого ответа нет вовсе.
    Error(transport_error) ->
      messages.NewMessage(
        ..messages.new(session.id, types.Assistant, ""),
        provider_id: Some(provider_id),
        model_id: Some(model_id),
        params: Some(prepared.effective_params),
        status: types.Failed,
        error: Some(client.describe(transport_error)),
        reply_to: Some(user_message.id),
        task_id:,
        step:,
      )

    Ok(exchange) ->
      case
        response.parse_response_body(
          prepared.entry.provider,
          exchange.http_status,
          exchange.response_body,
        )
      {
        Ok(parsed) ->
          messages.NewMessage(
            ..messages.new(session.id, types.Assistant, parsed.content),
            reasoning: parsed.reasoning,
            provider_id: Some(provider_id),
            model_id: Some(model_id),
            params: Some(prepared.effective_params),
            status: types.Done,
            raw_response: Some(exchange.response_body),
            http_status: Some(exchange.http_status),
            latency_ms: Some(exchange.latency_ms),
            usage: parsed.usage,
            reply_to: Some(user_message.id),
            task_id:,
            step:,
            tool_calls: parsed.tool_calls,
          )

        // Ответ пришёл, но разобрать не удалось: сохраняем сырое тело —
        // в UI оно раскрывается и видно, что именно вернул провайдер.
        Error(parse_error) ->
          messages.NewMessage(
            ..messages.new(session.id, types.Assistant, ""),
            provider_id: Some(provider_id),
            model_id: Some(model_id),
            params: Some(prepared.effective_params),
            status: types.Failed,
            error: Some(response.describe(parse_error)),
            raw_response: Some(exchange.response_body),
            http_status: Some(exchange.http_status),
            latency_ms: Some(exchange.latency_ms),
            reply_to: Some(user_message.id),
            task_id:,
            step:,
          )
      }
  }

  use assistant_message <- result.try(
    messages.insert(connection, assistant_draft) |> map_repo_error,
  )

  // Сессия всплывает наверх списка и получает имя по первому вопросу.
  // Запуск агента переименовывать не нужно: он уже назван по агенту,
  // и подменять это текстом служебного шага было бы неожиданно.
  let _ = sessions.touch(connection, session.id)
  let _ = case attribution, content {
    Standalone, Some(text) -> sessions.autotitle(connection, session.id, text)
    _, _ -> Ok(Nil)
  }

  Ok(Exchange(
    user: user_message,
    assistant: assistant_message,
    warnings: prepared.warnings,
  ))
}

/// Текст запроса для показа в ленте. None — продолжение истории после
/// вызова инструментов: нового сообщения от пользователя там нет.
fn map_repo_error(
  result: Result(a, messages.RepoError),
) -> Result(a, ChatError) {
  result.map_error(result, fn(error) {
    case error {
      messages.NotFound -> Storage("запись не найдена")
      messages.BelongsToTask(_) -> Storage("шаг задания")
      messages.Sql(sql) -> Storage(string.inspect(sql))
    }
  })
}

// ─── Форматирование JSON ─────────────────────────────────────────────────────

/// Отступы в 2 пробела для читаемого вида в редакторе и в блоке «сырой JSON».
///
/// gleam_json умеет только компактный вывод, поэтому форматируем сами:
/// проходим по строке и расставляем переносы вне строковых литералов.
pub fn pretty(input: String) -> String {
  do_pretty(string.to_graphemes(input), 0, False, False, [])
  |> list.reverse
  |> string.join("")
}

fn do_pretty(
  chars: List(String),
  depth: Int,
  in_string: Bool,
  escaped: Bool,
  acc: List(String),
) -> List(String) {
  case chars {
    [] -> acc

    [char, ..rest] if in_string ->
      case escaped, char {
        True, _ -> do_pretty(rest, depth, True, False, [char, ..acc])
        False, "\\" -> do_pretty(rest, depth, True, True, [char, ..acc])
        False, "\"" -> do_pretty(rest, depth, False, False, [char, ..acc])
        False, _ -> do_pretty(rest, depth, True, False, [char, ..acc])
      }

    ["\"", ..rest] -> do_pretty(rest, depth, True, False, ["\"", ..acc])

    [open, ..rest] if open == "{" || open == "[" ->
      case rest {
        // Пустой объект или массив оставляем в одну строку.
        [close, ..tail] if close == "}" || close == "]" ->
          do_pretty(tail, depth, False, False, [open <> close, ..acc])
        _ ->
          do_pretty(rest, depth + 1, False, False, [
            open <> newline(depth + 1),
            ..acc
          ])
      }

    [close, ..rest] if close == "}" || close == "]" ->
      do_pretty(rest, depth - 1, False, False, [
        newline(depth - 1) <> close,
        ..acc
      ])

    [",", ..rest] ->
      do_pretty(rest, depth, False, False, ["," <> newline(depth), ..acc])

    [":", ..rest] -> do_pretty(rest, depth, False, False, [": ", ..acc])

    [char, ..rest] -> do_pretty(rest, depth, False, False, [char, ..acc])
  }
}

fn newline(depth: Int) -> String {
  "\n" <> string.repeat("  ", depth)
}

// ─── Описание ошибок ─────────────────────────────────────────────────────────

pub fn describe(error: ChatError) -> String {
  case error {
    UnknownProvider(id) -> "неизвестный провайдер: " <> id
    UnknownModel(provider_id:, model_id:) ->
      "модель " <> model_id <> " не найдена у провайдера " <> provider_id
    ProviderUnavailable(title) ->
      "провайдер " <> title <> " недоступен: не задан ключ в окружении"
    EmptyContent -> "сообщение пустое"
    InvalidOverride(detail) -> "отредактированный JSON некорректен: " <> detail
    Storage(detail) -> "ошибка базы данных: " <> detail
  }
}

pub fn error_code(error: ChatError) -> String {
  case error {
    UnknownProvider(_) -> "unknown_provider"
    UnknownModel(..) -> "unknown_model"
    ProviderUnavailable(_) -> "provider_unavailable"
    EmptyContent -> "empty_content"
    InvalidOverride(_) -> "invalid_override"
    Storage(_) -> "storage_error"
  }
}

/// HTTP-статус для ответа API.
pub fn http_status(error: ChatError) -> Int {
  case error {
    UnknownProvider(_) | UnknownModel(..) | EmptyContent | InvalidOverride(_) ->
      400
    ProviderUnavailable(_) -> 503
    Storage(_) -> 500
  }
}

/// Проверка доступности перед отправкой — отдельно от `prepare`,
/// потому что preview должен работать и без ключа.
pub fn require_available(entry: ProviderConfig) -> Result(Nil, ChatError) {
  case config.is_available(entry) {
    True -> Ok(Nil)
    False -> Error(ProviderUnavailable(entry.provider.title))
  }
}
