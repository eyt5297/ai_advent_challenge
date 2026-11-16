//// Доступ к таблице `messages`.
////
//// Запрос и ответ хранятся двумя строками с соседним `seq`: у `User`
//// заполнен `raw_request`, у `Assistant` — `raw_response`. Такая форма
//// готова к будущему мультитёрновому режиму — история уже лежит рядом.

import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import server/ids
import shared/codec
import shared/types.{
  type Message, type MessageStatus, type RequestOptions, type Role, type Usage,
}
import sqlight.{type Connection}

pub type RepoError {
  Sql(sqlight.Error)
  NotFound
  /// Шаг задания нельзя удалить по отдельности: шаги связаны историей,
  /// и задание без части из них невоспроизводимо. Удаляется задание
  /// целиком через `tasks.delete`.
  BelongsToTask(task_id: String)
}

const columns =
  "id, session_id, seq, role, content, reasoning, provider_id,
                 model_id, status, error, params_json, hand_edited,
                 raw_request, raw_response, http_status, latency_ms,
                 usage_json, reply_to, task_id, step,
                 tool_calls_json, tool_call_id, created_at"

// ─── Декодер строки ──────────────────────────────────────────────────────────

fn message_decoder() -> Decoder(Message) {
  use id <- decode.field(0, decode.string)
  use session_id <- decode.field(1, decode.string)
  use seq <- decode.field(2, decode.int)
  use role_text <- decode.field(3, decode.string)
  use content <- decode.field(4, decode.string)
  use reasoning <- decode.field(5, decode.optional(decode.string))
  use provider_id <- decode.field(6, decode.optional(decode.string))
  use model_id <- decode.field(7, decode.optional(decode.string))
  use status_text <- decode.field(8, decode.string)
  use error <- decode.field(9, decode.optional(decode.string))
  use params_json <- decode.field(10, decode.optional(decode.string))
  use hand_edited <- decode.field(11, decode.int)
  use raw_request <- decode.field(12, decode.optional(decode.string))
  use raw_response <- decode.field(13, decode.optional(decode.string))
  use http_status <- decode.field(14, decode.optional(decode.int))
  use latency_ms <- decode.field(15, decode.optional(decode.int))
  use usage_json <- decode.field(16, decode.optional(decode.string))
  use reply_to <- decode.field(17, decode.optional(decode.string))
  use task_id <- decode.field(18, decode.optional(decode.string))
  use step <- decode.field(19, decode.optional(decode.int))
  use tool_calls_json <- decode.field(20, decode.optional(decode.string))
  use tool_call_id <- decode.field(21, decode.optional(decode.string))
  use created_at <- decode.field(22, decode.int)

  decode.success(types.Message(
    id:,
    session_id:,
    seq:,
    // Неизвестные значения из БД не должны ронять загрузку диалога.
    role: types.role_from_string(role_text) |> result.unwrap(types.User),
    content:,
    reasoning:,
    provider_id:,
    model_id:,
    status: types.status_from_string(status_text)
      |> result.unwrap(types.Done),
    error:,
    params: option.map(params_json, codec.options_from_string),
    hand_edited: hand_edited != 0,
    raw_request:,
    raw_response:,
    http_status:,
    latency_ms:,
    usage: option.then(usage_json, decode_usage),
    reply_to:,
    task_id:,
    step:,
    tool_calls: decode_tool_calls(tool_calls_json),
    tool_call_id:,
    created_at:,
  ))
}

/// Битый список вызовов не должен мешать открыть диалог: сырое тело
/// всё равно сохранено и видно в UI.
fn decode_tool_calls(raw: Option(String)) -> List(types.ToolCall) {
  case raw {
    Some(text) ->
      json.parse(text, decode.list(codec.tool_call_decoder()))
      |> result.unwrap([])
    None -> []
  }
}

fn decode_usage(raw: String) -> Option(Usage) {
  json.parse(raw, codec.usage_decoder()) |> option.from_result
}

// ─── Чтение ──────────────────────────────────────────────────────────────────

/// Шаги одного задания — то, что раскрывается в карточке.
///
/// Порядок по `seq`, а не по `step`: у старых строк `step` пустой, да и
/// внутри шага пара запрос-ответ должна идти в порядке записи.
pub fn list_for_task(
  connection: Connection,
  task_id: String,
) -> Result(List(Message), RepoError) {
  { "SELECT " <> columns <> " FROM messages WHERE task_id = ? ORDER BY seq" }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(task_id)],
    expecting: message_decoder(),
  )
  |> result.map_error(Sql)
}

