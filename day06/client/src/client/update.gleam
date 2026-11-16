//// Обработка сообщений: вся логика переходов состояния.

import client/api
import client/dom
import client/model.{type Model, type Msg, Agents, JsonEditor, Model, Rename}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lustre/effect.{type Effect}
import rsvp
import shared/api as dto
import shared/types.{type RequestOptions}

pub fn init(_flags) -> #(Model, Effect(Msg)) {
  #(
    model.init_model(),
    effect.batch([
      api.load_catalog(model.CatalogLoaded),
      api.load_sessions(model.SessionsLoaded),
    ]),
  )
}

pub fn update(current: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // ─── Загрузка ────────────────────────────────────────────────────────────
    model.CatalogLoaded(Ok(response)) -> catalog_loaded(current, response)
    model.CatalogLoaded(Error(error)) -> fail(current, error)

    model.SessionsLoaded(Ok(sessions)) -> sessions_loaded(current, sessions)
    model.SessionsLoaded(Error(error)) -> fail(current, error)

    model.MessagesLoaded(Ok(messages)) -> #(
      Model(..current, messages:, loading: False),
      dom.scroll_dialog_to_bottom(),
    )
    model.MessagesLoaded(Error(error)) -> fail(current, error)

    model.SessionLoaded(Ok(session)) -> session_loaded(current, session)
    model.SessionLoaded(Error(error)) -> fail(current, error)

    model.TasksLoaded(Ok(tasks)) -> #(Model(..current, tasks:), effect.none())
    // Молча проглатывать нельзя: без заданий лента агентской сессии
    // окажется пустой, и причина будет неочевидна.
    model.TasksLoaded(Error(error)) -> #(
      Model(..current, tasks: [], error: Some(api.describe_error(error))),
      effect.none(),
    )

    // Задание выполнено: карточка и её шаги приходят одним ответом.
    //
    // Те же данные мог принести и поток событий, поэтому слияние идёт по
    // `id`, а не добавлением: иначе лента удвоилась бы.
    model.TaskCompleted(Ok(response)) -> #(
      Model(
        ..merge_task(current, response.task),
        messages: merge_messages(current.messages, response.messages),
        draft: "",
        sending: False,
        json_editor: None,
      ),
      effect.batch([
        dom.scroll_dialog_to_bottom(),
        dom.auto_resize(composer_id),
        api.load_sessions(model.SessionsLoaded),
        // Задание могло добавить фактов и наверняка добавило токенов.
        case current.active {
          Some(id) -> api.load_memory(id, model.MemoryLoaded)
          None -> effect.none()
        },
      ]),
    )

    // ─── Агенты ──────────────────────────────────────────────────────────────
    model.AgentsOpened -> #(
      Model(..current, agents: Agents(..current.agents, open: True)),
      // Список агентов может измениться между открытиями, каталог
      // инструментов — нет, но второй запрос дешевле ветвления.
      effect.batch([
        api.load_agents(model.AgentsLoaded),
        api.load_tools(model.ToolsLoaded),
      ]),
    )

    model.AgentsClosed -> #(
      Model(
        ..current,
        agents: Agents(..current.agents, open: False, form: None),
        error: None,
      ),
      effect.none(),
    )

    model.AgentsLoaded(Ok(list)) -> #(
      Model(..current, agents: Agents(..current.agents, list:)),
      effect.none(),
    )
    model.AgentsLoaded(Error(error)) -> fail(current, error)

    model.ToolsLoaded(Ok(tools)) -> #(
      Model(..current, agents: Agents(..current.agents, tools:)),
      effect.none(),
    )
    model.ToolsLoaded(Error(error)) -> fail(current, error)

    model.AgentCreateClicked -> #(
      Model(
        ..current,
        error: None,
        agents: Agents(
          ..current.agents,
          form: Some(model.blank_agent_form(
            current.provider_id,
            current.model_id,
          )),
        ),
      ),
      effect.none(),
    )

    // Список не содержит промпта и параметров — за ними отдельный запрос.
    model.AgentEditClicked(id) -> #(
      Model(..current, error: None),
      api.load_agent(id, model.AgentLoaded),
    )

    model.AgentLoaded(Ok(agent)) -> #(
      Model(
        ..current,
        agents: Agents(..current.agents, form: Some(model.agent_form_of(agent))),
      ),
      effect.none(),
    )
    model.AgentLoaded(Error(error)) -> fail(current, error)

    model.AgentFormCancelled -> #(
      Model(
        ..current,
        error: None,
        agents: Agents(..current.agents, form: None),
      ),
      effect.none(),
    )

    model.AgentNameChanged(value) ->
      edit_form(current, fn(form) { model.AgentForm(..form, name: value) })
    model.AgentDescriptionChanged(value) ->
      edit_form(current, fn(form) {
        model.AgentForm(..form, description: value)
      })
    model.AgentPromptChanged(value) ->
      edit_form(current, fn(form) {
        model.AgentForm(..form, system_prompt: value)
      })
    model.AgentMaxStepsChanged(value) ->
      edit_form(current, fn(form) { model.AgentForm(..form, max_steps: value) })

    // Смена провайдера перевыбирает модель: прежняя у нового провайдера
    // почти наверняка отсутствует.
    model.AgentProviderChanged(value) ->
      edit_form(current, fn(form) {
        model.AgentForm(
          ..form,
          provider_id: value,
          model_id: default_model_of(current, value),
        )
      })
    model.AgentModelChanged(value) ->
      edit_form(current, fn(form) { model.AgentForm(..form, model_id: value) })

    model.AgentToolToggled(id) ->
      edit_form(current, fn(form) {
        model.AgentForm(..form, tools: toggle(form.tools, id))
      })

    model.AgentFormSubmitted -> submit_agent(current)

    model.AgentSaved(Ok(_)) -> #(
      Model(
        ..current,
        agents: Agents(..current.agents, form: None, saving: False),
      ),
      api.load_agents(model.AgentsLoaded),
    )
    model.AgentSaved(Error(error)) -> #(
      Model(
        ..current,
        agents: Agents(..current.agents, saving: False),
        error: Some(api.describe_error(error)),
      ),
      effect.none(),
    )

    model.AgentDeleteClicked(id) -> #(
      Model(..current, error: None),
      api.delete_agent(id, fn(result) { model.AgentDeleted(id, result) }),
    )

    model.AgentDeleted(_, Ok(Nil)) -> #(
      current,
      api.load_agents(model.AgentsLoaded),
    )
    // Чаще всего это 409: у агента есть запуски. Сообщение сервера
    // понятнее любого, что мы придумали бы здесь.
    model.AgentDeleted(_, Error(error)) -> fail(current, error)

    model.AgentRunClicked(id) -> #(
      Model(..current, error: None),
      api.start_agent_session(id, model.AgentSessionStarted),
    )

    // Запуск создан — закрываем экран и открываем новую сессию.
    model.AgentSessionStarted(Ok(session)) -> #(
      Model(
        ..current,
        agents: Agents(..current.agents, open: False, form: None),
        active: Some(session.id),
        messages: [],
        tasks: [],
        agent_id: session.agent_id,
        draft: "",
        json_editor: None,
        warnings: [],
      ),
      effect.batch([
        api.load_sessions(model.SessionsLoaded),
        api.load_session(session.id, model.SessionLoaded),
        dom.open_event_stream(session.id, model.StreamEvent),
        dom.focus(composer_id),
      ]),
    )
    model.AgentSessionStarted(Error(error)) -> fail(current, error)

    // ─── Память сессии ───────────────────────────────────────────────────────
    model.MemoryLoaded(Ok(memory)) -> #(
      Model(..current, memory: Some(memory)),
      effect.none(),
    )
    // Молча: панель памяти — справка, а не действие пользователя.
    // Баннер об ошибке здесь только мешал бы.
    model.MemoryLoaded(Error(_)) -> #(
      Model(..current, memory: None),
      effect.none(),
    )

    model.MemoryPanelToggled -> #(
      Model(..current, memory_open: !current.memory_open),
      effect.none(),
    )

    model.AgentMemoryWindowChanged(value) ->
      edit_form(current, fn(form) {
        model.AgentForm(..form, memory_window: value)
      })
    model.AgentMemoryTasksChanged(value) ->
      edit_form(current, fn(form) {
        model.AgentForm(..form, memory_tasks: value)
      })
    model.AgentMemorySummaryChanged(value) ->
      edit_form(current, fn(form) {
        model.AgentForm(..form, memory_summary_every: value)
      })
    model.AgentMemoryFactsToggled ->
      edit_form(current, fn(form) {
        model.AgentForm(..form, memory_facts: !form.memory_facts)
      })
    model.AgentMemoryBudgetChanged(value) ->
      edit_form(current, fn(form) {
        model.AgentForm(..form, memory_budget: value)
      })

    // ─── Поток событий ───────────────────────────────────────────────────────
    model.StreamEvent(name:, payload:) -> stream_event(current, name, payload)

    model.TaskCompleted(Error(error)) -> #(
      Model(..current, sending: False, error: Some(api.describe_error(error))),
      effect.none(),
    )

    model.TaskDeleteClicked(id) -> #(
      Model(..current, error: None),
      api.delete_task(id, fn(result) { model.TaskDeleted(id, result) }),
    )

    // Удаляем задание и его шаги из состояния, не перезагружая сессию.
    model.TaskDeleted(id, Ok(Nil)) -> #(
      Model(
        ..current,
        tasks: list.filter(current.tasks, fn(task) { task.id != id }),
        messages: list.filter(current.messages, fn(message) {
          message.task_id != Some(id)
        }),
      ),
      api.load_sessions(model.SessionsLoaded),
    )
    model.TaskDeleted(_, Error(error)) -> fail(current, error)

    model.TaskExpandToggled(id) -> #(
      Model(..current, expanded_tasks: model.toggle(current.expanded_tasks, id)),
      effect.none(),
    )

    // ─── Сессии ──────────────────────────────────────────────────────────────
    model.NewSessionClicked -> #(
      Model(..current, error: None),
      api.create_session(None, model.SessionCreated),
    )

    model.SessionCreated(Ok(session)) -> #(
      Model(
        ..current,
        active: Some(session.id),
        messages: [],
        tasks: [],
        agent_id: None,
        draft: "",
        json_editor: None,
        warnings: [],
      ),
      effect.batch([
        api.load_sessions(model.SessionsLoaded),
        dom.focus(composer_id),
        dom.open_event_stream(session.id, model.StreamEvent),
      ]),
    )
    model.SessionCreated(Error(error)) -> fail(current, error)

    model.SessionSelected(id) ->
      case current.active == Some(id) {
        True -> #(current, effect.none())
        False -> #(
          Model(
            ..current,
            active: Some(id),
            messages: [],
            tasks: [],
            agent_id: None,
            json_editor: None,
            warnings: [],
            error: None,
            loading: True,
          ),
          effect.batch([
            // Сессия помнит выбранную модель и параметры — подтягиваем их.
            api.load_session(id, model.SessionLoaded),
            api.load_messages(id, model.MessagesLoaded),
            api.load_tasks(id, model.TasksLoaded),
            api.load_memory(id, model.MemoryLoaded),
            // Поток даёт изменения, загрузка выше — состояние. Одно без
            // другого неполно.
            dom.open_event_stream(id, model.StreamEvent),
          ]),
        )
      }

    model.SessionDeleteClicked(id) -> #(
      current,
      api.delete_session(id, fn(result) { model.SessionDeleted(id, result) }),
    )

    model.SessionDeleted(id, Ok(Nil)) -> {
      let active = case current.active == Some(id) {
        True -> None
        False -> current.active
      }
      let messages = case current.active == Some(id) {
        True -> []
        False -> current.messages
      }
      // Оставленный поток слал бы события удалённой сессии.
      let closing = case current.active == Some(id) {
        True -> dom.close_event_stream()
        False -> effect.none()
      }

      #(
        Model(..current, active:, messages:),
        effect.batch([api.load_sessions(model.SessionsLoaded), closing]),
      )
    }
    model.SessionDeleted(_, Error(error)) -> fail(current, error)

    model.RenameStarted(id, title) -> #(
      Model(..current, renaming: Some(Rename(id, title))),
      dom.focus(rename_id),
    )

    model.RenameChanged(title) -> #(
      Model(
        ..current,
        renaming: option.map(current.renaming, fn(rename) {
          Rename(..rename, title:)
        }),
      ),
      effect.none(),
    )

    model.RenameSubmitted ->
      case current.renaming {
        None -> #(current, effect.none())
        Some(rename) ->
          case string.trim(rename.title) {
            "" -> #(Model(..current, renaming: None), effect.none())
            title -> #(
              Model(..current, renaming: None),
              api.update_session(
                rename.session_id,
                Some(title),
                None,
                None,
                None,
                model.SessionUpdated,
              ),
            )
          }
      }

    model.RenameCancelled -> #(Model(..current, renaming: None), effect.none())

    model.SessionUpdated(Ok(_)) -> #(
      current,
      api.load_sessions(model.SessionsLoaded),
    )
    model.SessionUpdated(Error(error)) -> fail(current, error)

    // ─── Выбор модели ────────────────────────────────────────────────────────
    model.ProviderChanged(provider_id) -> provider_changed(current, provider_id)
    model.ModelChanged(model_id) -> model_changed(current, model_id)

    // ─── Параметры ───────────────────────────────────────────────────────────
    model.ParamsToggled -> #(
      Model(..current, params_open: !current.params_open),
      effect.none(),
    )

    model.TemperatureToggled(on) ->
      set_params(current, fn(params) {
        types.RequestOptions(..params, temperature: case on {
          True -> Some(0.7)
          False -> None
        })
      })

    model.TemperatureChanged(raw) ->
      set_params(current, fn(params) {
        case float.parse(raw) {
          Ok(value) -> types.RequestOptions(..params, temperature: Some(value))
          // Целое число приходит без точки — float.parse такое не берёт.
          Error(Nil) ->
            case int.parse(raw) {
              Ok(value) ->
                types.RequestOptions(
                  ..params,
                  temperature: Some(int.to_float(value)),
                )
              Error(Nil) -> params
            }
        }
      })

    model.MaxTokensToggled(on) ->
      set_params(current, fn(params) {
        types.RequestOptions(..params, max_tokens: case on {
          True -> Some(default_max_tokens(current))
          False -> None
        })
      })

    model.MaxTokensChanged(raw) ->
      set_params(current, fn(params) {
        case int.parse(raw) {
          Ok(value) -> types.RequestOptions(..params, max_tokens: Some(value))
          Error(Nil) -> params
        }
      })

    model.SystemPromptToggled(on) ->
      set_params(current, fn(params) {
        types.RequestOptions(..params, system_prompt: case on {
          True -> Some("")
          False -> None
        })
      })

    model.SystemPromptChanged(text) ->
      set_params(current, fn(params) {
        types.RequestOptions(..params, system_prompt: Some(text))
      })

    model.ReasoningToggled(on) ->
      set_params(current, fn(params) {
        case on {
          True -> {
            let effort =
              model.current_model(current)
              |> option.then(types.default_effort)
            types.RequestOptions(
              ..params,
              reasoning_enabled: Some(True),
              reasoning_effort: effort,
            )
          }
          False ->
            types.RequestOptions(
              ..params,
              reasoning_enabled: None,
              reasoning_effort: None,
            )
        }
      })

    model.ReasoningEnabledChanged(enabled) ->
      set_params(current, fn(params) {
        types.RequestOptions(..params, reasoning_enabled: Some(enabled))
      })

    model.EffortChanged(effort) ->
      set_params(current, fn(params) {
        types.RequestOptions(..params, reasoning_effort: Some(effort))
      })

    model.ParamsReset -> set_params(current, fn(_) { types.default_options() })

    // ─── Ввод и отправка ─────────────────────────────────────────────────────
    model.DraftChanged(draft) -> #(
      Model(..current, draft:),
      dom.auto_resize(composer_id),
    )

    model.SendClicked -> send(current)

    model.SendCompleted(Ok(response)) -> #(
      Model(
        ..current,
        messages: list.append(current.messages, [
          response.user,
          response.assistant,
        ]),
        draft: "",
        sending: False,
        warnings: response.warnings,
        // После отправки редактор сбрасывается: следующий запрос снова
        // собирается из параметров.
        json_editor: None,
      ),
      effect.batch([
        dom.scroll_dialog_to_bottom(),
        dom.auto_resize(composer_id),
        api.load_sessions(model.SessionsLoaded),
        // Задание могло добавить фактов и наверняка добавило токенов.
        case current.active {
          Some(id) -> api.load_memory(id, model.MemoryLoaded)
          None -> effect.none()
        },
      ]),
    )

    model.SendCompleted(Error(error)) -> #(
      Model(..current, sending: False, error: Some(api.describe_error(error))),
      effect.none(),
    )

    // ─── Редактор JSON ───────────────────────────────────────────────────────
    model.JsonEditorToggled ->
      case current.json_editor {
        Some(_) -> #(Model(..current, json_editor: None), effect.none())
        None -> open_editor(current)
      }

    model.JsonEditorChanged(text) -> #(
      Model(
        ..current,
        json_editor: option.map(current.json_editor, fn(editor) {
          JsonEditor(..editor, text:, parse_error: dom.validate_json(text))
        }),
      ),
      effect.none(),
    )

    model.JsonEditorReset -> open_editor(current)

    model.PreviewLoaded(Ok(response)) -> #(
      Model(
        ..current,
        json_editor: Some(JsonEditor(
          text: response.raw_request,
          generated: response.raw_request,
          parse_error: None,
          loading: False,
        )),
        warnings: response.warnings,
      ),
      effect.none(),
    )

    model.PreviewLoaded(Error(error)) -> #(
      Model(
        ..current,
        json_editor: None,
        error: Some(api.describe_error(error)),
      ),
      effect.none(),
    )

    // ─── Диалог ──────────────────────────────────────────────────────────────
    model.RawToggled(id) -> #(
      Model(..current, expanded: model.toggle(current.expanded, id)),
      effect.none(),
    )

    model.ReasoningExpandToggled(id) -> #(
      Model(
        ..current,
        expanded_reasoning: model.toggle(current.expanded_reasoning, id),
      ),
      effect.none(),
    )

    model.MessageDeleteClicked(id) ->
      case current.active {
        None -> #(current, effect.none())
        Some(session_id) -> #(
          Model(..current, error: None),
          api.delete_message(session_id, id, model.MessageDeleted),
        )
      }

    // Сервер возвращает id удалённых строк — убираем их из диалога, не
    // перезагружая список целиком.
    model.MessageDeleted(Ok(deleted)) -> #(
      Model(
        ..current,
        messages: list.filter(current.messages, fn(message) {
          !list.contains(deleted, message.id)
        }),
      ),
      api.load_sessions(model.SessionsLoaded),
    )

    model.MessageDeleted(Error(error)) -> fail(current, error)

    model.WarningsDismissed -> #(Model(..current, warnings: []), effect.none())
    model.ErrorDismissed -> #(Model(..current, error: None), effect.none())
  }
}

