//// Доступ к таблице `sessions`.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/ids
import shared/codec
import shared/types.{type RequestOptions, type Session, type SessionSummary}
import sqlight.{type Connection}

pub type RepoError {
  Sql(sqlight.Error)
  NotFound
}

/// Заголовок новой сессии. Пока он не менялся, его можно подставить
/// автоматически по первому сообщению.
pub const default_title = "Новый чат"

// ─── Декодеры строк ──────────────────────────────────────────────────────────

fn session_decoder() -> Decoder(Session) {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use created_at <- decode.field(2, decode.int)
  use updated_at <- decode.field(3, decode.int)
  use agent_id <- decode.field(4, decode.optional(decode.string))
  use provider_id <- decode.field(5, decode.optional(decode.string))
  use model_id <- decode.field(6, decode.optional(decode.string))
  use params_json <- decode.field(7, decode.optional(decode.string))
  decode.success(types.Session(
    id:,
    title:,
    created_at:,
    updated_at:,
    agent_id:,
    provider_id:,
    model_id:,
    params: decode_params(params_json),
  ))
}

fn summary_decoder() -> Decoder(SessionSummary) {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use created_at <- decode.field(2, decode.int)
  use updated_at <- decode.field(3, decode.int)
  use message_count <- decode.field(4, decode.int)
  use agent_id <- decode.field(5, decode.optional(decode.string))
  decode.success(types.SessionSummary(
    id:,
    title:,
    created_at:,
    updated_at:,
    message_count:,
    agent_id:,
  ))
}

/// Битый или отсутствующий params_json не должен мешать открыть сессию.
fn decode_params(raw: Option(String)) -> RequestOptions {
  case raw {
    Some(json) -> codec.options_from_string(json)
    None -> types.default_options()
  }
}

// ─── Чтение ──────────────────────────────────────────────────────────────────

const select_columns =
  "id, title, created_at, updated_at, agent_id, provider_id, model_id, params_json"

/// Список для левой панели: свежие сверху, с числом сообщений.
pub fn list(connection: Connection) -> Result(List(SessionSummary), RepoError) {
  // rowid в конце — устойчивый tiebreaker: две сессии, созданные в одну
  // миллисекунду, иначе выстраивались бы в произвольном порядке.
  "SELECT s.id, s.title, s.created_at, s.updated_at,
          (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id),
          s.agent_id
     FROM sessions s
    ORDER BY s.updated_at DESC, s.created_at DESC, s.rowid DESC"
  |> sqlight.query(on: connection, with: [], expecting: summary_decoder())
  |> result.map_error(Sql)
}

/// Запуски одного агента — для второго уровня левой панели.
pub fn list_for_agent(
  connection: Connection,
  agent_id: String,
) -> Result(List(SessionSummary), RepoError) {
  "SELECT s.id, s.title, s.created_at, s.updated_at,
          (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id),
          s.agent_id
     FROM sessions s
    WHERE s.agent_id = ?
    ORDER BY s.updated_at DESC, s.created_at DESC, s.rowid DESC"
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(agent_id)],
    expecting: summary_decoder(),
  )
  |> result.map_error(Sql)
}

pub fn get(connection: Connection, id: String) -> Result(Session, RepoError) {
  { "SELECT " <> select_columns <> " FROM sessions WHERE id = ?" }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(id)],
    expecting: session_decoder(),
  )
  |> result.map_error(Sql)
  |> result.try(first_row)
}

pub fn exists(connection: Connection, id: String) -> Result(Bool, RepoError) {
  case get(connection, id) {
    Ok(_) -> Ok(True)
    Error(NotFound) -> Ok(False)
    Error(error) -> Error(error)
  }
}

fn first_row(rows: List(a)) -> Result(a, RepoError) {
  case rows {
    [row, ..] -> Ok(row)
    [] -> Error(NotFound)
  }
}

// ─── Запись ──────────────────────────────────────────────────────────────────

