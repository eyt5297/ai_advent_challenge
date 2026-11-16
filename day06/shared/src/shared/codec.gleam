//// JSON-кодеки для типов из `shared/types`.
////
//// Используются и сервером (ответы API, запись в БД), и клиентом (разбор
//// ответов). Держим их в одном месте, чтобы формат не разъезжался.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import shared/types.{
  type Agent, type AgentSummary, type Fact, type Memory, type Message,
  type MessageStatus, type ModelGroup, type ModelInfo, type Provider,
  type ProviderStatus, type ReasoningSupport, type RequestOptions, type Role,
  type Session, type SessionSummary, type Summary, type Task, type TaskStatus,
  type ToolCall, type Usage, Agent, AgentSummary, AlwaysReasoning, Fact, Message,
  ModelGroup, ModelInfo, NoReasoning, OptionalReasoning, Provider,
  ProviderStatus, RequestOptions, Session, SessionSummary, Summary, Task,
  ToolCall, Usage,
}

// ─── Вспомогательное ─────────────────────────────────────────────────────────

/// Декодер поля-перечисления, заданного парой to_string/from_string.
fn enum_decoder(
  name: String,
  parse: fn(String) -> Result(a, Nil),
  fallback: a,
) -> Decoder(a) {
  decode.string
  |> decode.then(fn(value) {
    case parse(value) {
      Ok(parsed) -> decode.success(parsed)
      Error(Nil) -> decode.failure(fallback, name)
    }
  })
}

// ─── RequestOptions ──────────────────────────────────────────────────────────

pub fn options_to_json(options: RequestOptions) -> Json {
  json.object([
    #("temperature", json.nullable(options.temperature, json.float)),
    #("max_tokens", json.nullable(options.max_tokens, json.int)),
    #("system_prompt", json.nullable(options.system_prompt, json.string)),
    #("reasoning_enabled", json.nullable(options.reasoning_enabled, json.bool)),
    #("reasoning_effort", json.nullable(options.reasoning_effort, json.string)),
    #("stream", json.bool(options.stream)),
  ])
}

pub fn options_decoder() -> Decoder(RequestOptions) {
  use temperature <- decode.optional_field(
    "temperature",
    None,
    decode.optional(decode.float),
  )
  use max_tokens <- decode.optional_field(
    "max_tokens",
    None,
    decode.optional(decode.int),
  )
  use system_prompt <- decode.optional_field(
    "system_prompt",
    None,
    decode.optional(decode.string),
  )
  use reasoning_enabled <- decode.optional_field(
    "reasoning_enabled",
    None,
    decode.optional(decode.bool),
  )
  use reasoning_effort <- decode.optional_field(
    "reasoning_effort",
    None,
    decode.optional(decode.string),
  )
  use stream <- decode.optional_field("stream", False, decode.bool)
  decode.success(RequestOptions(
    temperature:,
    max_tokens:,
    system_prompt:,
    reasoning_enabled:,
    reasoning_effort:,
    stream:,
  ))
}

/// Разбирает `params_json` из БД. Битые данные не должны ронять загрузку
/// сессии — возвращаем дефолт.
pub fn options_from_string(raw: String) -> RequestOptions {
  case json.parse(raw, options_decoder()) {
    Ok(options) -> options
    Error(_) -> types.default_options()
  }
}

pub fn options_to_string(options: RequestOptions) -> String {
  options |> options_to_json |> json.to_string
}

// ─── Каталог ─────────────────────────────────────────────────────────────────

pub fn reasoning_to_json(support: ReasoningSupport) -> Json {
  case support {
    NoReasoning -> json.object([#("kind", json.string("none"))])
    OptionalReasoning(default_enabled:, default_effort:, efforts:) ->
      json.object([
        #("kind", json.string("optional")),
        #("default_enabled", json.bool(default_enabled)),
        #("default_effort", json.string(default_effort)),
        #("efforts", json.array(efforts, json.string)),
      ])
    AlwaysReasoning(default_effort:, efforts:) ->
      json.object([
        #("kind", json.string("always")),
        #("default_effort", json.string(default_effort)),
        #("efforts", json.array(efforts, json.string)),
      ])
  }
}

pub fn reasoning_decoder() -> Decoder(ReasoningSupport) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "none" -> decode.success(NoReasoning)
    "optional" -> {
      use default_enabled <- decode.field("default_enabled", decode.bool)
      use default_effort <- decode.field("default_effort", decode.string)
      use efforts <- decode.field("efforts", decode.list(decode.string))
      decode.success(OptionalReasoning(
        default_enabled:,
        default_effort:,
        efforts:,
      ))
    }
    "always" -> {
      use default_effort <- decode.field("default_effort", decode.string)
      use efforts <- decode.field("efforts", decode.list(decode.string))
      decode.success(AlwaysReasoning(default_effort:, efforts:))
    }
    _ -> decode.failure(NoReasoning, "ReasoningSupport")
  }
}