/// Сообщения одного шага задания — для потока событий.
///
/// Шаг, а не всё задание: по SSE уходит только то, что появилось, иначе
/// каждое событие пересылало бы заново всю переписку.
pub fn list_for_step(
  connection: Connection,
  task_id: String,
  step: Int,
) -> Result(List(Message), RepoError) {
  {
    "SELECT "
    <> columns
    <> " FROM messages WHERE task_id = ? AND step = ? ORDER BY seq"
  }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(task_id), sqlight.int(step)],
    expecting: message_decoder(),
  )
  |> result.map_error(Sql)
}

pub fn list_for_session(
  connection: Connection,
  session_id: String,
) -> Result(List(Message), RepoError) {
  { "SELECT " <> columns <> " FROM messages WHERE session_id = ? ORDER BY seq" }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(session_id)],
    expecting: message_decoder(),
  )
  |> result.map_error(Sql)
}

pub fn get(connection: Connection, id: String) -> Result(Message, RepoError) {
  { "SELECT " <> columns <> " FROM messages WHERE id = ?" }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(id)],
    expecting: message_decoder(),
  )
  |> result.map_error(Sql)
  |> result.try(fn(rows) {
    case rows {
      [row, ..] -> Ok(row)
      [] -> Error(NotFound)
    }
  })
}

/// Следующий порядковый номер в сессии.
/// Номер последнего сообщения сессии; 0 для пустой.
///
/// Только для чтения — на запись номер присваивается внутри `insert`,
/// иначе между чтением и вставкой успевает вклиниться соседний процесс.
pub fn last_seq(
  connection: Connection,
  session_id: String,
) -> Result(Int, RepoError) {
  "SELECT COALESCE(MAX(seq), 0) FROM messages WHERE session_id = ?"
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(session_id)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(Sql)
  |> result.map(fn(rows) {
    case rows {
      [seq, ..] -> seq
      [] -> 0
    }
  })
}

// ─── Запись ──────────────────────────────────────────────────────────────────

/// Поля, которые задаёт вызывающий код; остальное заполняется здесь.
///
/// `seq` в списке намеренно отсутствует: номер присваивает `insert`
/// атомарно (см. там же).
pub type NewMessage {
  NewMessage(
    session_id: String,
    role: Role,
    content: String,
    reasoning: Option(String),
    provider_id: Option(String),
    model_id: Option(String),
    status: MessageStatus,
    error: Option(String),
    params: Option(RequestOptions),
    hand_edited: Bool,
    raw_request: Option(String),
    raw_response: Option(String),
    http_status: Option(Int),
    latency_ms: Option(Int),
    usage: Option(Usage),
    /// Заполняется у ответа — id запроса, на который он отвечает.
    reply_to: Option(String),
    /// К какому заданию относится шаг; None — сообщение вне заданий.
    task_id: Option(String),
    /// Номер обращения к LLM внутри задания.
    step: Option(Int),
    /// Запросы на вызов инструментов — у ответа модели.
    tool_calls: List(types.ToolCall),
    /// Какой вызов выполнен — у строки с ролью `Tool`.
    tool_call_id: Option(String),
  )
}

/// Заготовка со всеми необязательными полями в None.
pub fn new(session_id: String, role: Role, content: String) -> NewMessage {
  NewMessage(
    session_id:,
    role:,
    content:,
    reasoning: None,
    provider_id: None,
    model_id: None,
    status: types.Done,
    error: None,
    params: None,
    hand_edited: False,
    raw_request: None,
    raw_response: None,
    http_status: None,
    latency_ms: None,
    usage: None,
    reply_to: None,
    task_id: None,
    step: None,
    tool_calls: [],
    tool_call_id: None,
  )
}

