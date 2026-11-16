//// Тесты памяти агента.
////
//// Проверяется сборка слоёв и, главное, бюджет: любая комбинация рано
//// или поздно переполнит контекст, и срезать лишнее должны мы, а не
//// провайдер отказом.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import server/agent/memory
import server/db
import server/repo/agents
import server/repo/memory as memory_repo
import server/repo/messages
import server/repo/sessions
import server/repo/tasks
import shared/types
import sqlight

fn with_db(run: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(connection) = db.connect_memory()
  let result = run(connection)
  let assert Ok(Nil) = sqlight.close(connection)
  result
}

/// Модель с заданной длиной контекста — для проверки бюджета.
fn model(context_length: Int) -> types.ModelInfo {
  types.ModelInfo(
    id: "test/model",
    title: "Тестовая",
    context_length:,
    max_output_tokens: 4096,
    vision: False,
    tools: True,
    reasoning: types.NoReasoning,
  )
}

/// 1…count. В stdlib этой версии нет `list.range`.
fn numbers(count: Int) -> List(Int) {
  case count <= 0 {
    True -> []
    False -> list.append(numbers(count - 1), [count])
  }
}

/// Сессия агента с несколькими завершёнными заданиями.
fn session_with_tasks(
  connection: sqlight.Connection,
  count: Int,
) -> types.Session {
  let assert Ok(agent) =
    agents.create(connection, agents.new("А", "veai", "Anthropic/sonnet-5"))
  let assert Ok(session) =
    sessions.create_for_agent(connection, Some(agent.id), None, None, None)

  numbers(count)
  |> list.each(fn(n) {
    let number = string.inspect(n)
    let assert Ok(task) =
      tasks.create(connection, session.id, "задание " <> number)
    let assert Ok(_) =
      tasks.finish(
        connection,
        task.id,
        types.TaskDone,
        Some("итог " <> number),
        None,
        1,
      )
  })

  session
}

// ─── Окно ────────────────────────────────────────────────────────────────────

/// Без памяти агент начинает каждое задание с чистого листа — поведение
/// до появления этой возможности.
pub fn no_memory_returns_nothing_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 3)

  let history =
    memory.build(
      connection,
      session.id,
      "tsk_current",
      types.no_memory(),
      model(100_000),
      [],
    )

  assert history == []
}

/// Пары «задание → итог»: по два сообщения на задание, без шагов.
pub fn outcomes_returns_prompt_and_result_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 2)

  let history =
    memory.build(
      connection,
      session.id,
      "tsk_current",
      types.Memory(
        window: types.Outcomes(10),
        summary: types.NoSummary,
        facts: False,
        budget_chars: 0,
      ),
      model(100_000),
      [],
    )

  assert list.length(history) == 4
  let texts = list.map(history, fn(message) { message.content })
  assert texts == ["задание 1", "итог 1", "задание 2", "итог 2"]
}

/// Окно ограничено: из пяти заданий берутся последние два.
pub fn outcomes_keeps_only_recent_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 5)

  let history =
    memory.build(
      connection,
      session.id,
      "tsk_current",
      types.Memory(
        window: types.Outcomes(2),
        summary: types.NoSummary,
        facts: False,
        budget_chars: 0,
      ),
      model(100_000),
      [],
    )

  let texts = list.map(history, fn(message) { message.content })
  assert texts == ["задание 4", "итог 4", "задание 5", "итог 5"]
}

/// Текущее задание не попадает в память: оно придёт отдельно, и
/// дублирование сбило бы модель.
pub fn window_excludes_current_task_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 2)
  let assert Ok(all) = tasks.list_for_session(connection, session.id)
  let assert [_, second] = all

  let history =
    memory.build(
      connection,
      session.id,
      second.id,
      types.Memory(
        window: types.Outcomes(10),
        summary: types.NoSummary,
        facts: False,
        budget_chars: 0,
      ),
      model(100_000),
      [],
    )

  let texts = list.map(history, fn(message) { message.content })
  assert texts == ["задание 1", "итог 1"]
}

