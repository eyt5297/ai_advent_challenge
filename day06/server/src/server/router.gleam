//// Маршрутизация HTTP-запросов.

import gleam/erlang/process
import gleam/http.{Delete, Get, Patch, Post}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/agent/loop
import server/agent/tools
import server/config
import server/llm/chat
import server/repo/agents
import server/repo/memory as memory_repo
import server/repo/messages
import server/repo/sessions
import server/repo/tasks
import server/web.{type Context}
import shared/api
import shared/catalog
import shared/codec
import shared/types
import simplifile
import wisp.{type Request, type Response}

pub fn handle(request: Request, context: Context) -> Response {
  use request <- web.middleware(request, context)

  case wisp.path_segments(request) {
    [] -> serve_index(context)

    ["api", "health"] -> health(request, context)
    ["api", "catalog"] -> catalog(request, context)

    ["api", "tools"] -> tools_catalog(request)

    ["api", "agents"] -> agents_collection(request, context)
    ["api", "agents", id] -> agent_resource(request, context, id)
    ["api", "agents", id, "sessions"] -> agent_sessions(request, context, id)

    ["api", "tasks", id] -> task_resource(request, context, id)

    ["api", "sessions"] -> sessions_collection(request, context)
    ["api", "sessions", id] -> session_resource(request, context, id)
    ["api", "sessions", id, "messages"] ->
      session_messages(request, context, id)
    ["api", "sessions", session_id, "messages", id] ->
      message_resource(request, context, session_id, id)
    ["api", "sessions", id, "tasks"] -> session_tasks(request, context, id)
    ["api", "sessions", id, "memory"] -> session_memory(request, context, id)
    ["api", "sessions", id, "preview"] -> preview(request, context, id)
    ["api", "sessions", id, "send"] -> send(request, context, id)

    _ -> web.not_found("маршрут не найден")
  }
}

/// SPA: корневой путь отдаёт index.html.
fn serve_index(context: Context) -> Response {
  let path = context.config.static_dir <> "/index.html"
  case simplifile.read(path) {
    Ok(html) ->
      wisp.response(200)
      |> wisp.set_header("content-type", "text/html; charset=utf-8")
      |> wisp.string_body(html)
    Error(_) ->
      web.error(
        503,
        "client_not_built",
        "клиент не собран: нет файла "
          <> path
          <> ". Соберите его командой ./run.sh build",
      )
  }
}

// ─── Служебное ───────────────────────────────────────────────────────────────

fn health(request: Request, context: Context) -> Response {
  use <- wisp.require_method(request, Get)

  let providers =
    list.map(context.config.providers, fn(entry) {
      json.object([
        #("id", json.string(entry.provider.id)),
        #("title", json.string(entry.provider.title)),
        #("base_url", json.string(entry.base_url)),
        // Сам ключ, разумеется, не отдаём — только факт его наличия.
        #("has_key", json.bool(option.is_some(entry.api_key))),
      ])
    })

  web.json_ok(
    json.object([
      #("status", json.string("ok")),
      #("db", json.string("connected")),
      #("providers", json.preprocessed_array(providers)),
    ]),
  )
}

/// Каталог моделей с признаком доступности провайдера.
fn catalog(request: Request, context: Context) -> Response {
  use <- wisp.require_method(request, Get)

  let providers =
    list.map(context.config.providers, fn(entry) {
      types.ProviderStatus(
        provider: entry.provider,
        available: config.is_available(entry),
      )
    })

  api.CatalogResponse(providers:)
  |> api.catalog_response_to_json
  |> web.json_ok
}

// ─── Инструменты ─────────────────────────────────────────────────────────────

/// Каталог инструментов: что вообще можно дать агенту.
///
/// Нужен интерфейсу, чтобы показать список с описаниями, и полезен при
/// отладке — видно ровно то, что уйдёт модели.
fn tools_catalog(request: Request) -> Response {
  use <- wisp.require_method(request, Get)

  web.json_ok(
    json.object([
      #(
        "tools",
        json.array(tools.registry(), fn(tool) {
          json.object([
            #("id", json.string(tool.id)),
            #("description", json.string(tool.description)),
            #("parameters", tool.parameters),
          ])
        }),
      ),
    ]),
  )
}

// ─── Агенты ──────────────────────────────────────────────────────────────────

