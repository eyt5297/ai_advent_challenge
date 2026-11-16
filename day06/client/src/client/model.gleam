//// Состояние клиента и сообщения обновления.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import rsvp
import shared/api
import shared/types.{
  type Agent, type AgentSummary, type Message, type ModelInfo,
  type ProviderStatus, type RequestOptions, type Session, type SessionSummary,
  type Task,
}

pub type Model {
  Model(
    /// Список слева.
    sessions: List(SessionSummary),
    active: Option(String),
    messages: List(Message),
    /// Агент активной сессии; None — обычная сессия, режим
    /// «сообщение → запрос → ответ», как до появления агентов.
    agent_id: Option(String),
    /// Задания активной сессии. Пусто у сессий без агента — тогда лента
    /// остаётся плоской, как до появления агентов.
    tasks: List(Task),
    /// id заданий с раскрытыми шагами: по умолчанию видны задание и итог,
    /// а обмен с моделью разворачивается по требованию.
    expanded_tasks: Set(String),
    /// Каталог с сервера; до загрузки пуст.
    catalog: List(ProviderStatus),
    provider_id: String,
    model_id: String,
    draft: String,
    params: RequestOptions,
    params_open: Bool,
    /// None — редактор JSON свёрнут.
    json_editor: Option(JsonEditor),
    /// id сообщений с раскрытым сырым JSON.
    expanded: Set(String),
    /// id сообщений с раскрытыми рассуждениями.
    expanded_reasoning: Set(String),
    /// Идёт запрос к провайдеру — ввод заблокирован.
    sending: Bool,
    /// Сессия, которую сейчас переименовывают.
    renaming: Option(Rename),
    /// Предупреждения нормализации параметров.
    warnings: List(String),
    /// Ошибка верхнего уровня (сеть, сервер).
    error: Option(String),
    /// Идёт первичная загрузка.
    loading: Bool,
    /// Агенты и их настройка.
    agents: Agents,
    /// Память активной сессии: факты, пересказ, расход токенов.
    /// None — у сессии без агента её не бывает.
    memory: Option(api.MemoryResponse),
    /// Панель памяти раскрыта.
    memory_open: Bool,
  )
}

/// Всё, что относится к управлению агентами.
///
/// Вынесено в отдельную запись, а не рассыпано по `Model`: полей много,
/// и живут они своей жизнью — экран агентов открыт или закрыт целиком.
pub type Agents {
  Agents(
    /// Экран агентов открыт поверх диалога.
    open: Bool,
    list: List(AgentSummary),
    /// Каталог инструментов с сервера; загружается один раз.
    tools: List(api.ToolInfo),
    /// Открытая форма: создание или правка. None — показан список.
    form: Option(AgentForm),
    /// Идёт сохранение — кнопки заблокированы.
    saving: Bool,
  )
}

/// Поля формы агента.
///
/// Хранятся строками, как их ввёл пользователь: разбор `max_steps` в
/// число на каждое нажатие клавиши мешал бы стирать значение целиком.
pub type AgentForm {
  AgentForm(
    /// None — создаём нового, Some(id) — правим существующего.
    id: Option(String),
    name: String,
    description: String,
    system_prompt: String,
    provider_id: String,
    model_id: String,
    max_steps: String,
    /// Выбранные инструменты.
    tools: Set(String),
    /// Настройка памяти. Поля строками — чтобы можно было стереть
    /// значение целиком, не получая ноль на каждое нажатие клавиши.
    memory_window: String,
    memory_tasks: String,
    memory_summary_every: String,
    memory_facts: Bool,
    memory_budget: String,
  )
}

/// Пустая форма для нового агента.
///
/// Провайдер и модель берутся текущие: чаще всего агента создают под ту
/// модель, с которой только что работали.
pub fn blank_agent_form(provider_id: String, model_id: String) -> AgentForm {
  AgentForm(
    id: None,
    name: "",
    description: "",
    system_prompt: "",
    provider_id:,
    model_id:,
    max_steps: "1",
    // Инструменты по умолчанию не выданы: включение `read_file` или
    // `http_request` должно быть осознанным действием.
    tools: set.new(),
    // А вот память по умолчанию включена: агент, забывающий предыдущий
    // разговор, — чаще недоразумение, чем осознанный выбор.
    memory_window: "outcomes",
    memory_tasks: "10",
    memory_summary_every: "20",
    memory_facts: True,
    memory_budget: "0",
  )
}