/// Незавершённое задание в память не идёт: итога у него нет, а место
/// оно заняло бы наравне с остальными.
pub fn window_skips_unfinished_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 1)
  let assert Ok(_) = tasks.create(connection, session.id, "ещё не готово")

  let history =
    memory.build(
      connection,
      session.id,
      "tsk_current",
      types.Memory(
        window: types.Outcomes(10),
        summary: types.NoSummary,
        facts: False,
        budget_chars: 0,
      ),
      model(100_000),
      [],
    )

  let texts = list.map(history, fn(message) { message.content })
  assert texts == ["задание 1", "итог 1"]
}

// ─── Бюджет ──────────────────────────────────────────────────────────────────

/// Без явного предела берётся четверть контекста модели.
pub fn budget_defaults_to_context_share_test() {
  let memory_config =
    types.Memory(
      window: types.Everything,
      summary: types.NoSummary,
      facts: False,
      budget_chars: 0,
    )

  // 100_000 токенов × 4 символа ÷ 4 = 100_000 символов.
  assert memory.budget_of(memory_config, model(100_000)) == 100_000
}

pub fn budget_respects_explicit_value_test() {
  let memory_config =
    types.Memory(
      window: types.Everything,
      summary: types.NoSummary,
      facts: False,
      budget_chars: 5000,
    )

  assert memory.budget_of(memory_config, model(1_000_000)) == 5000
}

/// Старое вытесняется первым: недавнее важнее давнего.
pub fn fit_drops_oldest_first_test() {
  let history =
    list.map(["древнее", "старое", "недавнее"], fn(text) {
      types.Message(..blank_message(), content: text)
    })

  // Каждое сообщение — 14 байт, в бюджет на 30 влезают два последних.
  let kept = memory.fit(history, 30)
  let texts = list.map(kept, fn(message) { message.content })

  assert texts == ["старое", "недавнее"]
}

/// Если не влезает даже последнее — лучше забыть всё, чем получить от
/// провайдера отказ на весь запрос.
pub fn fit_returns_empty_when_budget_tiny_test() {
  let history = [
    types.Message(..blank_message(), content: string.repeat("x", 100)),
  ]

  assert memory.fit(history, 10) == []
  assert memory.fit(history, 0) == []
}

/// Факты и пересказ не вытесняются — ради них память и нужна.
pub fn budget_preserves_facts_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 5)
  let assert Ok(_) =
    memory_repo.remember(connection, session.id, "пользователя зовут Пётр")

  let history =
    memory.build(
      connection,
      session.id,
      "tsk_current",
      types.Memory(
        window: types.Outcomes(10),
        summary: types.NoSummary,
        facts: True,
        // Хватит на факты и почти ни на что больше.
        budget_chars: 50,
      ),
      model(100_000),
      [],
    )

  let joined =
    history
    |> list.map(fn(message) { message.content })
    |> string.join(" ")

  assert string.contains(joined, "Пётр")
}

// ─── Факты ───────────────────────────────────────────────────────────────────

pub fn facts_appear_as_system_message_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 0)
  let assert Ok(_) = memory_repo.remember(connection, session.id, "любит кофе")

  let history =
    memory.build(
      connection,
      session.id,
      "tsk_current",
      types.Memory(
        window: types.NoMemory,
        summary: types.NoSummary,
        facts: True,
        budget_chars: 0,
      ),
      model(100_000),
      [],
    )

  let assert [first] = history
  // Роль `system`, а не `user`: это знание об обстановке, а не реплика.
  assert first.role == types.System
  assert string.contains(first.content, "любит кофе")
}