pub fn model_to_json(model: ModelInfo) -> Json {
  json.object([
    #("id", json.string(model.id)),
    #("title", json.string(model.title)),
    #("context_length", json.int(model.context_length)),
    #("max_output_tokens", json.int(model.max_output_tokens)),
    #("vision", json.bool(model.vision)),
    #("tools", json.bool(model.tools)),
    #("reasoning", reasoning_to_json(model.reasoning)),
  ])
}

pub fn model_decoder() -> Decoder(ModelInfo) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use context_length <- decode.optional_field("context_length", 0, decode.int)
  use max_output_tokens <- decode.optional_field(
    "max_output_tokens",
    0,
    decode.int,
  )
  use vision <- decode.optional_field("vision", False, decode.bool)
  use tools <- decode.optional_field("tools", False, decode.bool)
  use reasoning <- decode.field("reasoning", reasoning_decoder())
  decode.success(ModelInfo(
    id:,
    title:,
    context_length:,
    max_output_tokens:,
    vision:,
    tools:,
    reasoning:,
  ))
}

pub fn group_to_json(group: ModelGroup) -> Json {
  json.object([
    #("title", json.string(group.title)),
    #("models", json.array(group.models, model_to_json)),
  ])
}

pub fn group_decoder() -> Decoder(ModelGroup) {
  use title <- decode.field("title", decode.string)
  use models <- decode.field("models", decode.list(model_decoder()))
  decode.success(ModelGroup(title:, models:))
}

pub fn provider_to_json(provider: Provider) -> Json {
  json.object([
    #("id", json.string(provider.id)),
    #("title", json.string(provider.title)),
    #("default_model", json.string(provider.default_model)),
    #("groups", json.array(provider.groups, group_to_json)),
  ])
}

pub fn provider_decoder() -> Decoder(Provider) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use default_model <- decode.field("default_model", decode.string)
  use groups <- decode.field("groups", decode.list(group_decoder()))
  decode.success(Provider(id:, title:, default_model:, groups:))
}

pub fn provider_status_to_json(status: ProviderStatus) -> Json {
  json.object([
    #("provider", provider_to_json(status.provider)),
    #("available", json.bool(status.available)),
  ])
}

pub fn provider_status_decoder() -> Decoder(ProviderStatus) {
  use provider <- decode.field("provider", provider_decoder())
  use available <- decode.field("available", decode.bool)
  decode.success(ProviderStatus(provider:, available:))
}

// ─── Агенты ──────────────────────────────────────────────────────────────────

pub fn agent_to_json(agent: Agent) -> Json {
  json.object([
    #("id", json.string(agent.id)),
    #("name", json.string(agent.name)),
    #("description", json.string(agent.description)),
    #("system_prompt", json.string(agent.system_prompt)),
    #("provider_id", json.string(agent.provider_id)),
    #("model_id", json.string(agent.model_id)),
    #("params", options_to_json(agent.params)),
    #("max_steps", json.int(agent.max_steps)),
    #("tools", json.array(agent.tools, json.string)),
    #("memory", memory_to_json(agent.memory)),
    #("created_at", json.int(agent.created_at)),
    #("updated_at", json.int(agent.updated_at)),
  ])
}

pub fn agent_decoder() -> Decoder(Agent) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use system_prompt <- decode.optional_field("system_prompt", "", decode.string)
  use provider_id <- decode.field("provider_id", decode.string)
  use model_id <- decode.field("model_id", decode.string)
  use params <- decode.optional_field(
    "params",
    types.default_options(),
    options_decoder(),
  )
  use max_steps <- decode.optional_field(
    "max_steps",
    types.single_step,
    decode.int,
  )
  use tools <- decode.optional_field("tools", [], decode.list(decode.string))
  use memory <- decode.optional_field(
    "memory",
    types.no_memory(),
    memory_decoder(),
  )
  use created_at <- decode.optional_field("created_at", 0, decode.int)
  use updated_at <- decode.optional_field("updated_at", 0, decode.int)
  decode.success(Agent(
    id:,
    name:,
    description:,
    system_prompt:,
    provider_id:,
    model_id:,
    params:,
    max_steps:,
    tools:,
    memory:,
    created_at:,
    updated_at:,
  ))
}

