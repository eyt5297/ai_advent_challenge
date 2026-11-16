//// Вызовы внутреннего API сервера.
////
//// Каждая функция возвращает `Effect`, который шлёт соответствующий `Msg`.

import gleam/dynamic/decode.{type Decoder}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/option.{type Option, None}
import gleam/string
import lustre/effect.{type Effect}
import rsvp
import shared/api as dto
import shared/codec
import shared/types.{
  type Agent, type AgentSummary, type Message, type RequestOptions, type Session,
  type SessionSummary, type Task,
}

// ─── Каталог ─────────────────────────────────────────────────────────────────

pub fn load_catalog(
  on_result: fn(Result(dto.CatalogResponse, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.get(
    "/api/catalog",
    rsvp.expect_json(dto.catalog_response_decoder(), on_result),
  )
}

// ─── Агенты ──────────────────────────────────────────────────────────────────

/// Каталог инструментов. Запрашивается один раз при старте: реестр
/// вкомпилирован в сервер и за время работы не меняется.
pub fn load_tools(
  on_result: fn(Result(List(dto.ToolInfo), rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.get(
    "/api/tools",
    rsvp.expect_json(wrapped("tools", dto.tool_info_decoder()), on_result),
  )
}

pub fn load_agents(
  on_result: fn(Result(List(AgentSummary), rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.get(
    "/api/agents",
    rsvp.expect_json(
      wrapped("agents", codec.agent_summary_decoder()),
      on_result,
    ),
  )
}

/// Полная карточка агента — для формы правки.
///
/// Список отдаёт только имя и модель: показывать в нём промпт и параметры
/// незачем, а тащить их ради возможной правки — лишний трафик.
pub fn load_agent(
  id: String,
  on_result: fn(Result(Agent, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.get(
    "/api/agents/" <> id,
    rsvp.expect_json(codec.agent_decoder(), on_result),
  )
}

pub fn create_agent(
  request: dto.CreateAgentRequest,
  on_result: fn(Result(Agent, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/agents",
    dto.create_agent_request_to_json(request),
    rsvp.expect_json(codec.agent_decoder(), on_result),
  )
}

pub fn update_agent(
  id: String,
  request: dto.UpdateAgentRequest,
  on_result: fn(Result(Agent, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.patch(
    "/api/agents/" <> id,
    dto.update_agent_request_to_json(request),
    rsvp.expect_json(codec.agent_decoder(), on_result),
  )
}

/// Удаляет агента. Сервер отвечает `409`, если у него есть запуски:
/// иначе сессии осиротели бы.
pub fn delete_agent(
  id: String,
  on_result: fn(Result(Nil, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.delete(
    "/api/agents/" <> id,
    json.object([]),
    rsvp.expect_ok_response(fn(result) { on_result(result_to_nil(result)) }),
  )
}

/// Создаёт запуск агента — сессию, в которой выдаются задания.
pub fn start_agent_session(
  agent_id: String,
  on_result: fn(Result(Session, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/agents/" <> agent_id <> "/sessions",
    dto.start_session_request_to_json(dto.StartSessionRequest(title: None)),
    rsvp.expect_json(codec.session_decoder(), on_result),
  )
}

/// Что агент помнит об этой сессии: факты, пересказ, расход токенов.
pub fn load_memory(
  session_id: String,
  on_result: fn(Result(dto.MemoryResponse, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.get(
    "/api/sessions/" <> session_id <> "/memory",
    rsvp.expect_json(dto.memory_response_decoder(), on_result),
  )
}

// ─── Сессии ──────────────────────────────────────────────────────────────────

pub fn load_sessions(
  on_result: fn(Result(List(SessionSummary), rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.get(
    "/api/sessions",
    rsvp.expect_json(
      wrapped("sessions", codec.session_summary_decoder()),
      on_result,
    ),
  )
}

pub fn create_session(
  title: Option(String),
  on_result: fn(Result(Session, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/sessions",
    dto.create_session_request_to_json(dto.CreateSessionRequest(title:)),
    rsvp.expect_json(codec.session_decoder(), on_result),
  )
}

pub fn update_session(
  id: String,
  title: Option(String),
  provider_id: Option(String),
  model_id: Option(String),
  params: Option(RequestOptions),
  on_result: fn(Result(Session, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.patch(
    "/api/sessions/" <> id,
    dto.update_session_request_to_json(dto.UpdateSessionRequest(
      title:,
      provider_id:,
      model_id:,
      params:,
    )),
    rsvp.expect_json(codec.session_decoder(), on_result),
  )
}

pub fn delete_session(
  id: String,
  on_result: fn(Result(Nil, rsvp.Error)) -> msg,
) -> Effect(msg) {
  // Сервер отвечает 204 без тела, поэтому ждём только статус.
  rsvp.delete(
    "/api/sessions/" <> id,
    json.object([]),
    rsvp.expect_ok_response(fn(result) { on_result(result_to_nil(result)) }),
  )
}

fn result_to_nil(
  result: Result(Response(String), rsvp.Error),
) -> Result(Nil, rsvp.Error) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

pub fn load_messages(
  session_id: String,
  on_result: fn(Result(List(Message), rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.get(
    "/api/sessions/" <> session_id <> "/messages",
    rsvp.expect_json(wrapped("messages", codec.message_decoder()), on_result),
  )
}

/// Задания сессии. У сессии без агента список всегда пуст — лента
/// в этом случае остаётся плоской.
pub fn load_tasks(
  session_id: String,
  on_result: fn(Result(List(Task), rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.get(
    "/api/sessions/" <> session_id <> "/tasks",
    rsvp.expect_json(wrapped("tasks", codec.task_decoder()), on_result),
  )
}

/// Выдаёт задание агенту. Ответ приходит по завершении — вместе с шагами.
pub fn create_task(
  session_id: String,
  prompt: String,
  on_result: fn(Result(dto.TaskResponse, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/sessions/" <> session_id <> "/tasks",
    dto.create_task_request_to_json(dto.CreateTaskRequest(prompt:)),
    rsvp.expect_json(dto.task_response_decoder(), on_result),
  )
}

/// Удаляет задание со всеми его шагами.
///
/// Шаги по одному не удаляются: внутри задания они связаны историей,
/// и задание без части шагов невоспроизводимо.
pub fn delete_task(
  task_id: String,
  on_result: fn(Result(Nil, rsvp.Error)) -> msg,
) -> Effect(msg) {
  // Сервер отвечает 204 без тела, поэтому ждём только статус.
  rsvp.delete(
    "/api/tasks/" <> task_id,
    json.object([]),
    rsvp.expect_ok_response(fn(result) { on_result(result_to_nil(result)) }),
  )
}

/// Удаляет сообщение вместе с его парой; сервер возвращает id удалённых.
pub fn delete_message(
  session_id: String,
  message_id: String,
  on_result: fn(Result(List(String), rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.delete(
    "/api/sessions/" <> session_id <> "/messages/" <> message_id,
    json.object([]),
    rsvp.expect_json(wrapped("deleted", decode.string), on_result),
  )
}

pub fn load_session(
  session_id: String,
  on_result: fn(Result(Session, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.get(
    "/api/sessions/" <> session_id,
    rsvp.expect_json(codec.session_decoder(), on_result),
  )
}

// ─── Preview и Send ──────────────────────────────────────────────────────────

pub fn preview(
  session_id: String,
  request: dto.SendRequest,
  on_result: fn(Result(dto.PreviewResponse, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/sessions/" <> session_id <> "/preview",
    dto.send_request_to_json(request),
    rsvp.expect_json(dto.preview_response_decoder(), on_result),
  )
}

pub fn send(
  session_id: String,
  request: dto.SendRequest,
  on_result: fn(Result(dto.SendResponse, rsvp.Error)) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/sessions/" <> session_id <> "/send",
    dto.send_request_to_json(request),
    rsvp.expect_json(dto.send_response_decoder(), on_result),
  )
}

// ─── Вспомогательное ─────────────────────────────────────────────────────────

/// Декодер для ответов вида `{ "<key>": [ ... ] }`.
fn wrapped(key: String, inner: Decoder(a)) -> Decoder(List(a)) {
  decode.at([key], decode.list(inner))
}

/// Человекочитаемое описание ошибки запроса.
///
/// Сервер присылает ошибки в едином формате — пытаемся достать из них
/// сообщение, иначе объясняем происходящее своими словами.
pub fn describe_error(error: rsvp.Error) -> String {
  case error {
    rsvp.NetworkError -> "сервер недоступен"
    rsvp.BadUrl(url) -> "некорректный адрес: " <> url
    rsvp.BadBody -> "сервер вернул неожиданный ответ"
    rsvp.JsonError(_) -> "не удалось разобрать ответ сервера"
    rsvp.UnhandledResponse(response) ->
      "неожиданный статус " <> int_to_string(response.status)
    rsvp.HttpError(response) -> describe_http_error(response)
  }
}

fn describe_http_error(response: Response(String)) -> String {
  case json.parse(response.body, codec.api_error_decoder()) {
    Ok(api_error) -> api_error.message
    Error(_) ->
      case string.trim(response.body) {
        "" -> "ошибка " <> int_to_string(response.status)
        body -> truncate(body, 200)
      }
  }
}

fn truncate(value: String, limit: Int) -> String {
  case string.length(value) > limit {
    True -> string.slice(value, at_index: 0, length: limit) <> "…"
    False -> value
  }
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}
