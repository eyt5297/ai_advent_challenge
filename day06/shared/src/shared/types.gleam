//// Доменные типы, общие для клиента и сервера.
////
//// Модуль намеренно не содержит логики — только данные и мелкие
//// вспомогательные функции над ними. JSON-кодеки лежат в `shared/codec`.

import gleam/list
import gleam/option.{type Option, None, Some}

// ─── Каталог провайдеров и моделей ───────────────────────────────────────────

pub type Provider {
  Provider(
    id: String,
    title: String,
    /// Группы моделей — становятся <optgroup> в выпадающем списке.
    groups: List(ModelGroup),
    /// Модель, выбираемая при первом обращении к провайдеру.
    default_model: String,
  )
}

/// Группа моделей внутри провайдера: вендор (Anthropic, OpenAI …) либо «Авто».
pub type ModelGroup {
  ModelGroup(title: String, models: List(ModelInfo))
}

pub type ModelInfo {
  ModelInfo(
    /// Значение поля "model" в запросе к провайдеру.
    id: String,
    /// Подпись в выпадающем списке.
    title: String,
    /// Размер контекстного окна, 0 — неизвестно.
    context_length: Int,
    /// Максимум токенов в ответе, 0 — неизвестно.
    max_output_tokens: Int,
    /// Принимает изображения на вход.
    vision: Bool,
    /// Поддерживает tool calls.
    tools: Bool,
    reasoning: ReasoningSupport,
  )
}

/// Как конкретная модель относится к «рассуждениям».
///
/// Главное расхождение между провайдерами: veai знает шкалу
/// low/medium/high/xhigh/max и позволяет рассуждения выключать,
/// kimi рассуждает всегда и знает только low/high/max. Поэтому
/// допустимые значения хранятся данными, а не хардкодом.
pub type ReasoningSupport {
  /// Модель не рассуждает (Anthropic/haiku-4.5, Google/gemini-3.5-flash-lite).
  NoReasoning
  /// Рассуждения можно включать и выключать.
  OptionalReasoning(
    default_enabled: Bool,
    default_effort: String,
    efforts: List(String),
  )
  /// Модель рассуждает всегда; управлять можно только усилием.
  AlwaysReasoning(default_effort: String, efforts: List(String))
}

/// Провайдер вместе с признаком доступности (есть ли ключ в окружении).
/// Отдаётся клиенту эндпоинтом GET /api/catalog.
pub type ProviderStatus {
  ProviderStatus(provider: Provider, available: Bool)
}

// ─── Параметры запроса ───────────────────────────────────────────────────────

/// Параметры генерации.
///
/// `None` означает «не включать ключ в тело запроса вообще», а не
/// «значение по умолчанию». Это позволяет отличить явно выставленный
/// `temperature: 0.0` от «параметр не трогали, пусть решает провайдер».
pub type RequestOptions {
  RequestOptions(
    temperature: Option(Float),
    max_tokens: Option(Int),
    system_prompt: Option(String),
    reasoning_enabled: Option(Bool),
    reasoning_effort: Option(String),
    /// В MVP всегда False.
    stream: Bool,
  )
}

/// Ничего не навязываем провайдеру.
pub fn default_options() -> RequestOptions {
  RequestOptions(
    temperature: None,
    max_tokens: None,
    system_prompt: None,
    reasoning_enabled: None,
    reasoning_effort: None,
    stream: False,
  )
}

/// Сколько параметров задано явно — для счётчика на кнопке ⚙.
pub fn active_option_count(options: RequestOptions) -> Int {
  let count = fn(is_set) {
    case is_set {
      True -> 1
      False -> 0
    }
  }
  count(option.is_some(options.temperature))
  + count(option.is_some(options.max_tokens))
  + count(option.is_some(options.system_prompt))
  + count(option.is_some(options.reasoning_enabled))
  + count(option.is_some(options.reasoning_effort))
}

// ─── Агенты ──────────────────────────────────────────────────────────────────

