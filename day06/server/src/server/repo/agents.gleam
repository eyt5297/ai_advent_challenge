//// Доступ к таблице `agents`.
////
//// Агент — настройка, которая живёт независимо от запусков: промпт,
//// модель и параметры задаются один раз и переиспользуются. Сессия
//// ссылается на агента через `sessions.agent_id`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/ids
import shared/codec
import shared/types.{type Agent, type AgentSummary, type RequestOptions}
import sqlight.{type Connection}

pub type RepoError {
  Sql(sqlight.Error)
  NotFound
  /// Агента нельзя удалить, пока на него ссылаются запуски: за ними стоит
  /// история работы, и терять её по одному клику недопустимо.
  InUse(session_count: Int)
}

// ─── Декодеры строк ──────────────────────────────────────────────────────────

const columns =
  "id, name, description, system_prompt, provider_id,
                 model_id, params_json, max_steps, tools_json,
                 memory_json, created_at, updated_at"

fn agent_decoder() -> Decoder(Agent) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use description <- decode.field(2, decode.string)
  use system_prompt <- decode.field(3, decode.string)
  use provider_id <- decode.field(4, decode.string)
  use model_id <- decode.field(5, decode.string)
  use params_json <- decode.field(6, decode.optional(decode.string))
  use max_steps <- decode.field(7, decode.int)
  use tools_json <- decode.field(8, decode.optional(decode.string))
  use memory_json <- decode.field(9, decode.optional(decode.string))
  use created_at <- decode.field(10, decode.int)
  use updated_at <- decode.field(11, decode.int)

  decode.success(types.Agent(
    id:,
    name:,
    description:,
    system_prompt:,
    provider_id:,
    model_id:,
    params: decode_params(params_json),
    max_steps:,
    tools: decode_tools(tools_json),
    memory: decode_memory(memory_json),
    created_at:,
    updated_at:,
  ))
}

fn summary_decoder() -> Decoder(AgentSummary) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use model_id <- decode.field(2, decode.string)
  use session_count <- decode.field(3, decode.int)
  decode.success(types.AgentSummary(id:, name:, model_id:, session_count:))
}

/// Битый JSON не должен мешать открыть агента: параметры вернутся
/// к значениям по умолчанию, остальные поля останутся на месте.
fn decode_params(raw: Option(String)) -> RequestOptions {
  case raw {
    Some(text) -> codec.options_from_string(text)
    None -> types.default_options()
  }
}

/// NULL — у агента, созданного до появления памяти. Поведение не
/// меняется молча: «без памяти» — это ровно то, как он работал.
fn decode_memory(raw: Option(String)) -> types.Memory {
  case raw {
    None -> types.no_memory()
    Some(text) ->
      json.parse(text, codec.memory_decoder())
      |> result.unwrap(types.no_memory())
  }
}

fn decode_tools(raw: Option(String)) -> List(String) {
  case raw {
    Some(text) ->
      json.parse(text, decode.list(decode.string)) |> result.unwrap([])
    None -> []
  }
}

fn encode_tools(tools: List(String)) -> String {
  json.array(tools, json.string) |> json.to_string
}

fn encode_memory(memory: types.Memory) -> String {
  codec.memory_to_json(memory) |> json.to_string
}

// ─── Чтение ──────────────────────────────────────────────────────────────────

/// Список для левой панели: свежие сверху, с числом запусков.
pub fn list(connection: Connection) -> Result(List(AgentSummary), RepoError) {
  "SELECT a.id, a.name, a.model_id,
          (SELECT COUNT(*) FROM sessions s WHERE s.agent_id = a.id)
     FROM agents a
    ORDER BY a.updated_at DESC, a.created_at DESC, a.rowid DESC"
  |> sqlight.query(on: connection, with: [], expecting: summary_decoder())
  |> result.map_error(Sql)
}

pub fn get(connection: Connection, id: String) -> Result(Agent, RepoError) {
  { "SELECT " <> columns <> " FROM agents WHERE id = ?" }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(id)],
    expecting: agent_decoder(),
  )
  |> result.map_error(Sql)
  |> result.try(first_row)
}

/// Поиск агента по имени — для инструмента `call_agent`.
///
/// Модель оперирует именами, а не идентификаторами: просить её запомнить
/// `agt_xK3…` бессмысленно. Регистр не важен.
pub fn find_by_name(
  connection: Connection,
  name: String,
) -> Result(Agent, RepoError) {
  { "SELECT " <> columns <> " FROM agents WHERE lower(name) = lower(?)" }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(string.trim(name))],
    expecting: agent_decoder(),
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