pub const composer_id = "composer-input"

pub const rename_id = "rename-input"

// ─── Загрузка данных ─────────────────────────────────────────────────────────

fn catalog_loaded(
  current: Model,
  response: dto.CatalogResponse,
) -> #(Model, Effect(Msg)) {
  // Выбираем первого доступного провайдера, иначе просто первого.
  let selected =
    list.find(response.providers, fn(status) { status.available })
    |> option.from_result
    |> option.lazy_or(fn() {
      list.first(response.providers) |> option.from_result
    })

  case selected {
    None -> #(
      Model(..current, catalog: response.providers, loading: False),
      effect.none(),
    )
    Some(status) -> #(
      Model(
        ..current,
        catalog: response.providers,
        // Не затираем выбор, если он уже восстановлен из сессии.
        provider_id: case current.provider_id {
          "" -> status.provider.id
          existing -> existing
        },
        model_id: case current.model_id {
          "" -> status.provider.default_model
          existing -> existing
        },
        loading: False,
      ),
      effect.none(),
    )
  }
}

fn sessions_loaded(
  current: Model,
  sessions: List(types.SessionSummary),
) -> #(Model, Effect(Msg)) {
  let updated = Model(..current, sessions:, loading: False)

  // При первом заходе открываем верхнюю сессию, чтобы не показывать пустоту.
  case current.active, sessions {
    None, [first, ..] -> #(
      Model(..updated, active: Some(first.id), loading: True),
      effect.batch([
        api.load_session(first.id, model.SessionLoaded),
        api.load_messages(first.id, model.MessagesLoaded),
        api.load_tasks(first.id, model.TasksLoaded),
        api.load_memory(first.id, model.MemoryLoaded),
        // Сессия, открытая автовыбором, ничем не отличается от выбранной
        // руками: поток нужен и ей.
        dom.open_event_stream(first.id, model.StreamEvent),
      ]),
    )
    _, _ -> #(updated, effect.none())
  }
}

