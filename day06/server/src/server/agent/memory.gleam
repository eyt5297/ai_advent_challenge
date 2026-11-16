//// Сборка истории для запроса: что агент помнит, начиная новое задание.
////
//// Слои складываются в таком порядке:
////
////     факты → пересказ → окно прошлых заданий → текущее задание
////
//// Системный промпт добавляется ниже по течению, в `build_request_body`:
//// точка расширения не должна знать про агентов.
////
//// Модуль не обращается к LLM — только читает БД и режет списки. Сжатие
//// живёт отдельно (`agent/summarize.gleam`), потому что требует вызова
//// модели, а это совсем другая цена ошибки.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import server/repo/memory as memory_repo
import server/repo/messages
import server/repo/tasks
import shared/types.{
  type Memory, type Message, type ModelInfo, type Task, Everything, NoMemory,
  Outcomes, Transcripts,
}
import sqlight.{type Connection}

/// Оценка «символов на токен».
///
/// Точный подсчёт требует токенизатора, которого у нас нет. Четыре —
/// заниженная оценка для русского текста (там скорее 2–3), и это
/// намеренно: лучше отправить меньше, чем получить отказ провайдера.
pub const chars_per_token = 4

/// Какую долю контекста модели занимать историей.
///
/// Остальное нужно системному промпту, текущему заданию, описаниям
/// инструментов и самому ответу.
const context_share = 4

/// Собирает историю для запроса.
///
/// Текущее задание передаётся отдельно (`current`) и не режется: это то,
/// над чем агент работает прямо сейчас.
pub fn build(
  connection: Connection,
  session_id: String,
  task_id: String,
  memory: Memory,
  model: ModelInfo,
  current: List(Message),
) -> List(Message) {
  let budget = budget_of(memory, model)

  let facts = case memory.facts {
    False -> []
    True -> fact_messages(connection, session_id)
  }

  let summary = case memory.summary {
    types.NoSummary -> []
    types.SummarizeEvery(..) -> summary_messages(connection, session_id)
  }

  let window = window_messages(connection, session_id, task_id, memory.window)

  // Режется только окно: факты и пересказ — то, ради чего всё делалось,
  // и вытеснять их бессмысленно. Текущее задание тем более.
  let reserved = char_size(facts) + char_size(summary) + char_size(current)

  list.flatten([facts, summary, fit(window, budget - reserved), current])
}

/// Предел истории в символах.
pub fn budget_of(memory: Memory, model: ModelInfo) -> Int {
  case memory.budget_chars > 0 {
    True -> memory.budget_chars
    False ->
      case model.context_length > 0 {
        True -> model.context_length * chars_per_token / context_share
        // Каталог не знает длины контекста — берём осторожное значение.
        False -> 24_000
      }
  }
}

/// Оценка числа токенов в тексте.
pub fn estimate_tokens(text: String) -> Int {
  string.byte_size(text) / chars_per_token
}

// ─── Слои ────────────────────────────────────────────────────────────────────

/// Факты одной строкой, ролью `system`.
///
/// Не `user`: это не реплика в диалоге, а знание об обстановке. Модели
/// заметно лучше удерживают такое, когда оно отделено от переписки.
fn fact_messages(connection: Connection, session_id: String) -> List(Message) {
  case memory_repo.list_facts(connection, session_id) {
    Error(_) -> []
    Ok([]) -> []
    Ok(facts) -> {
      let lines =
        facts
        |> list.map(fn(fact) { "- " <> fact.text })
        |> string.join("\n")

      [synthetic(session_id, types.System, "Запомненное ранее:\n" <> lines)]
    }
  }
}

fn summary_messages(
  connection: Connection,
  session_id: String,
) -> List(Message) {
  case memory_repo.latest_summary(connection, session_id) {
    Error(_) -> []
    Ok(summary) ->
      case string.trim(summary.text) {
        "" -> []
        text -> [
          synthetic(
            session_id,
            types.System,
            "Краткое изложение более ранней части разговора:\n" <> text,
          ),
        ]
      }
  }
}

/// Окно прошлых заданий.
fn window_messages(
  connection: Connection,
  session_id: String,
  task_id: String,
  window: types.MemoryWindow,
) -> List(Message) {
  case window {
    NoMemory -> []

    Outcomes(tasks: count) ->
      past_tasks(connection, session_id, task_id, count)
      |> list.flat_map(fn(task) { outcome_pair(session_id, task) })

    Transcripts(tasks: count) ->
      past_tasks(connection, session_id, task_id, count)
      |> list.flat_map(fn(task) { transcript_of(connection, task) })

    Everything ->
      case messages.list_for_session(connection, session_id) {
        Error(_) -> []
        // Текущее задание придёт отдельно — иначе продублируется.
        Ok(all) ->
          list.filter(all, fn(message) {
            message.task_id != Some(task_id) && message.task_id != None
          })
      }
  }
}

