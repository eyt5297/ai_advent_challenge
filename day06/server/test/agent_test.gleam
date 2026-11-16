//// Тесты цикла агента: слияние настроек и жизненный цикл задания.
////
//// Обмен с провайдером здесь не проверяется — для него нужен живой
//// транспорт, это делают e2e-тесты против мока.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import server/agent/loop
import server/db
import server/repo/agents
import server/repo/messages
import server/repo/sessions
import server/repo/tasks
import shared/types
import sqlight.{type Connection}

fn with_db(run: fn(Connection) -> a) -> a {
  let assert Ok(connection) = db.connect_memory()
  let result = run(connection)
  let assert Ok(Nil) = sqlight.close(connection)
  result
}

fn sample_agent() -> types.Agent {
  types.Agent(
    id: "agt-1",
    name: "Агент",
    description: "",
    system_prompt: "Ты помощник",
    provider_id: "veai",
    model_id: "Anthropic/sonnet-5",
    params: types.RequestOptions(
      ..types.default_options(),
      temperature: Some(0.2),
      max_tokens: Some(1000),
    ),
    max_steps: 1,
    tools: [],
    memory: types.no_memory(),
    created_at: 0,
    updated_at: 0,
  )
}

fn sample_session() -> types.Session {
  types.Session(
    id: "ses-1",
    title: "запуск",
    created_at: 0,
    updated_at: 0,
    agent_id: Some("agt-1"),
    provider_id: None,
    model_id: None,
    params: types.default_options(),
  )
}

// ─── Слияние настроек ────────────────────────────────────────────────────────

/// Без переопределений действуют настройки агента.
pub fn merge_takes_agent_defaults_test() {
  let merged = loop.merge_options(sample_agent(), sample_session())

  assert merged.temperature == Some(0.2)
  assert merged.max_tokens == Some(1000)
  assert merged.system_prompt == Some("Ты помощник")
}

/// Сессия переопределяет агента по полю, а не целиком.
pub fn merge_overrides_per_field_test() {
  let session =
    types.Session(
      ..sample_session(),
      params: types.RequestOptions(
        ..types.default_options(),
        temperature: Some(0.9),
      ),
    )

  let merged = loop.merge_options(sample_agent(), session)

  assert merged.temperature == Some(0.9)
  // max_tokens не задан в сессии — остаётся агентский.
  assert merged.max_tokens == Some(1000)
}

/// Промпт агента не переопределяется: запуск с другим промптом — это
/// другой агент, а не другие параметры.
pub fn merge_keeps_agent_prompt_test() {
  let session =
    types.Session(
      ..sample_session(),
      params: types.RequestOptions(
        ..types.default_options(),
        system_prompt: Some("подменённый промпт"),
      ),
    )

  let merged = loop.merge_options(sample_agent(), session)
  assert merged.system_prompt == Some("Ты помощник")
}

/// Пустой промпт не должен попасть в запрос отдельным сообщением.
pub fn merge_drops_blank_prompt_test() {
  let agent = types.Agent(..sample_agent(), system_prompt: "   ")
  let merged = loop.merge_options(agent, sample_session())
  assert merged.system_prompt == None
}

/// Модель берётся у агента, но сессия может её заменить — это нужно,
/// чтобы сравнить поведение одного агента на разных моделях.
pub fn merge_model_prefers_session_test() {
  assert loop.merge_model(sample_agent(), sample_session())
    == #("veai", "Anthropic/sonnet-5")

  let session =
    types.Session(
      ..sample_session(),
      provider_id: Some("kimi"),
      model_id: Some("k3.1-pro"),
    )
  assert loop.merge_model(sample_agent(), session) == #("kimi", "k3.1-pro")
}

// ─── Создание задания ────────────────────────────────────────────────────────

fn stored_session(connection: Connection) -> types.Session {
  let assert Ok(agent) =
    agents.create(connection, agents.new("Агент", "veai", "Anthropic/sonnet-5"))
  let assert Ok(session) =
    sessions.create_for_agent(connection, Some(agent.id), None, None, None)
  session
}

pub fn start_creates_running_task_test() {
  use connection <- with_db
  let session = stored_session(connection)

  let assert Ok(task) = loop.start(connection, session, "  сделай дело  ")

  assert task.status == types.Running
  // Текст обрезается при сохранении, а не при показе.
  assert task.prompt == "сделай дело"
  assert task.steps == 0
}