pub fn create(
  connection: Connection,
  title: Option(String),
  provider_id: Option(String),
  model_id: Option(String),
) -> Result(Session, RepoError) {
  create_for_agent(connection, None, title, provider_id, model_id)
}

/// Создаёт запуск агента. `agent_id = None` — сессия без агента,
/// режим «сообщение → запрос → ответ».
pub fn create_for_agent(
  connection: Connection,
  agent_id: Option(String),
  title: Option(String),
  provider_id: Option(String),
  model_id: Option(String),
) -> Result(Session, RepoError) {
  let id = ids.session_id()
  let now = ids.now_ms()
  let session =
    types.Session(
      id:,
      title: option.unwrap(title, default_title),
      created_at: now,
      updated_at: now,
      agent_id:,
      provider_id:,
      model_id:,
      params: types.default_options(),
    )

  {
    "INSERT INTO sessions ("
    <> select_columns
    <> ") VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
  }
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.text(session.id),
      sqlight.text(session.title),
      sqlight.int(session.created_at),
      sqlight.int(session.updated_at),
      sqlight.nullable(sqlight.text, session.agent_id),
      sqlight.nullable(sqlight.text, session.provider_id),
      sqlight.nullable(sqlight.text, session.model_id),
      sqlight.text(codec.options_to_string(session.params)),
    ],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.replace(session)
}

/// Частичное обновление: None оставляет поле как есть.
///
/// `COALESCE(?, column)` делает это одним запросом, без предварительного
/// чтения строки.
pub fn update(
  connection: Connection,
  id: String,
  title: Option(String),
  provider_id: Option(String),
  model_id: Option(String),
  params: Option(RequestOptions),
) -> Result(Session, RepoError) {
  let params_json = option.map(params, codec.options_to_string)

  "UPDATE sessions
      SET title       = COALESCE(?, title),
          provider_id = COALESCE(?, provider_id),
          model_id    = COALESCE(?, model_id),
          params_json = COALESCE(?, params_json),
          updated_at  = ?
    WHERE id = ?"
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.nullable(sqlight.text, title),
      sqlight.nullable(sqlight.text, provider_id),
      sqlight.nullable(sqlight.text, model_id),
      sqlight.nullable(sqlight.text, params_json),
      sqlight.int(ids.now_ms()),
      sqlight.text(id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.try(fn(_) { get(connection, id) })
}

/// Отмечает сессию изменённой — вызывается после отправки сообщения,
/// чтобы она всплыла наверх списка.
pub fn touch(connection: Connection, id: String) -> Result(Nil, RepoError) {
  "UPDATE sessions SET updated_at = ? WHERE id = ?"
  |> sqlight.query(
    on: connection,
    with: [sqlight.int(ids.now_ms()), sqlight.text(id)],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.replace(Nil)
}

/// Переименовывает сессию по первому сообщению, но только если заголовок
/// всё ещё стандартный — ручное имя не затираем.
pub fn autotitle(
  connection: Connection,
  id: String,
  content: String,
) -> Result(Nil, RepoError) {
  "UPDATE sessions SET title = ? WHERE id = ? AND title = ?"
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.text(title_from_content(content)),
      sqlight.text(id),
      sqlight.text(default_title),
    ],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.replace(Nil)
}

/// Заголовок сессии из первого сообщения: одна строка, не длиннее 60 знаков.
pub fn title_from_content(content: String) -> String {
  let cleaned =
    content
    |> string.replace("\r", " ")
    |> string.replace("\n", " ")
    |> string.trim

  case cleaned {
    "" -> default_title
    text ->
      case string.length(text) > 60 {
        True -> string.slice(text, at_index: 0, length: 57) <> "…"
        False -> text
      }
  }
}

pub fn delete(connection: Connection, id: String) -> Result(Nil, RepoError) {
  // Сообщения уходят каскадом: PRAGMA foreign_keys = ON включён в db.configure.
  "DELETE FROM sessions WHERE id = ?"
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(id)],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.replace(Nil)
}