/// Последние `count` завершённых заданий, кроме текущего, в хронологии.
///
/// Только `done`: у выполняющегося нет итога, у упавшего он бесполезен,
/// а место в контексте они заняли бы наравне с остальными.
fn past_tasks(
  connection: Connection,
  session_id: String,
  task_id: String,
  count: Int,
) -> List(Task) {
  case tasks.list_for_session(connection, session_id) {
    Error(_) -> []
    Ok(all) ->
      all
      |> list.filter(fn(task) {
        task.id != task_id && task.status == types.TaskDone
      })
      |> last(count)
  }
}

/// Задание и итог — то, что от задания остаётся, когда подробности
/// уже не нужны.
fn outcome_pair(session_id: String, task: Task) -> List(Message) {
  case option.unwrap(task.result, "") {
    "" -> []
    result -> [
      synthetic(session_id, types.User, task.prompt),
      synthetic(session_id, types.Assistant, result),
    ]
  }
}

/// Полная расшифровка задания, со всеми вызовами инструментов.
fn transcript_of(connection: Connection, task: Task) -> List(Message) {
  case messages.list_for_task(connection, task.id) {
    Error(_) -> []
    Ok(rows) -> rows
  }
}

// ─── Бюджет ──────────────────────────────────────────────────────────────────

/// Урезает список с головы, пока он не влезет в бюджет.
///
/// С головы, а не с хвоста: недавнее важнее давнего. Если не влезает
/// даже последнее сообщение — отдаём пустой список, пусть лучше агент
/// забудет, чем провайдер отвергнет запрос целиком.
pub fn fit(history: List(Message), budget: Int) -> List(Message) {
  case budget <= 0 {
    True -> []
    False -> drop_until_fits(history, budget)
  }
}

fn drop_until_fits(history: List(Message), budget: Int) -> List(Message) {
  case char_size(history) <= budget {
    True -> history
    False ->
      case history {
        [] -> []
        // Пара «задание → итог» рвётся по одному сообщению: протокол
        // это допускает, а более умная резка потребовала бы знать
        // структуру, которой у истории уже нет.
        [_, ..rest] -> drop_until_fits(rest, budget)
      }
  }
}

pub fn char_size(history: List(Message)) -> Int {
  list.fold(history, 0, fn(total, message) {
    total + string.byte_size(message.content) + tool_call_size(message)
  })
}

fn tool_call_size(message: Message) -> Int {
  list.fold(message.tool_calls, 0, fn(total, call) {
    total + string.byte_size(call.name) + string.byte_size(call.arguments)
  })
}

// ─── Мелочи ──────────────────────────────────────────────────────────────────

/// Сообщение, которого нет в БД: пересказ, факты, свёрнутый итог.
///
/// Нужно потому, что `build_request_body` принимает список `Message` —
/// и это правильно: точка расширения не должна знать, откуда взялся
/// каждый элемент истории.
fn synthetic(session_id: String, role: types.Role, content: String) -> Message {
  types.Message(
    id: "",
    session_id:,
    seq: 0,
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
    created_at: 0,
  )
}

fn last(items: List(a), count: Int) -> List(a) {
  let extra = list.length(items) - int.max(count, 0)
  case extra > 0 {
    True -> list.drop(items, extra)
    False -> items
  }
}

pub fn describe_window(window: types.MemoryWindow) -> String {
  case window {
    NoMemory -> "без памяти"
    Outcomes(tasks:) -> "итоги " <> int.to_string(tasks) <> " заданий"
    Transcripts(tasks:) -> "расшифровки " <> int.to_string(tasks) <> " заданий"
    Everything -> "вся история"
  }
}

/// Сколько сообщений сессии ещё не вошло в пересказ.
///
/// На этом держится порог сжатия: как только вытесненных накопилось
/// больше `SummarizeEvery(n)`, пора звать модель.
pub fn uncovered_count(
  connection: Connection,
  session_id: String,
  through_seq: Int,
) -> Int {
  case messages.list_for_session(connection, session_id) {
    Error(_) -> 0
    Ok(all) ->
      all
      |> list.filter(fn(message) { message.seq <= through_seq })
      |> list.length
  }
}

/// Пересказ, уже сохранённый для сессии, — для следующего сжатия.
pub fn previous_summary(
  connection: Connection,
  session_id: String,
) -> Result(types.Summary, Nil) {
  memory_repo.latest_summary(connection, session_id)
  |> result.replace_error(Nil)
}