/// Восстанавливает выбор модели и параметры из сохранённой сессии.
fn session_loaded(
  current: Model,
  session: types.Session,
) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..current,
      agent_id: session.agent_id,
      provider_id: option.unwrap(session.provider_id, current.provider_id),
      model_id: option.unwrap(session.model_id, current.model_id),
      params: session.params,
    ),
    effect.none(),
  )
}

fn fail(current: Model, error: rsvp.Error) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..current,
      loading: False,
      sending: False,
      error: Some(api.describe_error(error)),
    ),
    effect.none(),
  )
}

// ─── Агенты ──────────────────────────────────────────────────────────────────

/// Правка открытой формы. Без формы сообщение игнорируется.
fn edit_form(
  current: Model,
  change: fn(model.AgentForm) -> model.AgentForm,
) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..current,
      agents: Agents(
        ..current.agents,
        form: option.map(current.agents.form, change),
      ),
    ),
    effect.none(),
  )
}

fn toggle(selected: Set(String), id: String) -> Set(String) {
  case set.contains(selected, id) {
    True -> set.delete(selected, id)
    False -> set.insert(selected, id)
  }
}

/// Модель по умолчанию у провайдера — для смены провайдера в форме.
fn default_model_of(current: Model, provider_id: String) -> String {
  current.catalog
  |> list.find(fn(entry) { entry.provider.id == provider_id })
  |> result.map(fn(entry) { entry.provider.default_model })
  |> result.unwrap("")
}