/// Форма, заполненная существующим агентом.
pub fn agent_form_of(agent: Agent) -> AgentForm {
  AgentForm(
    id: Some(agent.id),
    name: agent.name,
    description: agent.description,
    system_prompt: agent.system_prompt,
    provider_id: agent.provider_id,
    model_id: agent.model_id,
    max_steps: int.to_string(agent.max_steps),
    tools: set.from_list(agent.tools),
    memory_window: types.window_to_string(agent.memory.window),
    memory_tasks: int.to_string(case types.window_tasks(agent.memory.window) {
      0 -> 10
      tasks -> tasks
    }),
    memory_summary_every: int.to_string(case agent.memory.summary {
      types.NoSummary -> 0
      types.SummarizeEvery(messages:) -> messages
    }),
    memory_facts: agent.memory.facts,
    memory_budget: int.to_string(agent.memory.budget_chars),
  )
}

/// Собирает настройку памяти из полей формы.
pub fn memory_of_form(form: AgentForm) -> types.Memory {
  types.Memory(
    window: types.window_from(
      form.memory_window,
      parse_int(form.memory_tasks, 10),
    ),
    summary: case parse_int(form.memory_summary_every, 0) {
      every if every > 0 -> types.SummarizeEvery(every)
      _ -> types.NoSummary
    },
    facts: form.memory_facts,
    budget_chars: parse_int(form.memory_budget, 0),
  )
}

fn parse_int(text: String, fallback: Int) -> Int {
  case int.parse(string.trim(text)) {
    Ok(value) -> value
    Error(Nil) -> fallback
  }
}

/// Редактор отправляемого JSON.
pub type JsonEditor {
  JsonEditor(
    /// Текущий текст в поле.
    text: String,
    /// Текст, сгенерированный сервером, — чтобы понять, правил ли пользователь.
    generated: String,
    /// Ошибка разбора JSON, если есть.
    parse_error: Option(String),
    /// Идёт запрос /preview.
    loading: Bool,
  )
}

pub type Rename {
  Rename(session_id: String, title: String)
}

pub fn init_model() -> Model {
  Model(
    sessions: [],
    active: None,
    messages: [],
    agent_id: None,
    tasks: [],
    expanded_tasks: set.new(),
    catalog: [],
    provider_id: "",
    model_id: "",
    draft: "",
    params: types.default_options(),
    params_open: False,
    json_editor: None,
    expanded: set.new(),
    expanded_reasoning: set.new(),
    sending: False,
    renaming: None,
    warnings: [],
    error: None,
    loading: True,
    agents: Agents(open: False, list: [], tools: [], form: None, saving: False),
    memory: None,
    memory_open: False,
  )
}

// ─── Сообщения ───────────────────────────────────────────────────────────────

pub type Msg {
  // Загрузка данных
  CatalogLoaded(Result(api.CatalogResponse, rsvp.Error))
  SessionsLoaded(Result(List(SessionSummary), rsvp.Error))
  MessagesLoaded(Result(List(Message), rsvp.Error))
  SessionLoaded(Result(Session, rsvp.Error))
  TasksLoaded(Result(List(Task), rsvp.Error))

  // Задания
  TaskExpandToggled(String)
  TaskCompleted(Result(api.TaskResponse, rsvp.Error))
  TaskDeleteClicked(String)
  TaskDeleted(String, Result(Nil, rsvp.Error))

  // Сессии
  NewSessionClicked
  SessionCreated(Result(Session, rsvp.Error))
  SessionSelected(String)
  SessionDeleteClicked(String)
  SessionDeleted(String, Result(Nil, rsvp.Error))
  RenameStarted(String, String)
  RenameChanged(String)
  RenameSubmitted
  RenameCancelled
  SessionUpdated(Result(Session, rsvp.Error))

  // Выбор модели
  ProviderChanged(String)
  ModelChanged(String)

  // Параметры
  ParamsToggled
  TemperatureToggled(Bool)
  TemperatureChanged(String)
  MaxTokensToggled(Bool)
  MaxTokensChanged(String)
  SystemPromptToggled(Bool)
  SystemPromptChanged(String)
  ReasoningToggled(Bool)
  ReasoningEnabledChanged(Bool)
  EffortChanged(String)
  ParamsReset

  // Ввод и отправка
  DraftChanged(String)
  SendClicked
  SendCompleted(Result(api.SendResponse, rsvp.Error))

  // Редактор JSON
  JsonEditorToggled
  JsonEditorChanged(String)
  JsonEditorReset
  PreviewLoaded(Result(api.PreviewResponse, rsvp.Error))

  // Агенты
  AgentsOpened
  AgentsClosed
  AgentsLoaded(Result(List(AgentSummary), rsvp.Error))
  ToolsLoaded(Result(List(api.ToolInfo), rsvp.Error))
  AgentCreateClicked
  AgentEditClicked(String)
  AgentLoaded(Result(Agent, rsvp.Error))
  AgentFormCancelled
  AgentNameChanged(String)
  AgentDescriptionChanged(String)
  AgentPromptChanged(String)
  AgentProviderChanged(String)
  AgentModelChanged(String)
  AgentMaxStepsChanged(String)
  AgentToolToggled(String)
  AgentFormSubmitted
  AgentSaved(Result(Agent, rsvp.Error))
  AgentDeleteClicked(String)
  AgentDeleted(String, Result(Nil, rsvp.Error))
  AgentRunClicked(String)
  AgentSessionStarted(Result(Session, rsvp.Error))

  // Память сессии
  MemoryLoaded(Result(api.MemoryResponse, rsvp.Error))
  MemoryPanelToggled

  // Настройка памяти в форме агента
  AgentMemoryWindowChanged(String)
  AgentMemoryTasksChanged(String)
  AgentMemorySummaryChanged(String)
  AgentMemoryFactsToggled
  AgentMemoryBudgetChanged(String)

  // Поток событий сессии (SSE)
  StreamEvent(name: String, payload: Dynamic)

  // Диалог
  RawToggled(String)
  ReasoningExpandToggled(String)
  MessageDeleteClicked(String)
  MessageDeleted(Result(List(String), rsvp.Error))
  WarningsDismissed
  ErrorDismissed
}