pub fn agent_summary_to_json(agent: AgentSummary) -> Json {
  json.object([
    #("id", json.string(agent.id)),
    #("name", json.string(agent.name)),
    #("model_id", json.string(agent.model_id)),
    #("session_count", json.int(agent.session_count)),
  ])
}

pub fn agent_summary_decoder() -> Decoder(AgentSummary) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use model_id <- decode.optional_field("model_id", "", decode.string)
  use session_count <- decode.optional_field("session_count", 0, decode.int)
  decode.success(AgentSummary(id:, name:, model_id:, session_count:))
}

// ─── Память ──────────────────────────────────────────────────────────────────

/// Память в JSON.
///
/// Плоский объект, а не вложенный вариант: так его читает и человек в
/// `agents.memory_json`, и форма в интерфейсе — без разбора тегов.
pub fn memory_to_json(memory: Memory) -> Json {
  json.object([
    #("window", json.string(types.window_to_string(memory.window))),
    #("window_tasks", json.int(types.window_tasks(memory.window))),
    #("summary_every", json.int(summary_every(memory.summary))),
    #("facts", json.bool(memory.facts)),
    #("budget_chars", json.int(memory.budget_chars)),
  ])
}

fn summary_every(mode: types.SummaryMode) -> Int {
  case mode {
    types.NoSummary -> 0
    types.SummarizeEvery(messages:) -> messages
  }
}

pub fn memory_decoder() -> Decoder(Memory) {
  use window <- decode.optional_field("window", "none", decode.string)
  use window_tasks <- decode.optional_field("window_tasks", 10, decode.int)
  use summary_every <- decode.optional_field("summary_every", 0, decode.int)
  use facts <- decode.optional_field("facts", False, decode.bool)
  use budget_chars <- decode.optional_field("budget_chars", 0, decode.int)

  decode.success(types.Memory(
    window: types.window_from(window, window_tasks),
    // Ноль и отрицательное — «не сжимать»: иначе порог в ноль сообщений
    // означал бы пересказ на каждом шаге.
    summary: case summary_every > 0 {
      True -> types.SummarizeEvery(summary_every)
      False -> types.NoSummary
    },
    facts:,
    budget_chars:,
  ))
}

pub fn fact_to_json(fact: Fact) -> Json {
  json.object([
    #("id", json.string(fact.id)),
    #("session_id", json.string(fact.session_id)),
    #("text", json.string(fact.text)),
    #("created_at", json.int(fact.created_at)),
  ])
}

pub fn fact_decoder() -> Decoder(Fact) {
  use id <- decode.field("id", decode.string)
  use session_id <- decode.optional_field("session_id", "", decode.string)
  use text <- decode.field("text", decode.string)
  use created_at <- decode.optional_field("created_at", 0, decode.int)
  decode.success(Fact(id:, session_id:, text:, created_at:))
}

pub fn summary_to_json(summary: Summary) -> Json {
  json.object([
    #("id", json.string(summary.id)),
    #("session_id", json.string(summary.session_id)),
    #("text", json.string(summary.text)),
    #("covers_through_seq", json.int(summary.covers_through_seq)),
    #("message_count", json.int(summary.message_count)),
    #("created_at", json.int(summary.created_at)),
  ])
}

pub fn summary_decoder() -> Decoder(Summary) {
  use id <- decode.field("id", decode.string)
  use session_id <- decode.optional_field("session_id", "", decode.string)
  use text <- decode.field("text", decode.string)
  use covers_through_seq <- decode.optional_field(
    "covers_through_seq",
    0,
    decode.int,
  )
  use message_count <- decode.optional_field("message_count", 0, decode.int)
  use created_at <- decode.optional_field("created_at", 0, decode.int)
  decode.success(Summary(
    id:,
    session_id:,
    text:,
    covers_through_seq:,
    message_count:,
    created_at:,
  ))
}

// ─── Задания ─────────────────────────────────────────────────────────────────

pub fn task_status_decoder() -> Decoder(TaskStatus) {
  enum_decoder("TaskStatus", types.task_status_from_string, types.Running)
}

pub fn task_to_json(task: Task) -> Json {
  json.object([
    #("id", json.string(task.id)),
    #("session_id", json.string(task.session_id)),
    #("seq", json.int(task.seq)),
    #("prompt", json.string(task.prompt)),
    #("result", json.nullable(task.result, json.string)),
    #("status", json.string(types.task_status_to_string(task.status))),
    #("error", json.nullable(task.error, json.string)),
    #("steps", json.int(task.steps)),
    #("created_at", json.int(task.created_at)),
    #("finished_at", json.nullable(task.finished_at, json.int)),
  ])
}