fn agents_collection(request: Request, context: Context) -> Response {
  case request.method {
    Get -> list_agents(context)
    Post -> create_agent(request, context)
    _ -> wisp.method_not_allowed([Get, Post])
  }
}

fn list_agents(context: Context) -> Response {
  case agents.list(context.db) {
    Ok(items) ->
      web.json_ok(
        json.object([
          #("agents", json.array(items, codec.agent_summary_to_json)),
        ]),
      )
    Error(error) -> agent_repo_error(error)
  }
}

fn create_agent(request: Request, context: Context) -> Response {
  use payload <- web.require_decoded(
    request,
    api.create_agent_request_decoder(),
  )
  use name <- require_agent_name(payload.name)
  use Nil <- require_known_model(payload.provider_id, payload.model_id)
  use max_steps <- require_step_limit(payload.max_steps)
  use Nil <- require_known_tools(payload.tools)

  let draft =
    agents.NewAgent(
      name:,
      description: payload.description,
      system_prompt: payload.system_prompt,
      provider_id: payload.provider_id,
      model_id: payload.model_id,
      params: payload.params,
      max_steps:,
      tools: payload.tools,
      memory: payload.memory,
    )

  case agents.create(context.db, draft) {
    Ok(agent) -> web.json_created(codec.agent_to_json(agent))
    Error(error) -> agent_repo_error(error)
  }
}

fn agent_resource(request: Request, context: Context, id: String) -> Response {
  case request.method {
    Get -> get_agent(context, id)
    Patch -> update_agent(request, context, id)
    Delete -> delete_agent(context, id)
    _ -> wisp.method_not_allowed([Get, Patch, Delete])
  }
}

fn get_agent(context: Context, id: String) -> Response {
  case agents.get(context.db, id) {
    Ok(agent) -> web.json_ok(codec.agent_to_json(agent))
    Error(error) -> agent_repo_error(error)
  }
}

fn update_agent(request: Request, context: Context, id: String) -> Response {
  use payload <- web.require_decoded(
    request,
    api.update_agent_request_decoder(),
  )
  use existing <- with_agent(context, id)

  // Провайдер и модель проверяются вместе: сменить можно только один из
  // них, и пара должна остаться существующей.
  let provider_id = option.unwrap(payload.provider_id, existing.provider_id)
  let model_id = option.unwrap(payload.model_id, existing.model_id)
  use Nil <- require_known_model(provider_id, model_id)

  use max_steps <- require_optional_step_limit(payload.max_steps)
  use Nil <- require_known_tools(option.unwrap(payload.tools, []))

  case
    agents.update(
      context.db,
      id,
      option.map(payload.name, string.trim),
      payload.description,
      payload.system_prompt,
      payload.provider_id,
      payload.model_id,
      payload.params,
      max_steps,
      payload.tools,
      payload.memory,
    )
  {
    Ok(agent) -> web.json_ok(codec.agent_to_json(agent))
    Error(error) -> agent_repo_error(error)
  }
}

fn delete_agent(context: Context, id: String) -> Response {
  case agents.delete(context.db, id) {
    Ok(Nil) -> web.no_content()
    Error(error) -> agent_repo_error(error)
  }
}

/// Запуски агента: список и создание нового экземпляра.
fn agent_sessions(request: Request, context: Context, id: String) -> Response {
  case request.method {
    Get -> list_agent_sessions(context, id)
    Post -> start_agent_session(request, context, id)
    _ -> wisp.method_not_allowed([Get, Post])
  }
}

fn list_agent_sessions(context: Context, id: String) -> Response {
  use _agent <- with_agent(context, id)

  case sessions.list_for_agent(context.db, id) {
    Ok(items) ->
      web.json_ok(
        json.object([
          #("sessions", json.array(items, codec.session_summary_to_json)),
        ]),
      )
    Error(error) -> session_repo_error(error)
  }
}

/// Создаёт сессию-экземпляр: провайдер и модель копируются из агента,
/// чтобы запуск работал даже если агента потом перенастроят.
fn start_agent_session(
  request: Request,
  context: Context,
  id: String,
) -> Response {
  use payload <- web.require_decoded(
    request,
    api.start_session_request_decoder(),
  )
  use agent <- with_agent(context, id)

  case
    sessions.create_for_agent(
      context.db,
      Some(agent.id),
      Some(option.unwrap(payload.title, agent.name)),
      Some(agent.provider_id),
      Some(agent.model_id),
    )
  {
    Ok(session) -> web.json_created(codec.session_to_json(session))
    Error(error) -> session_repo_error(error)
  }
}