/// Отправляет форму: создание или правка — по наличию `id`.
///
/// Валидацию не дублируем: сервер уже проверяет имя, модель и пределы
/// `max_steps`, и его сообщения точнее. Здесь только то, что нельзя
/// выразить запросом, — пустое имя блокирует кнопку.
fn submit_agent(current: Model) -> #(Model, Effect(Msg)) {
  case current.agents.form {
    None -> #(current, effect.none())
    Some(form) -> {
      let tools = set.to_list(form.tools)
      // Непонятное значение приравниваем к одному шагу: агент без
      // многошаговости — разумное умолчание, а не ошибка.
      let max_steps = result.unwrap(int.parse(string.trim(form.max_steps)), 1)

      let saving =
        Model(
          ..current,
          error: None,
          agents: Agents(..current.agents, saving: True),
        )

      case form.id {
        None -> #(
          saving,
          api.create_agent(
            dto.CreateAgentRequest(
              name: string.trim(form.name),
              description: string.trim(form.description),
              system_prompt: form.system_prompt,
              provider_id: form.provider_id,
              model_id: form.model_id,
              params: types.default_options(),
              max_steps:,
              tools:,
              memory: model.memory_of_form(form),
            ),
            model.AgentSaved,
          ),
        )

        Some(id) -> #(
          saving,
          api.update_agent(
            id,
            dto.UpdateAgentRequest(
              name: Some(string.trim(form.name)),
              description: Some(string.trim(form.description)),
              system_prompt: Some(form.system_prompt),
              provider_id: Some(form.provider_id),
              model_id: Some(form.model_id),
              // Параметры правятся в сессии запуска, а не здесь: форма
              // и так длинная, а поля те же самые.
              params: None,
              max_steps: Some(max_steps),
              tools: Some(tools),
              memory: Some(model.memory_of_form(form)),
            ),
            model.AgentSaved,
          ),
        )
      }
    }
  }
}