/// Сессия без агента заданий не принимает: выполнять их некому.
pub fn start_requires_agent_test() {
  use connection <- with_db
  let assert Ok(plain) = sessions.create(connection, None, None, None)

  assert loop.start(connection, plain, "задание") == Error(loop.NoAgent)
}

pub fn start_rejects_empty_prompt_test() {
  use connection <- with_db
  let session = stored_session(connection)

  assert loop.start(connection, session, "   ") == Error(loop.EmptyPrompt)
}

/// Задания одной сессии идут последовательно.
pub fn start_rejects_second_task_test() {
  use connection <- with_db
  let session = stored_session(connection)

  let assert Ok(first) = loop.start(connection, session, "первое")
  assert loop.start(connection, session, "второе") == Error(loop.Busy(first.id))
}

/// Упавшее задание не блокирует сессию навсегда.
pub fn failed_task_releases_session_test() {
  use connection <- with_db
  let session = stored_session(connection)

  let assert Ok(first) = loop.start(connection, session, "упадёт")
  let assert Ok(_) =
    tasks.finish(connection, first.id, types.TaskFailed, None, Some("сбой"), 0)

  let assert Ok(_) = loop.start(connection, session, "следующее")
  Nil
}

// ─── Ошибки ──────────────────────────────────────────────────────────────────

pub fn error_codes_and_statuses_test() {
  assert loop.error_code(loop.NoAgent) == "session_without_agent"
  assert loop.error_code(loop.Busy("tsk-1")) == "task_already_running"
  assert loop.error_code(loop.EmptyPrompt) == "empty_prompt"

  assert loop.http_status(loop.NoAgent) == 400
  assert loop.http_status(loop.EmptyPrompt) == 400
  assert loop.http_status(loop.Busy("tsk-1")) == 409
  assert loop.http_status(loop.Storage("…")) == 500
}

/// Текст ошибки должен называть причину, а не только её вид.
pub fn error_descriptions_mention_cause_test() {
  assert string.contains(loop.describe(loop.Busy("tsk-7")), "tsk-7")
  assert string.contains(loop.describe(loop.EmptyPrompt), "пуст")
  assert string.contains(loop.describe(loop.NoAgent), "агент")
}

// ─── Шаги задания ────────────────────────────────────────────────────────────

/// Шаги помечаются заданием и номером — на этом держится лента.
pub fn steps_are_attributed_test() {
  use connection <- with_db
  let session = stored_session(connection)
  let assert Ok(task) = loop.start(connection, session, "задание")

  let assert Ok(question) =
    messages.insert(
      connection,
      messages.NewMessage(
        ..messages.new(session.id, types.User, "шаг"),
        task_id: Some(task.id),
        step: Some(1),
      ),
    )

  assert question.task_id == Some(task.id)
  assert question.step == Some(1)

  let assert Ok(steps) = messages.list_for_task(connection, task.id)
  assert list.length(steps) == 1
}

/// Шаг задания нельзя удалить по отдельности: без него задание
/// невоспроизводимо. Защита на сервере, а не только в интерфейсе.
pub fn step_cannot_be_deleted_alone_test() {
  use connection <- with_db
  let session = stored_session(connection)
  let assert Ok(task) = loop.start(connection, session, "задание")

  let assert Ok(step) =
    messages.insert(
      connection,
      messages.NewMessage(
        ..messages.new(session.id, types.User, "шаг"),
        task_id: Some(task.id),
        step: Some(1),
      ),
    )

  assert messages.delete_exchange(connection, step.id)
    == Error(messages.BelongsToTask(task.id))

  // Шаг на месте: отказ не должен быть частичным.
  let assert Ok(remaining) = messages.list_for_task(connection, task.id)
  assert list.length(remaining) == 1
}

/// Сообщения вне заданий удаляются по-прежнему.
pub fn loose_message_still_deletable_test() {
  use connection <- with_db
  let assert Ok(plain) = sessions.create(connection, None, None, None)

  let assert Ok(question) =
    messages.insert(connection, messages.new(plain.id, types.User, "вопрос"))
  let assert Ok(_) =
    messages.insert(
      connection,
      messages.NewMessage(
        ..messages.new(plain.id, types.Assistant, "ответ"),
        reply_to: Some(question.id),
      ),
    )

  let assert Ok(deleted) = messages.delete_exchange(connection, question.id)
  assert list.length(deleted) == 2
}