pub fn task_decoder() -> Decoder(Task) {
  use id <- decode.field("id", decode.string)
  use session_id <- decode.field("session_id", decode.string)
  use seq <- decode.optional_field("seq", 0, decode.int)
  use prompt <- decode.field("prompt", decode.string)
  use result <- decode.optional_field(
    "result",
    None,
    decode.optional(decode.string),
  )
  use status <- decode.field("status", task_status_decoder())
  use error <- decode.optional_field(
    "error",
    None,
    decode.optional(decode.string),
  )
  use steps <- decode.optional_field("steps", 0, decode.int)
  use created_at <- decode.optional_field("created_at", 0, decode.int)
  use finished_at <- decode.optional_field(
    "finished_at",
    None,
    decode.optional(decode.int),
  )
  decode.success(Task(
    id:,
    session_id:,
    seq:,
    prompt:,
    result:,
    status:,
    error:,
    steps:,
    created_at:,
    finished_at:,
  ))
}

// ─── Сессии ──────────────────────────────────────────────────────────────────

pub fn session_summary_to_json(session: SessionSummary) -> Json {
  json.object([
    #("id", json.string(session.id)),
    #("title", json.string(session.title)),
    #("created_at", json.int(session.created_at)),
    #("updated_at", json.int(session.updated_at)),
    #("message_count", json.int(session.message_count)),
    #("agent_id", json.nullable(session.agent_id, json.string)),
  ])
}

pub fn session_summary_decoder() -> Decoder(SessionSummary) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use updated_at <- decode.field("updated_at", decode.int)
  use message_count <- decode.optional_field("message_count", 0, decode.int)
  use agent_id <- decode.optional_field(
    "agent_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(SessionSummary(
    id:,
    title:,
    created_at:,
    updated_at:,
    message_count:,
    agent_id:,
  ))
}

pub fn session_to_json(session: Session) -> Json {
  json.object([
    #("id", json.string(session.id)),
    #("title", json.string(session.title)),
    #("created_at", json.int(session.created_at)),
    #("updated_at", json.int(session.updated_at)),
    #("agent_id", json.nullable(session.agent_id, json.string)),
    #("provider_id", json.nullable(session.provider_id, json.string)),
    #("model_id", json.nullable(session.model_id, json.string)),
    #("params", options_to_json(session.params)),
  ])
}

pub fn session_decoder() -> Decoder(Session) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use updated_at <- decode.field("updated_at", decode.int)
  use agent_id <- decode.optional_field(
    "agent_id",
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
    types.default_options(),
    options_decoder(),
  )
  decode.success(Session(
    id:,
    title:,
    created_at:,
    updated_at:,
    agent_id:,
    provider_id:,
    model_id:,
    params:,
  ))
}

// ─── Сообщения ───────────────────────────────────────────────────────────────

pub fn usage_to_json(usage: Usage) -> Json {
  json.object([
    #("prompt_tokens", json.int(usage.prompt_tokens)),
    #("completion_tokens", json.int(usage.completion_tokens)),
    #("total_tokens", json.int(usage.total_tokens)),
  ])
}

pub fn usage_decoder() -> Decoder(Usage) {
  use prompt_tokens <- decode.optional_field("prompt_tokens", 0, decode.int)
  use completion_tokens <- decode.optional_field(
    "completion_tokens",
    0,
    decode.int,
  )
  use total_tokens <- decode.optional_field("total_tokens", 0, decode.int)
  decode.success(Usage(prompt_tokens:, completion_tokens:, total_tokens:))
}

pub fn role_decoder() -> Decoder(Role) {
  enum_decoder("Role", types.role_from_string, types.User)
}

pub fn status_decoder() -> Decoder(MessageStatus) {
  enum_decoder("MessageStatus", types.status_from_string, types.Done)
}