/// Вставляет сообщение, присваивая `seq` следующим по сессии.
///
/// Номер вычисляется **внутри** оператора, а не отдельным запросом: между
/// чтением максимума и вставкой проходит весь запрос к провайдеру — секунды,
/// за которые соседний процесс успевает прочитать тот же максимум. SQLite
/// выполняет оператор атомарно, поэтому гонки здесь нет.
///
/// `RETURNING seq` возвращает присвоенный номер — угадывать его на стороне
/// вызывающего кода нельзя по той же причине.
pub fn insert(
  connection: Connection,
  message: NewMessage,
) -> Result(Message, RepoError) {
  let stored =
    types.Message(
      id: ids.message_id(),
      session_id: message.session_id,
      // Заполняется из RETURNING ниже; до вставки номер неизвестен.
      seq: 0,
      role: message.role,
      content: message.content,
      reasoning: message.reasoning,
      provider_id: message.provider_id,
      model_id: message.model_id,
      status: message.status,
      error: message.error,
      params: message.params,
      hand_edited: message.hand_edited,
      raw_request: message.raw_request,
      raw_response: message.raw_response,
      http_status: message.http_status,
      latency_ms: message.latency_ms,
      usage: message.usage,
      reply_to: message.reply_to,
      task_id: message.task_id,
      step: message.step,
      tool_calls: message.tool_calls,
      tool_call_id: message.tool_call_id,
      created_at: ids.now_ms(),
    )

  {
    "INSERT INTO messages ("
    <> columns
    <> ") SELECT ?, ?, COALESCE(MAX(seq), 0) + 1,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
         FROM messages WHERE session_id = ?
       RETURNING seq"
  }
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.text(stored.id),
      sqlight.text(stored.session_id),
      sqlight.text(types.role_to_string(stored.role)),
      sqlight.text(stored.content),
      sqlight.nullable(sqlight.text, stored.reasoning),
      sqlight.nullable(sqlight.text, stored.provider_id),
      sqlight.nullable(sqlight.text, stored.model_id),
      sqlight.text(types.status_to_string(stored.status)),
      sqlight.nullable(sqlight.text, stored.error),
      sqlight.nullable(
        sqlight.text,
        option.map(stored.params, codec.options_to_string),
      ),
      sqlight.bool(stored.hand_edited),
      sqlight.nullable(sqlight.text, stored.raw_request),
      sqlight.nullable(sqlight.text, stored.raw_response),
      sqlight.nullable(sqlight.int, stored.http_status),
      sqlight.nullable(sqlight.int, stored.latency_ms),
      sqlight.nullable(sqlight.text, encode_usage(stored.usage)),
      sqlight.nullable(sqlight.text, stored.reply_to),
      sqlight.nullable(sqlight.text, stored.task_id),
      sqlight.nullable(sqlight.int, stored.step),
      sqlight.nullable(sqlight.text, encode_tool_calls(stored.tool_calls)),
      sqlight.nullable(sqlight.text, stored.tool_call_id),
      sqlight.int(stored.created_at),
      // Последний параметр — для WHERE в подзапросе.
      sqlight.text(stored.session_id),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(Sql)
  |> result.try(fn(rows) {
    case rows {
      [seq, ..] -> Ok(types.Message(..stored, seq:))
      // RETURNING не вернул строку — вставки не произошло.
      [] -> Error(NotFound)
    }
  })
}

/// Пустой список не пишем: NULL честнее, чем "[]" в каждой строке.
fn encode_tool_calls(calls: List(types.ToolCall)) -> Option(String) {
  case calls {
    [] -> None
    _ -> Some(json.to_string(json.array(calls, codec.tool_call_to_json)))
  }
}

fn encode_usage(usage: Option(Usage)) -> Option(String) {
  case usage {
    Some(value) -> Some(value |> codec.usage_to_json |> json.to_string)
    None -> None
  }
}

/// Удаляет сообщение вместе с его парой.
///
/// Запрос и ответ — две строки с соседним `seq`, и поодиночке они
/// бессмысленны: вопрос без ответа или ответ без вопроса только путают.
/// Поэтому удаляем обмен целиком и возвращаем id удалённых строк.
pub fn delete_exchange(
  connection: Connection,
  id: String,
) -> Result(List(String), RepoError) {
  use message <- result.try(get(connection, id))
  use Nil <- result.try(case message.task_id {
    Some(task_id) -> Error(BelongsToTask(task_id))
    None -> Ok(Nil)
  })

  // Связь ищется в обе стороны: потянули за запрос — уйдёт его ответ,
  // потянули за ответ — уйдёт запрос, на который он ссылается.
  //
  // Последнее условие — для сообщений, записанных до появления `reply_to`:
  // у них связи нет, и пара определяется соседним номером, как раньше.
  // Для новых строк оно не срабатывает, потому что `reply_to` заполнен.
  let legacy_seq = case message.role {
    types.User -> message.seq + 1
    _ -> message.seq - 1
  }

  "DELETE FROM messages
    WHERE session_id = ?
      AND (
        id = ?
        OR reply_to = ?
        OR id = (SELECT reply_to FROM messages WHERE id = ?)
        OR (
          seq = ? AND role != ? AND reply_to IS NULL
          AND (SELECT reply_to FROM messages WHERE id = ?) IS NULL
        )
      )
   RETURNING id"
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.text(message.session_id),
      sqlight.text(id),
      sqlight.text(id),
      sqlight.text(id),
      sqlight.int(legacy_seq),
      sqlight.text(types.role_to_string(message.role)),
      sqlight.text(id),
    ],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(Sql)
}

pub fn delete_for_session(
  connection: Connection,
  session_id: String,
) -> Result(Nil, RepoError) {
  "DELETE FROM messages WHERE session_id = ?"
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(session_id)],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.replace(Nil)
}