// ─── Производные значения ────────────────────────────────────────────────────

/// Выбранный провайдер со статусом доступности.
pub fn current_provider(model: Model) -> Option(ProviderStatus) {
  list.find(model.catalog, fn(status) {
    status.provider.id == model.provider_id
  })
  |> option.from_result
}

pub fn current_model(model: Model) -> Option(ModelInfo) {
  case current_provider(model) {
    Some(status) ->
      types.find_model(status.provider, model.model_id) |> option.from_result
    None -> None
  }
}

/// Доступен ли выбранный провайдер (есть ли ключ на сервере).
pub fn provider_available(model: Model) -> Bool {
  case current_provider(model) {
    Some(status) -> status.available
    None -> False
  }
}

/// Правил ли пользователь JSON руками.
///
/// Если правил, панель параметров переходит в режим «только чтение»:
/// применять параметры поверх ручного тела было бы неожиданно.
pub fn json_hand_edited(model: Model) -> Bool {
  case model.json_editor {
    Some(editor) -> editor.text != editor.generated
    None -> False
  }
}

/// Можно ли отправлять.
pub fn can_send(model: Model) -> Bool {
  let has_content = string.trim(model.draft) != ""
  let json_valid = case model.json_editor {
    Some(editor) -> editor.parse_error == None
    None -> True
  }

  !model.sending
  && model.active != None
  && has_content
  && json_valid
  && provider_available(model)
}

/// Причина, по которой отправка недоступна, — для подсказки на кнопке.
pub fn send_blocked_reason(model: Model) -> Option(String) {
  case model.sending, model.active, string.trim(model.draft) {
    True, _, _ -> Some("идёт запрос")
    _, None, _ -> Some("выберите или создайте сессию")
    _, _, "" -> Some("введите сообщение")
    _, _, _ ->
      case provider_available(model), model.json_editor {
        False, _ -> Some("у провайдера не задан ключ на сервере")
        _, Some(JsonEditor(parse_error: Some(_), ..)) ->
          Some("JSON содержит ошибку")
        _, _ -> None
      }
  }
}

pub fn is_expanded(model: Model, id: String) -> Bool {
  set.contains(model.expanded, id)
}

pub fn is_reasoning_expanded(model: Model, id: String) -> Bool {
  set.contains(model.expanded_reasoning, id)
}

/// Сессия запущена агентом: ввод выдаёт задания, а не сообщения.
pub fn is_agent_session(model: Model) -> Bool {
  model.agent_id != None
}

pub fn is_task_expanded(model: Model, id: String) -> Bool {
  set.contains(model.expanded_tasks, id)
}

/// Шаги одного задания в порядке выполнения.
pub fn steps_of(model: Model, task_id: String) -> List(Message) {
  list.filter(model.messages, fn(message) { message.task_id == Some(task_id) })
}

/// Сообщения вне заданий — ручные отправки в сессии без агента.
/// Они рисуются плоско, как до появления агентов.
pub fn loose_messages(model: Model) -> List(Message) {
  list.filter(model.messages, fn(message) { message.task_id == None })
}

pub fn toggle(items: Set(String), id: String) -> Set(String) {
  case set.contains(items, id) {
    True -> set.delete(items, id)
    False -> set.insert(items, id)
  }
}