/// Настроенный исполнитель: промпт, модель и параметры, заданные один раз
/// и переиспользуемые при каждом запуске.
///
/// Сессия — запущенный экземпляр агента (`Session.agent_id`), задание —
/// единица работы внутри запуска.
pub type Agent {
  Agent(
    id: String,
    name: String,
    description: String,
    /// Определяющее свойство агента: на уровне запуска не переопределяется.
    system_prompt: String,
    provider_id: String,
    model_id: String,
    /// Значения по умолчанию; сессия может переопределить по полю.
    params: RequestOptions,
    /// Предел обращений к LLM в одном задании — защита от зацикливания.
    max_steps: Int,
    /// Идентификаторы доступных инструментов. Пустой список — обычное
    /// поведение: агент только общается с моделью.
    tools: List(String),
    /// Что агент помнит между заданиями.
    memory: Memory,
    created_at: Int,
    updated_at: Int,
  )
}

// ─── Память ──────────────────────────────────────────────────────────────────

/// Что агент берёт из прошлого, начиная новое задание.
///
/// Четыре независимых переключателя, а не один режим: «вся история» и
/// «факты» — разные вещи, и запрещать их сочетание незачем. Итоговый
/// запрос собирается слоями:
///
///     системный промпт → факты → пересказ → окно → текущее задание
pub type Memory {
  Memory(
    window: MemoryWindow,
    summary: SummaryMode,
    /// Подставлять ли факты сессии (инструмент `remember`).
    facts: Bool,
    /// Предел на историю в символах. 0 — четверть контекста модели.
    ///
    /// Последний рубеж: любая комбинация рано или поздно переполнит
    /// контекст, и провайдер отвергнет запрос целиком. Лучше срезать
    /// старое самим, чем получить отказ.
    budget_chars: Int,
  )
}

/// Сколько прошлых заданий показывать и в каком виде.
pub type MemoryWindow {
  /// Каждое задание с чистого листа — поведение до появления памяти.
  NoMemory
  /// Пары «задание → итог», без шагов и вызовов инструментов.
  /// Дёшево по контексту и обычно достаточно, чтобы не терять нить.
  Outcomes(tasks: Int)
  /// Последние N заданий целиком, со всеми вызовами.
  Transcripts(tasks: Int)
  /// Вся история сессии.
  Everything
}

/// Пересказ вытесненного за окно.
pub type SummaryMode {
  NoSummary
  /// Сжимать, когда за окно вытеснено `messages` сообщений.
  SummarizeEvery(messages: Int)
}

/// Умолчание: помнить итоги последних десяти заданий и сжимать всё, что
/// старше. Для агента это полезнее чистого листа, а контекст растёт
/// медленно — в отличие от полных расшифровок.
pub fn default_memory() -> Memory {
  Memory(
    window: Outcomes(10),
    summary: SummarizeEvery(20),
    facts: True,
    budget_chars: 0,
  )
}

/// Память, выключенная целиком.
pub fn no_memory() -> Memory {
  Memory(window: NoMemory, summary: NoSummary, facts: False, budget_chars: 0)
}

pub fn window_to_string(window: MemoryWindow) -> String {
  case window {
    NoMemory -> "none"
    Outcomes(..) -> "outcomes"
    Transcripts(..) -> "transcripts"
    Everything -> "everything"
  }
}

/// Сколько заданий охватывает окно; для `Everything` смысла не имеет.
pub fn window_tasks(window: MemoryWindow) -> Int {
  case window {
    NoMemory | Everything -> 0
    Outcomes(tasks:) -> tasks
    Transcripts(tasks:) -> tasks
  }
}

pub fn window_from(kind: String, tasks: Int) -> MemoryWindow {
  case kind {
    "outcomes" -> Outcomes(at_least(tasks, 1))
    "transcripts" -> Transcripts(at_least(tasks, 1))
    "everything" -> Everything
    _ -> NoMemory
  }
}

fn at_least(value: Int, floor: Int) -> Int {
  case value < floor {
    True -> floor
    False -> value
  }
}

/// Факт, который агент счёл важным запомнить.
///
/// Привязан к сессии, а не к агенту: у агента для постоянных знаний есть
/// системный промпт, а факт — то, что выяснилось в этом запуске.
pub type Fact {
  Fact(id: String, session_id: String, text: String, created_at: Int)
}

/// Пересказ вытесненной части истории.
///
/// Не заменяет сообщения в БД: те остаются со всеми сырыми телами, и
/// наблюдаемость не страдает. Пересказ — только то, что подставляется
/// вместо них в запрос.
pub type Summary {
  Summary(
    id: String,
    session_id: String,
    text: String,
    /// Докуда пересказано: `seq` последнего вошедшего сообщения.
    covers_through_seq: Int,
    /// Сколько сообщений вошло — для показа и для порога сжатия.
    message_count: Int,
    created_at: Int,
  )
}