pub fn message_to_json(message: Message) -> Json {
  json.object([
    #("id", json.string(message.id)),
    #("session_id", json.string(message.session_id)),
    #("seq", json.int(message.seq)),
    #("role", json.string(types.role_to_string(message.role))),
    #("content", json.string(message.content)),
    #("reasoning", json.nullable(message.reasoning, json.string)),
    #("provider_id", json.nullable(message.provider_id, json.string)),
    #("model_id", json.nullable(message.model_id, json.string)),
    #("status", json.string(types.status_to_string(message.status))),
    #("error", json.nullable(message.error, json.string)),
    #("params", json.nullable(message.params, options_to_json)),
    #("hand_edited", json.bool(message.hand_edited)),
    #("raw_request", json.nullable(message.raw_request, json.string)),
    #("raw_response", json.nullable(message.raw_response, json.string)),
    #("http_status", json.nullable(message.http_status, json.int)),
    #("latency_ms", json.nullable(message.latency_ms, json.int)),
    #("usage", json.nullable(message.usage, usage_to_json)),
    #("reply_to", json.nullable(message.reply_to, json.string)),
    #("task_id", json.nullable(message.task_id, json.string)),
    #("step", json.nullable(message.step, json.int)),
    #("tool_calls", json.array(message.tool_calls, tool_call_to_json)),
    #("tool_call_id", json.nullable(message.tool_call_id, json.string)),
    #("created_at", json.int(message.created_at)),
  ])
}

pub fn message_decoder() -> Decoder(Message) {
  use id <- decode.field("id", decode.string)
  use session_id <- decode.field("session_id", decode.string)
  use seq <- decode.field("seq", decode.int)
  use role <- decode.field("role", role_decoder())
  use content <- decode.field("content", decode.string)
  use reasoning <- decode.optional_field(
    "reasoning",
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
  use status <- decode.field("status", status_decoder())
  use error <- decode.optional_field(
    "error",
    None,
    decode.optional(decode.string),
  )
  use params <- decode.optional_field(
    "params",
    None,
    decode.optional(options_decoder()),
  )
  use hand_edited <- decode.optional_field("hand_edited", False, decode.bool)
  use raw_request <- decode.optional_field(
    "raw_request",
    None,
    decode.optional(decode.string),
  )
  use raw_response <- decode.optional_field(
    "raw_response",
    None,
    decode.optional(decode.string),
  )
  use http_status <- decode.optional_field(
    "http_status",
    None,
    decode.optional(decode.int),
  )
  use latency_ms <- decode.optional_field(
    "latency_ms",
    None,
    decode.optional(decode.int),
  )
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder()),
  )
  // optional_field: старые сохранённые тела поля не содержат.
  use reply_to <- decode.optional_field(
    "reply_to",
    None,
    decode.optional(decode.string),
  )
  use task_id <- decode.optional_field(
    "task_id",
    None,
    decode.optional(decode.string),
  )
  use step <- decode.optional_field("step", None, decode.optional(decode.int))
  use tool_calls <- decode.optional_field(
    "tool_calls",
    [],
    decode.list(tool_call_decoder()),
  )
  use tool_call_id <- decode.optional_field(
    "tool_call_id",
    None,
    decode.optional(decode.string),
  )
  use created_at <- decode.field("created_at", decode.int)
  decode.success(Message(
    id:,
    session_id:,
    seq:,
    role:,
    content:,
    reasoning:,
    provider_id:,
    model_id:,
    status:,
    error:,
    params:,
    hand_edited:,
    raw_request:,
    raw_response:,
    http_status:,
    latency_ms:,
    usage:,
    reply_to:,
    task_id:,
    step:,
    tool_calls:,
    tool_call_id:,
    created_at:,
  ))
}

pub fn tool_call_to_json(call: ToolCall) -> Json {
  json.object([
    #("id", json.string(call.id)),
    #("name", json.string(call.name)),
    #("arguments", json.string(call.arguments)),
  ])
}

pub fn tool_call_decoder() -> Decoder(ToolCall) {
  use id <- decode.optional_field("id", "", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use arguments <- decode.optional_field("arguments", "", decode.string)
  decode.success(ToolCall(id:, name:, arguments:))
}

// ─── Ошибка API ──────────────────────────────────────────────────────────────

pub fn error_to_json(code: String, message: String) -> Json {
  json.object([
    #(
      "error",
      json.object([
        #("code", json.string(code)),
        #("message", json.string(message)),
      ]),
    ),
  ])
}

pub type ApiError {
  ApiError(code: String, message: String)
}

pub fn api_error_decoder() -> Decoder(ApiError) {
  use error <- decode.field("error", {
    use code <- decode.optional_field("code", "unknown", decode.string)
    use message <- decode.field("message", decode.string)
    decode.success(ApiError(code:, message:))
  })
  decode.success(error)
}

/// Удобный конструктор для `Option` полей, которые приходят пустой строкой.
pub fn non_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    other -> Some(other)
  }
}