// ─── Поток событий сессии ────────────────────────────────────────────────────

/// Применяет пришедшее событие к состоянию.
///
/// Нечитаемое или незнакомое событие молча игнорируется: поток — это
/// ускорение, а не источник правды. Состояние всё равно подтвердится
/// ответом на запрос.
fn stream_event(
  current: Model,
  name: String,
  payload: Dynamic,
) -> #(Model, Effect(Msg)) {
  case name {
    "step" ->
      case decode.run(payload, dto.step_event_decoder()) {
        Ok(event) -> merge_step(current, event)
        Error(_) -> #(current, effect.none())
      }

    "task" ->
      case decode.run(payload, dto.task_event_decoder()) {
        Ok(event) -> #(merge_task(current, event.task), effect.none())
        Error(_) -> #(current, effect.none())
      }

    _ -> #(current, effect.none())
  }
}

/// Добавляет шаги, пришедшие потоком.
///
/// Слияние идёт по `id`: те же сообщения придут ещё раз в ответе на
/// `POST /tasks`, и без проверки лента удвоилась бы.
fn merge_step(current: Model, event: dto.StepEvent) -> #(Model, Effect(Msg)) {
  case merge_messages(current.messages, event.messages) {
    merged if merged == current.messages -> #(current, effect.none())
    merged -> #(
      Model(..current, messages: merged),
      dom.scroll_dialog_to_bottom(),
    )
  }
}