/// Модель склонна повторять «запомни» на каждом шаге — дубли не нужны.
pub fn remember_ignores_duplicates_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 0)

  let assert Ok(_) = memory_repo.remember(connection, session.id, "любит кофе")
  let assert Ok(_) = memory_repo.remember(connection, session.id, "Любит кофе")
  let assert Ok(_) =
    memory_repo.remember(connection, session.id, "  любит кофе  ")

  let assert Ok(facts) = memory_repo.list_facts(connection, session.id)
  assert list.length(facts) == 1
}

pub fn forget_removes_matching_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 0)
  let assert Ok(_) = memory_repo.remember(connection, session.id, "любит кофе")
  let assert Ok(_) =
    memory_repo.remember(connection, session.id, "живёт в Томске")

  let assert Ok(count) = memory_repo.forget(connection, session.id, "кофе")
  assert count == 1

  let assert Ok(facts) = memory_repo.list_facts(connection, session.id)
  assert list.map(facts, fn(fact) { fact.text }) == ["живёт в Томске"]
}

/// Ноль — не ошибка, но агенту полезно знать, что ничего не совпало.
pub fn forget_reports_zero_when_nothing_matches_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 0)
  let assert Ok(_) = memory_repo.remember(connection, session.id, "любит кофе")

  let assert Ok(count) = memory_repo.forget(connection, session.id, "чай")
  assert count == 0
}

/// Факты одной сессии не видны другой: это память запуска, а не агента.
pub fn facts_are_per_session_test() {
  use connection <- with_db
  let mine = session_with_tasks(connection, 0)
  let other = session_with_tasks(connection, 0)

  let assert Ok(_) = memory_repo.remember(connection, mine.id, "мой факт")

  let assert Ok(facts) = memory_repo.list_facts(connection, other.id)
  assert facts == []
}

// ─── Пересказ ────────────────────────────────────────────────────────────────

pub fn summary_appears_in_history_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 0)
  let assert Ok(_) =
    memory_repo.save_summary(connection, session.id, "обсудили отчёт", 10, 5)

  let history =
    memory.build(
      connection,
      session.id,
      "tsk_current",
      types.Memory(
        window: types.NoMemory,
        summary: types.SummarizeEvery(20),
        facts: False,
        budget_chars: 0,
      ),
      model(100_000),
      [],
    )

  let assert [first] = history
  assert first.role == types.System
  assert string.contains(first.content, "обсудили отчёт")
}

/// Берётся последний пересказ: он включает в себя все предыдущие.
pub fn latest_summary_wins_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 0)
  let assert Ok(_) =
    memory_repo.save_summary(connection, session.id, "первый", 10, 5)
  let assert Ok(_) =
    memory_repo.save_summary(connection, session.id, "второй", 20, 5)

  let assert Ok(latest) = memory_repo.latest_summary(connection, session.id)
  assert latest.text == "второй"
  assert latest.covers_through_seq == 20
}

/// Пересказ не трогает сообщения: сырые тела остаются в БД, и
/// наблюдаемость не страдает.
pub fn summary_does_not_delete_messages_test() {
  use connection <- with_db
  let session = session_with_tasks(connection, 1)
  let assert Ok(task) = tasks.create(connection, session.id, "ещё одно")
  let assert Ok(_) =
    messages.insert(
      connection,
      messages.NewMessage(
        ..messages.new(session.id, types.User, "важное сообщение"),
        task_id: Some(task.id),
      ),
    )

  let assert Ok(_) =
    memory_repo.save_summary(connection, session.id, "пересказ", 99, 10)

  let assert Ok(all) = messages.list_for_session(connection, session.id)
  assert list.length(all) == 1
}

// ─── Оценка токенов ──────────────────────────────────────────────────────────

pub fn estimate_tokens_is_proportional_test() {
  assert memory.estimate_tokens(string.repeat("a", 400)) == 100
  assert memory.estimate_tokens("") == 0
}

// ─── Мелочи ──────────────────────────────────────────────────────────────────

fn blank_message() -> types.Message {
  types.Message(
    id: "msg",
    session_id: "ses",
    seq: 1,
    role: types.User,
    content: "",
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