/// Строка в списке агентов.
pub type AgentSummary {
  AgentSummary(
    id: String,
    name: String,
    model_id: String,
    /// Сколько запусков у агента — для подписи в списке.
    session_count: Int,
  )
}

/// Значение `max_steps` для агента без многошаговости: одно задание —
/// один обмен с моделью.
pub const single_step = 1

// ─── Задания ─────────────────────────────────────────────────────────────────

pub type TaskStatus {
  Running
  TaskDone
  TaskFailed
  Cancelled
}

pub fn task_status_to_string(status: TaskStatus) -> String {
  case status {
    Running -> "running"
    TaskDone -> "done"
    TaskFailed -> "failed"
    Cancelled -> "cancelled"
  }
}

pub fn task_status_from_string(value: String) -> Result(TaskStatus, Nil) {
  case value {
    "running" -> Ok(Running)
    "done" -> Ok(TaskDone)
    "failed" -> Ok(TaskFailed)
    "cancelled" -> Ok(Cancelled)
    _ -> Error(Nil)
  }
}

/// Задание агенту и его итог.
///
/// Статус принадлежит заданию, а не сессии: сессия живёт долго и копит
/// задания, каждое из которых имеет свой жизненный цикл.
pub type Task {
  Task(
    id: String,
    session_id: String,
    seq: Int,
    /// Текст задания от пользователя.
    prompt: String,
    /// Итог работы; None, пока задание не завершено.
    result: Option(String),
    status: TaskStatus,
    error: Option(String),
    /// Сколько обращений к LLM потребовалось.
    steps: Int,
    created_at: Int,
    finished_at: Option(Int),
  )
}

// ─── Сессии ──────────────────────────────────────────────────────────────────

/// Строка в списке сессий слева.
pub type SessionSummary {
  SessionSummary(
    id: String,
    title: String,
    created_at: Int,
    updated_at: Int,
    /// Сколько сообщений в сессии — для подписи в списке.
    message_count: Int,
    /// Чей это запуск; None — сессия без агента (до появления агентов).
    agent_id: Option(String),
  )
}

/// Сессия со всеми сохранёнными настройками.
pub type Session {
  Session(
    id: String,
    title: String,
    created_at: Int,
    updated_at: Int,
    /// Чей это запуск. None — сессия без агента: работает в режиме
    /// «сообщение → запрос → ответ», как до появления агентов.
    agent_id: Option(String),
    provider_id: Option(String),
    model_id: Option(String),
    /// Текущие параметры сессии; восстанавливаются при её открытии.
    /// У сессии агента это переопределения поверх его настроек.
    params: RequestOptions,
  )
}

// ─── Сообщения ───────────────────────────────────────────────────────────────

pub type Role {
  System
  User
  Assistant
  /// Результат вызова инструмента. Формат OpenAI требует отдельной роли:
  /// модель должна отличать то, что вернул инструмент, от слов человека.
  Tool
}

pub fn role_to_string(role: Role) -> String {
  case role {
    System -> "system"
    User -> "user"
    Assistant -> "assistant"
    Tool -> "tool"
  }
}

pub fn role_from_string(value: String) -> Result(Role, Nil) {
  case value {
    "system" -> Ok(System)
    "user" -> Ok(User)
    "assistant" -> Ok(Assistant)
    "tool" -> Ok(Tool)
    _ -> Error(Nil)
  }
}

pub type MessageStatus {
  /// Запрос отправлен, ответ ещё не получен.
  Pending
  /// Ответ получен и разобран. Имя не `Ok`, чтобы не перекрывать `Result`.
  Done
  Failed
}

pub fn status_to_string(status: MessageStatus) -> String {
  case status {
    Pending -> "pending"
    Done -> "ok"
    Failed -> "error"
  }
}

pub fn status_from_string(value: String) -> Result(MessageStatus, Nil) {
  case value {
    "pending" -> Ok(Pending)
    "ok" -> Ok(Done)
    "error" -> Ok(Failed)
    _ -> Error(Nil)
  }
}