/// Добавляет только те сообщения, которых ещё нет.
///
/// Шаг приходит дважды — потоком и в ответе на `POST /tasks`. Какой из
/// них окажется первым, зависит от сети, поэтому порядок не важен: важна
/// идемпотентность.
fn merge_messages(
  existing: List(types.Message),
  incoming: List(types.Message),
) -> List(types.Message) {
  let known =
    existing
    |> list.map(fn(message) { message.id })
    |> set.from_list

  let fresh =
    list.filter(incoming, fn(message) { !set.contains(known, message.id) })

  list.append(existing, fresh)
}

/// Обновляет задание или добавляет новое.
///
/// Приходит и при создании задания, и при его завершении, поэтому
/// обрабатываются оба случая.
fn merge_task(current: Model, task: types.Task) -> Model {
  let known = list.any(current.tasks, fn(existing) { existing.id == task.id })

  case known {
    True ->
      Model(
        ..current,
        tasks: list.map(current.tasks, fn(existing) {
          case existing.id == task.id {
            True -> task
            False -> existing
          }
        }),
      )
    False -> Model(..current, tasks: list.append(current.tasks, [task]))
  }
}

// ─── Выбор модели ────────────────────────────────────────────────────────────

fn provider_changed(
  current: Model,
  provider_id: String,
) -> #(Model, Effect(Msg)) {
  let next_model =
    list.find(current.catalog, fn(status) { status.provider.id == provider_id })
    |> option.from_result
    |> option.map(fn(status) { status.provider.default_model })
    |> option.unwrap("")

  let updated = Model(..current, provider_id:, model_id: next_model)

  // Параметры могли содержать значения, недопустимые для новой модели
  // (например, effort=xhigh при переходе на kimi) — приводим их к шкале.
  let #(updated, _) = reconcile_params(updated)

  #(updated, persist_selection(updated))
}