// ─── Задания ─────────────────────────────────────────────────────────────────

/// Что агент помнит об этом запуске: факты, пересказ и расход токенов.
///
/// Один эндпоинт, а не три: всё это показывается вместе, одной панелью,
/// и три запроса ради одной панели — лишняя суета.
fn session_memory(request: Request, context: Context, id: String) -> Response {
  use <- wisp.require_method(request, Get)
  use _session <- with_session(context, id)

  let facts =
    memory_repo.list_facts(context.db, id)
    |> result.unwrap([])

  let summary = case memory_repo.latest_summary(context.db, id) {
    Ok(summary) -> Some(summary)
    Error(_) -> None
  }

  let usage = token_usage(context, id)

  web.json_ok(
    json.object([
      #("facts", json.array(facts, codec.fact_to_json)),
      #("summary", json.nullable(summary, codec.summary_to_json)),
      #("usage", usage),
    ]),
  )
}

/// Расход токенов по сессии.
///
/// Суммируется `usage` провайдера — это точные числа, а не оценка.
/// Шаги без `usage` (вызовы инструментов, неудачные запросы) просто не
/// вносят вклад.
fn token_usage(context: Context, session_id: String) -> json.Json {
  let rows =
    messages.list_for_session(context.db, session_id)
    |> result.unwrap([])

  let #(prompt, completion) =
    list.fold(rows, #(0, 0), fn(totals, message) {
      case message.usage {
        None -> totals
        Some(usage) -> #(
          totals.0 + usage.prompt_tokens,
          totals.1 + usage.completion_tokens,
        )
      }
    })

  json.object([
    #("prompt_tokens", json.int(prompt)),
    #("completion_tokens", json.int(completion)),
    #("total_tokens", json.int(prompt + completion)),
    #("exchanges", json.int(list.length(list.filter(rows, has_usage)))),
  ])
}

fn has_usage(message: types.Message) -> Bool {
  option.is_some(message.usage)
}

fn session_tasks(request: Request, context: Context, id: String) -> Response {
  case request.method {
    Get -> list_tasks(context, id)
    Post -> create_task(request, context, id)
    _ -> wisp.method_not_allowed([Get, Post])
  }
}

