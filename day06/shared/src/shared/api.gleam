//// DTO внутреннего API между клиентом и сервером.
////
//// Отдельно от `shared/types`, потому что это форма общения, а не домен:
//// её можно менять, не трогая модель данных.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None}
import shared/codec
import shared/types.{
  type Fact, type Memory, type Message, type ProviderStatus, type RequestOptions,
  type Summary, type Task,
}

// ─── POST /api/sessions ──────────────────────────────────────────────────────

pub type CreateSessionRequest {
  CreateSessionRequest(title: Option(String))
}

pub fn create_session_request_to_json(request: CreateSessionRequest) -> Json {
  json.object([#("title", json.nullable(request.title, json.string))])
}

pub fn create_session_request_decoder() -> Decoder(CreateSessionRequest) {
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  decode.success(CreateSessionRequest(title:))
}

// ─── PATCH /api/sessions/:id ─────────────────────────────────────────────────

/// Частичное обновление: присутствующие поля применяются, отсутствующие — нет.
pub type UpdateSessionRequest {
  UpdateSessionRequest(
    title: Option(String),
    provider_id: Option(String),
    model_id: Option(String),
    params: Option(RequestOptions),
  )
}

pub fn update_session_request_to_json(request: UpdateSessionRequest) -> Json {
  json.object([
    #("title", json.nullable(request.title, json.string)),
    #("provider_id", json.nullable(request.provider_id, json.string)),
    #("model_id", json.nullable(request.model_id, json.string)),
    #("params", json.nullable(request.params, codec.options_to_json)),
  ])
}

pub fn update_session_request_decoder() -> Decoder(UpdateSessionRequest) {
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use provider_id <- decode.optional_field(
    "provider_id",
    None,
    decode.optional(decode.string),
  )
  use model_id <- decode.optional_field(
    "model_id",
    None,
    decode.optional(decode.string),
  )
  use params <- decode.optional_field(
    "params",
    None,
    decode.optional(codec.options_decoder()),
  )
  decode.success(UpdateSessionRequest(title:, provider_id:, model_id:, params:))
}

// ─── GET /api/tools ──────────────────────────────────────────────────────────

/// Инструмент в каталоге.
///
/// `parameters` — это JSON Schema, которая уходит модели. Клиенту она не
/// нужна (он показывает чекбокс с описанием), поэтому в DTO не попадает:
/// добавить поле позже легко, убрать — уже нет.
pub type ToolInfo {
  ToolInfo(id: String, description: String)
}

pub fn tool_info_decoder() -> Decoder(ToolInfo) {
  use id <- decode.field("id", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  decode.success(ToolInfo(id:, description:))
}

// ─── GET /api/sessions/:id/memory ────────────────────────────────────────────

/// Что агент помнит об этом запуске.
///
/// Факты, пересказ и расход токенов приходят вместе: показываются они
/// одной панелью, и три запроса ради неё — лишняя суета.
pub type MemoryResponse {
  MemoryResponse(facts: List(Fact), summary: Option(Summary), usage: TokenUsage)
}

/// Расход токенов по сессии.
///
/// Точные числа от провайдера, а не оценка: суммируется `usage`
/// сохранённых обменов.
pub type TokenUsage {
  TokenUsage(
    prompt_tokens: Int,
    completion_tokens: Int,
    total_tokens: Int,
    /// Сколько обменов учтено — у вызовов инструментов `usage` нет.
    exchanges: Int,
  )
}

pub fn memory_response_decoder() -> Decoder(MemoryResponse) {
  use facts <- decode.optional_field(
    "facts",
    [],
    decode.list(codec.fact_decoder()),
  )
  use summary <- decode.optional_field(
    "summary",
    None,
    decode.optional(codec.summary_decoder()),
  )
  use usage <- decode.optional_field(
    "usage",
    TokenUsage(0, 0, 0, 0),
    token_usage_decoder(),
  )
  decode.success(MemoryResponse(facts:, summary:, usage:))
}

pub fn token_usage_decoder() -> Decoder(TokenUsage) {
  use prompt_tokens <- decode.optional_field("prompt_tokens", 0, decode.int)
  use completion_tokens <- decode.optional_field(
    "completion_tokens",
    0,
    decode.int,
  )
  use total_tokens <- decode.optional_field("total_tokens", 0, decode.int)
  use exchanges <- decode.optional_field("exchanges", 0, decode.int)
  decode.success(TokenUsage(
    prompt_tokens:,
    completion_tokens:,
    total_tokens:,
    exchanges:,
  ))
}

// ─── POST /api/agents и PATCH /api/agents/:id ────────────────────────────────

/// Создание агента. Обязательны имя, провайдер и модель — без них агент
/// не сможет работать, и откладывать проверку до первого запуска незачем.
pub type CreateAgentRequest {
  CreateAgentRequest(
    name: String,
    description: String,
    system_prompt: String,
    provider_id: String,
    model_id: String,
    params: RequestOptions,
    max_steps: Int,
    tools: List(String),
    memory: Memory,
  )
}

pub fn create_agent_request_to_json(request: CreateAgentRequest) -> Json {
  json.object([
    #("name", json.string(request.name)),
    #("description", json.string(request.description)),
    #("system_prompt", json.string(request.system_prompt)),
    #("provider_id", json.string(request.provider_id)),
    #("model_id", json.string(request.model_id)),
    #("params", codec.options_to_json(request.params)),
    #("max_steps", json.int(request.max_steps)),
    #("tools", json.array(request.tools, json.string)),
    #("memory", codec.memory_to_json(request.memory)),
  ])
}

pub fn create_agent_request_decoder() -> Decoder(CreateAgentRequest) {
  use name <- decode.field("name", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use system_prompt <- decode.optional_field("system_prompt", "", decode.string)
  use provider_id <- decode.field("provider_id", decode.string)
  use model_id <- decode.field("model_id", decode.string)
  use params <- decode.optional_field(
    "params",
    types.default_options(),
    codec.options_decoder(),
  )
  use max_steps <- decode.optional_field(
    "max_steps",
    types.single_step,
    decode.int,
  )
  use tools <- decode.optional_field("tools", [], decode.list(decode.string))
  // Умолчание — «без памяти»: создание агента запросом без поля `memory`
  // должно вести себя как раньше.
  use memory <- decode.optional_field(
    "memory",
    types.no_memory(),
    codec.memory_decoder(),
  )
  decode.success(CreateAgentRequest(
    name:,
    description:,
    system_prompt:,
    provider_id:,
    model_id:,
    params:,
    max_steps:,
    tools:,
    memory:,
  ))
}

/// Частичное обновление агента: присутствующие поля применяются.
pub type UpdateAgentRequest {
  UpdateAgentRequest(
    name: Option(String),
    description: Option(String),
    system_prompt: Option(String),
    provider_id: Option(String),
    model_id: Option(String),
    params: Option(RequestOptions),
    max_steps: Option(Int),
    tools: Option(List(String)),
    memory: Option(Memory),
  )
}

pub fn update_agent_request_to_json(request: UpdateAgentRequest) -> Json {
  json.object([
    #("name", json.nullable(request.name, json.string)),
    #("description", json.nullable(request.description, json.string)),
    #("system_prompt", json.nullable(request.system_prompt, json.string)),
    #("provider_id", json.nullable(request.provider_id, json.string)),
    #("model_id", json.nullable(request.model_id, json.string)),
    #("params", json.nullable(request.params, codec.options_to_json)),
    #("max_steps", json.nullable(request.max_steps, json.int)),
    #("tools", json.nullable(request.tools, json.array(_, json.string))),
    #("memory", json.nullable(request.memory, codec.memory_to_json)),
  ])
}

pub fn update_agent_request_decoder() -> Decoder(UpdateAgentRequest) {
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use system_prompt <- decode.optional_field(
    "system_prompt",
    None,
    decode.optional(decode.string),
  )
  use provider_id <- decode.optional_field(
    "provider_id",
    None,
    decode.optional(decode.string),
  )
  use model_id <- decode.optional_field(
    "model_id",
    None,
    decode.optional(decode.string),
  )
  use params <- decode.optional_field(
    "params",
    None,
    decode.optional(codec.options_decoder()),
  )
  use max_steps <- decode.optional_field(
    "max_steps",
    None,
    decode.optional(decode.int),
  )
  use tools <- decode.optional_field(
    "tools",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use memory <- decode.optional_field(
    "memory",
    None,
    decode.optional(codec.memory_decoder()),
  )
  decode.success(UpdateAgentRequest(
    name:,
    description:,
    system_prompt:,
    provider_id:,
    model_id:,
    params:,
    max_steps:,
    tools:,
    memory:,
  ))
}

// ─── POST /api/agents/:id/sessions ───────────────────────────────────────────

/// Запуск экземпляра агента. Заголовок необязателен — по умолчанию
/// подставляется время запуска.
pub type StartSessionRequest {
  StartSessionRequest(title: Option(String))
}

pub fn start_session_request_to_json(request: StartSessionRequest) -> Json {
  json.object([#("title", json.nullable(request.title, json.string))])
}

pub fn start_session_request_decoder() -> Decoder(StartSessionRequest) {
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  decode.success(StartSessionRequest(title:))
}

// ─── POST /api/sessions/:id/tasks ────────────────────────────────────────────

/// Задание агенту. Текст — единственное, что нужно: модель, промпт и
/// параметры уже заданы агентом.
pub type CreateTaskRequest {
  CreateTaskRequest(prompt: String)
}

pub fn create_task_request_to_json(request: CreateTaskRequest) -> Json {
  json.object([#("prompt", json.string(request.prompt))])
}

pub fn create_task_request_decoder() -> Decoder(CreateTaskRequest) {
  use prompt <- decode.field("prompt", decode.string)
  decode.success(CreateTaskRequest(prompt:))
}

/// Ответ на создание и чтение задания: итог вместе с шагами.
pub type TaskResponse {
  TaskResponse(task: Task, messages: List(Message))
}

pub fn task_response_to_json(response: TaskResponse) -> Json {
  json.object([
    #("task", codec.task_to_json(response.task)),
    #("messages", json.array(response.messages, codec.message_to_json)),
  ])
}

pub fn task_response_decoder() -> Decoder(TaskResponse) {
  use task <- decode.field("task", codec.task_decoder())
  use messages <- decode.optional_field(
    "messages",
    [],
    decode.list(codec.message_decoder()),
  )
  decode.success(TaskResponse(task:, messages:))
}

// ─── GET /api/sessions/:id/events (SSE) ──────────────────────────────────────

/// Событие `step`: шаг задания завершён и записан.
///
/// Несёт сообщения целиком, а не идентификаторы: иначе на каждое событие
/// клиент отвечал бы запросом, и задержка вернулась бы на место.
pub type StepEvent {
  StepEvent(task_id: String, step: Int, messages: List(Message))
}

pub fn step_event_to_json(event: StepEvent) -> Json {
  json.object([
    #("task_id", json.string(event.task_id)),
    #("step", json.int(event.step)),
    #("messages", json.array(event.messages, codec.message_to_json)),
  ])
}

pub fn step_event_decoder() -> Decoder(StepEvent) {
  use task_id <- decode.field("task_id", decode.string)
  use step <- decode.field("step", decode.int)
  use messages <- decode.optional_field(
    "messages",
    [],
    decode.list(codec.message_decoder()),
  )
  decode.success(StepEvent(task_id:, step:, messages:))
}

/// Событие `task`: задание сменило состояние.
///
/// Форма совпадает с `{"task": …}` из `GET /api/tasks/:id` — намеренно:
/// расхождение здесь означало бы два разных описания одного и того же.
pub type TaskEvent {
  TaskEvent(task: Task)
}

pub fn task_event_to_json(event: TaskEvent) -> Json {
  json.object([#("task", codec.task_to_json(event.task))])
}

pub fn task_event_decoder() -> Decoder(TaskEvent) {
  use task <- decode.field("task", codec.task_decoder())
  decode.success(TaskEvent(task:))
}

// ─── POST /api/sessions/:id/preview и /send ──────────────────────────────────

/// Общее тело для preview и send: они отличаются только тем, уходит ли
/// запрос провайдеру.
pub type SendRequest {
  SendRequest(
    provider_id: String,
    model_id: String,
    content: String,
    params: RequestOptions,
    /// Если задано — тело уходит провайдеру как есть, `params` игнорируются.
    raw_request_override: Option(String),
  )
}

pub fn send_request_to_json(request: SendRequest) -> Json {
  json.object([
    #("provider_id", json.string(request.provider_id)),
    #("model_id", json.string(request.model_id)),
    #("content", json.string(request.content)),
    #("params", codec.options_to_json(request.params)),
    #(
      "raw_request_override",
      json.nullable(request.raw_request_override, json.string),
    ),
  ])
}

pub fn send_request_decoder() -> Decoder(SendRequest) {
  use provider_id <- decode.field("provider_id", decode.string)
  use model_id <- decode.field("model_id", decode.string)
  use content <- decode.field("content", decode.string)
  use params <- decode.optional_field(
    "params",
    types.default_options(),
    codec.options_decoder(),
  )
  use raw_request_override <- decode.optional_field(
    "raw_request_override",
    None,
    decode.optional(decode.string),
  )
  decode.success(SendRequest(
    provider_id:,
    model_id:,
    content:,
    params:,
    raw_request_override:,
  ))
}

/// Ответ на /preview: что уйдёт провайдеру, если нажать «Отправить».
pub type PreviewResponse {
  PreviewResponse(
    /// Отформатированное тело запроса.
    raw_request: String,
    /// Параметры после нормализации под провайдера и модель.
    effective_params: RequestOptions,
    /// Что пришлось поправить: «effort 'xhigh' не поддерживается, заменён…».
    warnings: List(String),
  )
}

pub fn preview_response_to_json(response: PreviewResponse) -> Json {
  json.object([
    #("raw_request", json.string(response.raw_request)),
    #("effective_params", codec.options_to_json(response.effective_params)),
    #("warnings", json.array(response.warnings, json.string)),
  ])
}

pub fn preview_response_decoder() -> Decoder(PreviewResponse) {
  use raw_request <- decode.field("raw_request", decode.string)
  use effective_params <- decode.field(
    "effective_params",
    codec.options_decoder(),
  )
  use warnings <- decode.optional_field(
    "warnings",
    [],
    decode.list(decode.string),
  )
  decode.success(PreviewResponse(raw_request:, effective_params:, warnings:))
}

/// Ответ на /send: пара сообщений, которую клиент дописывает в диалог.
pub type SendResponse {
  SendResponse(user: Message, assistant: Message, warnings: List(String))
}

pub fn send_response_to_json(response: SendResponse) -> Json {
  json.object([
    #("user", codec.message_to_json(response.user)),
    #("assistant", codec.message_to_json(response.assistant)),
    #("warnings", json.array(response.warnings, json.string)),
  ])
}

pub fn send_response_decoder() -> Decoder(SendResponse) {
  use user <- decode.field("user", codec.message_decoder())
  use assistant <- decode.field("assistant", codec.message_decoder())
  use warnings <- decode.optional_field(
    "warnings",
    [],
    decode.list(decode.string),
  )
  decode.success(SendResponse(user:, assistant:, warnings:))
}

// ─── GET /api/catalog ────────────────────────────────────────────────────────

pub type CatalogResponse {
  CatalogResponse(providers: List(ProviderStatus))
}

pub fn catalog_response_to_json(response: CatalogResponse) -> Json {
  json.object([
    #(
      "providers",
      json.array(response.providers, codec.provider_status_to_json),
    ),
  ])
}

pub fn catalog_response_decoder() -> Decoder(CatalogResponse) {
  use providers <- decode.field(
    "providers",
    decode.list(codec.provider_status_decoder()),
  )
  decode.success(CatalogResponse(providers:))
}