/// Поля, которые задаёт вызывающий код.
pub type NewAgent {
  NewAgent(
    name: String,
    description: String,
    system_prompt: String,
    provider_id: String,
    model_id: String,
    params: RequestOptions,
    max_steps: Int,
    tools: List(String),
    memory: types.Memory,
  )
}

/// Заготовка: описание и промпт пустые, параметры по умолчанию,
/// один шаг, без инструментов.
pub fn new(name: String, provider_id: String, model_id: String) -> NewAgent {
  NewAgent(
    name:,
    description: "",
    system_prompt: "",
    provider_id:,
    model_id:,
    params: types.default_options(),
    max_steps: types.single_step,
    tools: [],
    memory: types.no_memory(),
  )
}

pub fn create(
  connection: Connection,
  agent: NewAgent,
) -> Result(Agent, RepoError) {
  let now = ids.now_ms()
  let stored =
    types.Agent(
      id: ids.agent_id(),
      name: agent.name,
      description: agent.description,
      system_prompt: agent.system_prompt,
      provider_id: agent.provider_id,
      model_id: agent.model_id,
      params: agent.params,
      max_steps: agent.max_steps,
      tools: agent.tools,
      memory: agent.memory,
      created_at: now,
      updated_at: now,
    )

  {
    "INSERT INTO agents ("
    <> columns
    <> ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  }
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.text(stored.id),
      sqlight.text(stored.name),
      sqlight.text(stored.description),
      sqlight.text(stored.system_prompt),
      sqlight.text(stored.provider_id),
      sqlight.text(stored.model_id),
      sqlight.text(codec.options_to_string(stored.params)),
      sqlight.int(stored.max_steps),
      sqlight.text(encode_tools(stored.tools)),
      sqlight.text(encode_memory(stored.memory)),
      sqlight.int(stored.created_at),
      sqlight.int(stored.updated_at),
    ],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.replace(stored)
}

/// Частичное обновление: None оставляет поле как есть.
pub fn update(
  connection: Connection,
  id: String,
  name: Option(String),
  description: Option(String),
  system_prompt: Option(String),
  provider_id: Option(String),
  model_id: Option(String),
  params: Option(RequestOptions),
  max_steps: Option(Int),
  tools: Option(List(String)),
  memory: Option(types.Memory),
) -> Result(Agent, RepoError) {
  "UPDATE agents
      SET name          = COALESCE(?, name),
          description   = COALESCE(?, description),
          system_prompt = COALESCE(?, system_prompt),
          provider_id   = COALESCE(?, provider_id),
          model_id      = COALESCE(?, model_id),
          params_json   = COALESCE(?, params_json),
          max_steps     = COALESCE(?, max_steps),
          tools_json    = COALESCE(?, tools_json),
          memory_json   = COALESCE(?, memory_json),
          updated_at    = ?
    WHERE id = ?"
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.nullable(sqlight.text, name),
      sqlight.nullable(sqlight.text, description),
      sqlight.nullable(sqlight.text, system_prompt),
      sqlight.nullable(sqlight.text, provider_id),
      sqlight.nullable(sqlight.text, model_id),
      sqlight.nullable(
        sqlight.text,
        option.map(params, codec.options_to_string),
      ),
      sqlight.nullable(sqlight.int, max_steps),
      sqlight.nullable(sqlight.text, option.map(tools, encode_tools)),
      sqlight.nullable(sqlight.text, option.map(memory, encode_memory)),
      sqlight.int(ids.now_ms()),
      sqlight.text(id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.try(fn(_) { get(connection, id) })
}

/// Удаляет агента, если на него никто не ссылается.
///
/// Каскад здесь был бы опасен: за агентом стоит история запусков со всеми
/// сообщениями. Поэтому при наличии сессий возвращается `InUse`, и
/// пользователь решает сам.
pub fn delete(connection: Connection, id: String) -> Result(Nil, RepoError) {
  use agent <- result.try(get(connection, id))
  use count <- result.try(session_count(connection, agent.id))

  case count {
    0 ->
      "DELETE FROM agents WHERE id = ?"
      |> sqlight.query(
        on: connection,
        with: [sqlight.text(id)],
        expecting: decode.dynamic,
      )
      |> result.map_error(Sql)
      |> result.replace(Nil)

    _ -> Error(InUse(count))
  }
}

pub fn session_count(
  connection: Connection,
  id: String,
) -> Result(Int, RepoError) {
  "SELECT COUNT(*) FROM sessions WHERE agent_id = ?"
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(id)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(Sql)
  |> result.map(fn(rows) { list.first(rows) |> result.unwrap(0) })
}