fn list_tasks(context: Context, id: String) -> Response {
  use _session <- with_session(context, id)

  case tasks.list_for_session(context.db, id) {
    Ok(items) ->
      web.json_ok(
        json.object([#("tasks", json.array(items, codec.task_to_json))]),
      )
    Error(error) -> task_repo_error(error)
  }
}

/// Выдаёт задание агенту.
///
/// `?async=true` возвращает `202` сразу, не дожидаясь конца работы: ход
/// читается через `GET /api/tasks/:id`. Синхронный режим оставлен
/// основным, потому что на нём держится текущий интерфейс.
fn create_task(request: Request, context: Context, id: String) -> Response {
  use payload <- web.require_decoded(request, api.create_task_request_decoder())
  use session <- with_session(context, id)
  use agent <- with_session_agent(context, session)

  case wisp.get_query(request) |> list.key_find("async") {
    Ok("true") -> start_task_async(context, agent, session, payload.prompt)
    _ -> run_task_sync(context, agent, session, payload.prompt)
  }
}

fn run_task_sync(
  context: Context,
  agent: types.Agent,
  session: types.Session,
  prompt: String,
) -> Response {
  case loop.start_and_run(context.db, context.config, agent, session, prompt) {
    Error(error) -> task_error(error)
    Ok(task) -> web.json_ok(task_with_steps(context, task))
  }
}

/// Асинхронный режим: задание создаётся синхронно, чтобы сразу вернуть id
/// и отловить «уже выполняется», а цикл уходит в отдельный процесс.
///
/// Состояние при этом живёт в БД, а не в процессе (SPEC_AGENTS.md, п. 10.2):
/// поэтому ход работы виден любому каналу, а не только тому, кто запустил.
fn start_task_async(
  context: Context,
  agent: types.Agent,
  session: types.Session,
  prompt: String,
) -> Response {
  case loop.start(context.db, session, prompt) {
    Error(error) -> task_error(error)
    Ok(task) -> {
      let _pid =
        process.spawn_unlinked(fn() {
          loop.run(context.db, context.config, agent, session, task)
        })

      web.json_response(
        202,
        json.object([
          #("task", codec.task_to_json(task)),
          #("messages", json.preprocessed_array([])),
        ]),
      )
    }
  }
}

/// Задание вместе с шагами: в одном ответе всё, что нужно ленте.
fn task_with_steps(context: Context, task: types.Task) -> json.Json {
  let steps = messages.list_for_task(context.db, task.id) |> result.unwrap([])

  json.object([
    #("task", codec.task_to_json(task)),
    #("messages", json.array(steps, codec.message_to_json)),
  ])
}

fn with_session_agent(
  context: Context,
  session: types.Session,
  next: fn(types.Agent) -> Response,
) -> Response {
  case session.agent_id {
    None -> task_error(loop.NoAgent)
    Some(agent_id) -> {
      use agent <- with_agent(context, agent_id)
      next(agent)
    }
  }
}

fn task_error(error: loop.TaskError) -> Response {
  web.error(
    loop.http_status(error),
    loop.error_code(error),
    loop.describe(error),
  )
}

fn task_resource(request: Request, context: Context, id: String) -> Response {
  case request.method {
    Get -> get_task(context, id)
    Delete -> delete_task(context, id)
    _ -> wisp.method_not_allowed([Get, Delete])
  }
}

/// Задание вместе с его шагами — то, что рисуется раскрытой карточкой.
fn get_task(context: Context, id: String) -> Response {
  case tasks.get(context.db, id) {
    Error(error) -> task_repo_error(error)
    Ok(task) ->
      case messages.list_for_task(context.db, id) {
        Ok(steps) ->
          web.json_ok(
            json.object([
              #("task", codec.task_to_json(task)),
              #("messages", json.array(steps, codec.message_to_json)),
            ]),
          )
        Error(error) -> message_repo_error(error)
      }
  }
}

fn delete_task(context: Context, id: String) -> Response {
  case tasks.delete(context.db, id) {
    Ok(Nil) -> web.no_content()
    Error(error) -> task_repo_error(error)
  }
}

// ─── Проверки входных данных агента ──────────────────────────────────────────

fn require_agent_name(raw: String, next: fn(String) -> Response) -> Response {
  case string.trim(raw) {
    "" -> web.error(400, "empty_name", "имя агента не может быть пустым")
    name -> next(name)
  }
}

/// Пара «провайдер + модель» должна существовать в каталоге.
///
/// Проверяем при сохранении, а не при запуске: иначе агент создавался бы
/// успешно и ломался потом, когда связь с ошибкой уже не очевидна.
fn require_known_model(
  provider_id: String,
  model_id: String,
  next: fn(Nil) -> Response,
) -> Response {
  case types.find_provider(catalog.providers(), provider_id) {
    Error(Nil) ->
      web.error(
        400,
        "unknown_provider",
        "провайдер " <> provider_id <> " не найден",
      )
    Ok(provider) ->
      case types.find_model(provider, model_id) {
        Error(Nil) ->
          web.error(
            400,
            "unknown_model",
            "модель " <> model_id <> " не найдена у провайдера " <> provider_id,
          )
        Ok(_model) -> next(Nil)
      }
  }
}

/// Верхняя граница шагов — защита от зацикливания агента.
const max_step_limit = 50

fn require_step_limit(value: Int, next: fn(Int) -> Response) -> Response {
  case value >= 1 && value <= max_step_limit {
    True -> next(value)
    False ->
      web.error(
        400,
        "invalid_max_steps",
        "max_steps должен быть от 1 до " <> int.to_string(max_step_limit),
      )
  }
}

fn require_optional_step_limit(
  value: Option(Int),
  next: fn(Option(Int)) -> Response,
) -> Response {
  case value {
    None -> next(None)
    Some(steps) -> require_step_limit(steps, fn(valid) { next(Some(valid)) })
  }
}

/// Инструменты проверяются при сохранении агента.
///
/// Молча отбрасывать неизвестные нельзя: пользователь будет думать, что
/// инструмент подключён, и не поймёт, почему агент им не пользуется.
fn require_known_tools(
  ids: List(String),
  next: fn(Nil) -> Response,
) -> Response {
  case tools.unknown_ids(ids) {
    [] -> next(Nil)
    unknown ->
      web.error(
        400,
        "unknown_tool",
        "неизвестные инструменты: " <> string.join(unknown, ", "),
      )
  }
}

fn with_agent(
  context: Context,
  id: String,
  next: fn(types.Agent) -> Response,
) -> Response {
  case agents.get(context.db, id) {
    Ok(agent) -> next(agent)
    Error(agents.NotFound) -> web.not_found("агент " <> id <> " не найден")
    Error(error) -> agent_repo_error(error)
  }
}

// ─── Сессии ──────────────────────────────────────────────────────────────────

fn sessions_collection(request: Request, context: Context) -> Response {
  case request.method {
    Get -> list_sessions(context)
    Post -> create_session(request, context)
    _ -> wisp.method_not_allowed([Get, Post])
  }
}

fn list_sessions(context: Context) -> Response {
  case sessions.list(context.db) {
    Ok(items) ->
      web.json_ok(
        json.object([
          #("sessions", json.array(items, codec.session_summary_to_json)),
        ]),
      )
    Error(error) -> session_repo_error(error)
  }
}

fn create_session(request: Request, context: Context) -> Response {
  use payload <- web.require_decoded(
    request,
    api.create_session_request_decoder(),
  )

  // Новая сессия наследует провайдера и модель по умолчанию, чтобы
  // выпадающие списки не были пустыми.
  let #(provider_id, model_id) = default_selection()

  case sessions.create(context.db, payload.title, provider_id, model_id) {
    Ok(session) -> web.json_created(codec.session_to_json(session))
    Error(error) -> session_repo_error(error)
  }
}

fn default_selection() -> #(Option(String), Option(String)) {
  case catalog.default_provider() {
    Ok(provider) -> #(Some(provider.id), Some(provider.default_model))
    Error(Nil) -> #(None, None)
  }
}

fn session_resource(
  request: Request,
  context: Context,
  id: String,
) -> Response {
  case request.method {
    Get -> get_session(context, id)
    Patch -> update_session(request, context, id)
    Delete -> delete_session(context, id)
    _ -> wisp.method_not_allowed([Get, Patch, Delete])
  }
}

fn get_session(context: Context, id: String) -> Response {
  case sessions.get(context.db, id) {
    Ok(session) -> web.json_ok(codec.session_to_json(session))
    Error(error) -> session_repo_error(error)
  }
}

fn update_session(request: Request, context: Context, id: String) -> Response {
  use payload <- web.require_decoded(
    request,
    api.update_session_request_decoder(),
  )

  case
    sessions.update(
      context.db,
      id,
      payload.title,
      payload.provider_id,
      payload.model_id,
      payload.params,
    )
  {
    Ok(session) -> web.json_ok(codec.session_to_json(session))
    Error(error) -> session_repo_error(error)
  }
}

fn delete_session(context: Context, id: String) -> Response {
  case sessions.delete(context.db, id) {
    Ok(Nil) -> web.no_content()
    Error(error) -> session_repo_error(error)
  }
}

fn session_messages(
  request: Request,
  context: Context,
  id: String,
) -> Response {
  use <- wisp.require_method(request, Get)
  // Без этой проверки запрос к несуществующей сессии отдавал бы пустой
  // список вместо 404, и клиент молча показывал бы пустой диалог.
  use _session <- with_session(context, id)

  case messages.list_for_session(context.db, id) {
    Ok(items) ->
      web.json_ok(
        json.object([#("messages", json.array(items, codec.message_to_json))]),
      )
    Error(error) -> message_repo_error(error)
  }
}

fn message_resource(
  request: Request,
  context: Context,
  session_id: String,
  id: String,
) -> Response {
  case request.method {
    Delete -> delete_message(context, session_id, id)
    _ -> wisp.method_not_allowed([Delete])
  }
}

/// Удаляет сообщение вместе с его парой: вопрос без ответа (или наоборот)
/// в диалоге бесполезен.
fn delete_message(
  context: Context,
  session_id: String,
  id: String,
) -> Response {
  use _session <- with_session(context, session_id)

  case messages.delete_exchange(context.db, id) {
    Ok(deleted) -> {
      let _ = sessions.touch(context.db, session_id)
      web.json_ok(json.object([#("deleted", json.array(deleted, json.string))]))
    }
    Error(error) -> message_repo_error(error)
  }
}

// ─── Preview и Send ──────────────────────────────────────────────────────────

/// Собирает тело запроса, ничего не отправляя. Работает и без ключа —
/// посмотреть будущий JSON полезно в любом случае.
fn preview(request: Request, context: Context, id: String) -> Response {
  use <- wisp.require_method(request, Post)
  use payload <- web.require_decoded(request, api.send_request_decoder())
  use _session <- with_session(context, id)

  case prepare(context, payload) {
    Error(error) -> chat_error(error)
    Ok(prepared) ->
      api.PreviewResponse(
        raw_request: prepared.body,
        effective_params: prepared.effective_params,
        warnings: prepared.warnings,
      )
      |> api.preview_response_to_json
      |> web.json_ok
  }
}

fn send(request: Request, context: Context, id: String) -> Response {
  use <- wisp.require_method(request, Post)
  use payload <- web.require_decoded(request, api.send_request_decoder())
  use session <- with_session(context, id)

  let outcome = {
    use prepared <- result.try(prepare(context, payload))
    use _ <- result.try(chat.require_available(prepared.entry))
    chat.send(
      context.db,
      context.config,
      session,
      prepared,
      Some(payload.content),
      // Ручная отправка: вне заданий агента.
      chat.Standalone,
    )
  }

  case outcome {
    Error(error) -> chat_error(error)
    Ok(exchange) ->
      api.SendResponse(
        user: exchange.user,
        assistant: exchange.assistant,
        warnings: exchange.warnings,
      )
      |> api.send_response_to_json
      |> web.json_ok
  }
}

fn prepare(
  context: Context,
  payload: api.SendRequest,
) -> Result(chat.Prepared, chat.ChatError) {
  chat.prepare(
    context.config,
    payload.provider_id,
    payload.model_id,
    Some(payload.content),
    payload.params,
    payload.raw_request_override,
    // Режим «запрос-ответ»: история намеренно не передаётся.
    [],
    // Инструменты — свойство агента; ручная отправка идёт без них.
    [],
  )
}

/// Общая проверка существования сессии перед работой с ней.
fn with_session(
  context: Context,
  id: String,
  next: fn(types.Session) -> Response,
) -> Response {
  case sessions.get(context.db, id) {
    Ok(session) -> next(session)
    Error(sessions.NotFound) -> web.not_found("сессия " <> id <> " не найдена")
    Error(error) -> session_repo_error(error)
  }
}

// ─── Ошибки ──────────────────────────────────────────────────────────────────

fn chat_error(error: chat.ChatError) -> Response {
  web.error(
    chat.http_status(error),
    chat.error_code(error),
    chat.describe(error),
  )
}

fn session_repo_error(error: sessions.RepoError) -> Response {
  case error {
    sessions.NotFound -> web.not_found("сессия не найдена")
    sessions.Sql(sql) -> web.server_error(string.inspect(sql))
  }
}

fn message_repo_error(error: messages.RepoError) -> Response {
  case error {
    messages.NotFound -> web.not_found("сообщение не найдено")
    messages.BelongsToTask(task_id) ->
      web.error(
        409,
        "message_belongs_to_task",
        "это шаг задания "
          <> task_id
          <> "; шаги связаны историей, удалить можно только задание целиком",
      )
    messages.Sql(sql) -> web.server_error(string.inspect(sql))
  }
}

fn agent_repo_error(error: agents.RepoError) -> Response {
  case error {
    agents.NotFound -> web.not_found("агент не найден")
    // 409, а не каскадное удаление: за агентом стоит история запусков.
    agents.InUse(count) ->
      web.error(
        409,
        "agent_in_use",
        "у агента есть запуски ("
          <> int.to_string(count)
          <> "); удалите их, если действительно хотите убрать агента",
      )
    agents.Sql(sql) -> web.server_error(string.inspect(sql))
  }
}

fn task_repo_error(error: tasks.RepoError) -> Response {
  case error {
    tasks.NotFound -> web.not_found("задание не найдено")
    // Задания одной сессии выполняются последовательно: параллельные
    // дали бы агенту чересполосицу в истории шагов.
    tasks.AlreadyRunning(id) ->
      web.error(
        409,
        "task_already_running",
        "в сессии уже выполняется задание " <> id,
      )
    tasks.Sql(sql) -> web.server_error(string.inspect(sql))
  }
}