fn model_changed(current: Model, model_id: String) -> #(Model, Effect(Msg)) {
  let updated = Model(..current, model_id:)
  let #(updated, _) = reconcile_params(updated)
  #(updated, persist_selection(updated))
}

/// Подгоняет параметры под возможности выбранной модели.
///
/// Это зеркало серверной `normalize_options` — нужно, чтобы UI не предлагал
/// значений, которые сервер всё равно заменит.
fn reconcile_params(current: Model) -> #(Model, List(String)) {
  case model.current_model(current) {
    None -> #(current, [])
    Some(info) -> {
      let params = current.params
      let efforts = types.reasoning_efforts(info)

      // Усилие вне шкалы модели заменяем её значением по умолчанию.
      let effort = case params.reasoning_effort {
        Some(value) ->
          case list.contains(efforts, value) {
            True -> Some(value)
            False -> types.default_effort(info)
          }
        None -> None
      }

      // Модель без рассуждений — параметры рассуждений не нужны вовсе.
      let #(enabled, effort) = case types.supports_reasoning(info) {
        False -> #(None, None)
        True ->
          case types.can_disable_reasoning(info) {
            True -> #(params.reasoning_enabled, effort)
            // Выключить нельзя, флаг бессмыслен.
            False -> #(None, effort)
          }
      }

      // max_tokens не должен превышать лимит модели.
      let max_tokens = case params.max_tokens, info.max_output_tokens {
        Some(value), limit if limit > 0 && value > limit -> Some(limit)
        other, _ -> other
      }

      #(
        Model(
          ..current,
          params: types.RequestOptions(
            ..params,
            reasoning_enabled: enabled,
            reasoning_effort: effort,
            max_tokens:,
          ),
        ),
        [],
      )
    }
  }
}