/// Запрос модели на вызов инструмента.
///
/// `arguments` остаётся строкой, а не разобранным объектом: модель иногда
/// присылает невалидный JSON, и это должно стать ошибкой инструмента,
/// а не ошибкой разбора всего ответа.
pub type ToolCall {
  ToolCall(id: String, name: String, arguments: String)
}

/// Расход токенов, если провайдер его сообщил.
pub type Usage {
  Usage(prompt_tokens: Int, completion_tokens: Int, total_tokens: Int)
}

/// Сообщение в диалоге.
///
/// Запрос и ответ — две отдельные строки с соседним `seq`. У строки `User`
/// заполнен `raw_request`, у `Assistant` — `raw_response`. Сырые тела
/// хранятся как есть, форматирование делает клиент при разворачивании.
pub type Message {
  Message(
    id: String,
    session_id: String,
    seq: Int,
    role: Role,
    /// Текст для показа в диалоге.
    content: String,
    /// Рассуждения модели, если провайдер их вернул отдельным полем.
    reasoning: Option(String),
    provider_id: Option(String),
    model_id: Option(String),
    status: MessageStatus,
    error: Option(String),
    /// Снимок параметров на момент отправки — неизменяемый.
    params: Option(RequestOptions),
    /// True, если тело запроса пользователь правил руками.
    hand_edited: Bool,
    raw_request: Option(String),
    raw_response: Option(String),
    http_status: Option(Int),
    latency_ms: Option(Int),
    usage: Option(Usage),
    /// Для ответа — id запроса, на который он отвечает.
    ///
    /// Номера пары не обязательно соседние: при параллельных отправках
    /// между запросом и ответом вклиниваются чужие строки. Поэтому связь
    /// хранится явно, а не выводится из `seq`. У сообщений, созданных до
    /// появления поля, здесь `None` — для них пара ищется по соседству.
    reply_to: Option(String),
    /// К какому заданию относится шаг. None — сообщение вне заданий.
    task_id: Option(String),
    /// Номер обращения к LLM внутри задания, с 1.
    ///
    /// Дублирует `seq` по смыслу, но не по области: `seq` сквозной по
    /// сессии (на нём держится порядок ленты), `step` локальный для
    /// задания. Дублирование осознанное.
    step: Option(Int),
    /// Запросы на вызов инструментов — заполнены у ответа модели.
    ///
    /// Протокол требует вернуть их модели вместе с результатами, поэтому
    /// они хранятся, а не восстанавливаются из сырого тела.
    tool_calls: List(ToolCall),
    /// Какой вызов выполнила эта строка — у сообщений с ролью `Tool`.
    tool_call_id: Option(String),
    created_at: Int,
  )
}

// ─── Поиск по каталогу ───────────────────────────────────────────────────────

pub fn find_provider(
  providers: List(Provider),
  id: String,
) -> Result(Provider, Nil) {
  list.find(providers, fn(provider) { provider.id == id })
}

/// Все модели провайдера одним списком, без деления на группы.
pub fn provider_models(provider: Provider) -> List(ModelInfo) {
  list.flat_map(provider.groups, fn(group) { group.models })
}

pub fn find_model(
  provider: Provider,
  model_id: String,
) -> Result(ModelInfo, Nil) {
  list.find(provider_models(provider), fn(model) { model.id == model_id })
}

/// Допустимые значения усилия рассуждений для модели.
pub fn reasoning_efforts(model: ModelInfo) -> List(String) {
  case model.reasoning {
    NoReasoning -> []
    OptionalReasoning(efforts: efforts, ..) -> efforts
    AlwaysReasoning(efforts: efforts, ..) -> efforts
  }
}

/// Усилие по умолчанию, если модель вообще рассуждает.
pub fn default_effort(model: ModelInfo) -> Option(String) {
  case model.reasoning {
    NoReasoning -> None
    OptionalReasoning(default_effort: effort, ..) -> Some(effort)
    AlwaysReasoning(default_effort: effort, ..) -> Some(effort)
  }
}

/// Можно ли выключить рассуждения. У моделей kimi — нельзя.
pub fn can_disable_reasoning(model: ModelInfo) -> Bool {
  case model.reasoning {
    OptionalReasoning(..) -> True
    NoReasoning | AlwaysReasoning(..) -> False
  }
}

pub fn supports_reasoning(model: ModelInfo) -> Bool {
  case model.reasoning {
    NoReasoning -> False
    OptionalReasoning(..) | AlwaysReasoning(..) -> True
  }
}