/// Сохраняет выбор и параметры в сессии, чтобы они пережили перезагрузку.
fn persist_selection(current: Model) -> Effect(Msg) {
  case current.active {
    None -> effect.none()
    Some(id) ->
      api.update_session(
        id,
        None,
        Some(current.provider_id),
        Some(current.model_id),
        Some(current.params),
        model.SessionUpdated,
      )
  }
}

// ─── Параметры ───────────────────────────────────────────────────────────────

fn set_params(
  current: Model,
  change: fn(RequestOptions) -> RequestOptions,
) -> #(Model, Effect(Msg)) {
  let updated = Model(..current, params: change(current.params))

  // Если редактор JSON открыт и не правился руками — перегенерируем тело,
  // чтобы изменение параметра было видно сразу.
  let refresh = case updated.json_editor, model.json_hand_edited(updated) {
    Some(_), False -> preview_effect(updated)
    _, _ -> effect.none()
  }

  #(updated, effect.batch([persist_selection(updated), refresh]))
}

fn default_max_tokens(current: Model) -> Int {
  case model.current_model(current) {
    Some(info) if info.max_output_tokens > 0 ->
      int.min(4096, info.max_output_tokens)
    _ -> 4096
  }
}

// ─── Отправка ────────────────────────────────────────────────────────────────

fn send(current: Model) -> #(Model, Effect(Msg)) {
  case model.can_send(current), current.active {
    False, _ | _, None -> #(current, effect.none())

    True, Some(session_id) -> {
      let busy = Model(..current, sending: True, error: None, warnings: [])

      // В сессии агента ввод выдаёт задание: отправлять отдельные
      // сообщения мимо агента было бы обходом его настроек.
      case model.is_agent_session(current) {
        True -> #(
          busy,
          api.create_task(session_id, current.draft, model.TaskCompleted),
        )
        False -> #(
          busy,
          api.send(session_id, build_request(current), model.SendCompleted),
        )
      }
    }
  }
}

/// Тело запроса к нашему серверу.
///
/// `raw_request_override` ставится только если пользователь действительно
/// правил JSON: иначе сервер соберёт тело сам из параметров.
fn build_request(current: Model) -> dto.SendRequest {
  let override = case current.json_editor {
    Some(editor) ->
      case editor.text != editor.generated {
        True -> Some(editor.text)
        False -> None
      }
    None -> None
  }

  dto.SendRequest(
    provider_id: current.provider_id,
    model_id: current.model_id,
    content: current.draft,
    params: current.params,
    raw_request_override: override,
  )
}

// ─── Редактор JSON ───────────────────────────────────────────────────────────

fn open_editor(current: Model) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..current,
      json_editor: Some(JsonEditor(
        text: "",
        generated: "",
        parse_error: None,
        loading: True,
      )),
    ),
    preview_effect(current),
  )
}

fn preview_effect(current: Model) -> Effect(Msg) {
  case current.active {
    None -> effect.none()
    Some(session_id) -> {
      // Для предпросмотра пустого сообщения сервер вернёт ошибку,
      // поэтому подставляем заглушку.
      let content = case string.trim(current.draft) {
        "" -> "…"
        text -> text
      }
      api.preview(
        session_id,
        dto.SendRequest(
          provider_id: current.provider_id,
          model_id: current.model_id,
          content:,
          params: current.params,
          raw_request_override: None,
        ),
        model.PreviewLoaded,
      )
    }
  }
}
