//// Тесты схемы и репозиториев на БД в памяти.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
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

// ─── Миграции ────────────────────────────────────────────────────────────────

pub fn migrations_are_idempotent_test() {
  // Повторный connect к той же памяти невозможен, поэтому проверяем, что
  // версия записана и таблицы на месте.
  use connection <- with_db
  let assert Ok(rows) =
    sqlight.query(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      on: connection,
      with: [],
      expecting: decode_first_string(),
    )
  assert list.contains(rows, "sessions")
  assert list.contains(rows, "messages")
  assert list.contains(rows, "schema_migrations")
}

pub fn foreign_keys_are_on_test() {
  use connection <- with_db
  let assert Ok([enabled]) =
    sqlight.query(
      "PRAGMA foreign_keys",
      on: connection,
      with: [],
      expecting: decode_first_int(),
    )
  assert enabled == 1
}

// ─── Сессии ──────────────────────────────────────────────────────────────────

pub fn create_and_get_session_test() {
  use connection <- with_db
  let assert Ok(created) = sessions.create(connection, None, None, None)
  assert created.title == sessions.default_title
  assert created.params == types.default_options()

  let assert Ok(loaded) = sessions.get(connection, created.id)
  assert loaded == created
}

pub fn get_missing_session_test() {
  use connection <- with_db
  assert sessions.get(connection, "нет-такой") == Error(sessions.NotFound)
}

pub fn list_sessions_newest_first_test() {
  use connection <- with_db
  let assert Ok(first) = sessions.create(connection, Some("первая"), None, None)
  let assert Ok(second) =
    sessions.create(connection, Some("вторая"), None, None)

  // Вторая создана позже, значит должна быть выше.
  let assert Ok([top, bottom]) = sessions.list(connection)
  assert top.id == second.id
  assert bottom.id == first.id
}

pub fn update_session_partially_test() {
  use connection <- with_db
  let assert Ok(created) =
    sessions.create(connection, Some("исходное"), Some("veai"), Some("m1"))

  // Меняем только модель — остальное должно уцелеть.
  let assert Ok(updated) =
    sessions.update(connection, created.id, None, None, Some("m2"), None)
  assert updated.title == "исходное"
  assert updated.provider_id == Some("veai")
  assert updated.model_id == Some("m2")
}

pub fn update_session_params_test() {
  use connection <- with_db
  let assert Ok(created) = sessions.create(connection, None, None, None)
  let params =
    types.RequestOptions(
      ..types.default_options(),
      temperature: Some(0.3),
      reasoning_effort: Some("high"),
    )

  let assert Ok(updated) =
    sessions.update(connection, created.id, None, None, None, Some(params))
  assert updated.params == params

  // И переживает перечитывание.
  let assert Ok(reloaded) = sessions.get(connection, created.id)
  assert reloaded.params == params
}

pub fn delete_session_cascades_messages_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)
  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.User, "привет"))

  let assert Ok(Nil) = sessions.delete(connection, session.id)
  assert sessions.get(connection, session.id) == Error(sessions.NotFound)
  let assert Ok([]) = messages.list_for_session(connection, session.id)
}

// ─── Автозаголовок ───────────────────────────────────────────────────────────

pub fn autotitle_sets_title_from_first_message_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)
  let assert Ok(Nil) =
    sessions.autotitle(connection, session.id, "как дела у тебя?")

  let assert Ok(updated) = sessions.get(connection, session.id)
  assert updated.title == "как дела у тебя?"
}

/// Имя, заданное пользователем, автозаголовок затирать не должен.
pub fn autotitle_keeps_manual_title_test() {
  use connection <- with_db
  let assert Ok(session) =
    sessions.create(connection, Some("моё имя"), None, None)
  let assert Ok(Nil) = sessions.autotitle(connection, session.id, "привет")

  let assert Ok(updated) = sessions.get(connection, session.id)
  assert updated.title == "моё имя"
}

pub fn title_from_content_collapses_newlines_test() {
  assert sessions.title_from_content("первая\nвторая") == "первая вторая"
}

pub fn title_from_content_truncates_test() {
  let title = sessions.title_from_content(string.repeat("а", 100))
  assert string.length(title) == 58
  assert string.ends_with(title, "…")
}

pub fn title_from_content_handles_blank_test() {
  assert sessions.title_from_content("   \n  ") == sessions.default_title
}

// ─── Сообщения ───────────────────────────────────────────────────────────────

pub fn insert_and_list_messages_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)

  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.User, "вопрос"))
  let assert Ok(_) =
    messages.insert(
      connection,
      messages.new(session.id, types.Assistant, "ответ"),
    )

  let assert Ok([first, second]) =
    messages.list_for_session(connection, session.id)
  assert first.content == "вопрос"
  assert first.role == types.User
  assert second.content == "ответ"
  assert second.role == types.Assistant
}

/// Номер присваивается самой вставкой и идёт по порядку.
pub fn insert_assigns_seq_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)
  assert messages.last_seq(connection, session.id) == Ok(0)

  let assert Ok(first) =
    messages.insert(connection, messages.new(session.id, types.User, "a"))
  assert first.seq == 1

  let assert Ok(second) =
    messages.insert(connection, messages.new(session.id, types.Assistant, "b"))
  assert second.seq == 2
  assert messages.last_seq(connection, session.id) == Ok(2)
}

/// Нумерация ведётся внутри сессии, а не глобально.
pub fn seq_is_per_session_test() {
  use connection <- with_db
  let assert Ok(one) = sessions.create(connection, None, None, None)
  let assert Ok(two) = sessions.create(connection, None, None, None)

  let assert Ok(_) =
    messages.insert(connection, messages.new(one.id, types.User, "a"))
  let assert Ok(_) =
    messages.insert(connection, messages.new(one.id, types.User, "b"))
  let assert Ok(other) =
    messages.insert(connection, messages.new(two.id, types.User, "c"))

  // Вторая сессия начинает с единицы, несмотря на строки первой.
  assert other.seq == 1
}

/// Уникальный индекс не даёт двум строкам сессии получить один номер.
///
/// Воспроизвести настоящую гонку в тесте нельзя — вставка атомарна.
/// Поэтому проверяем саму защиту: прямой INSERT с занятым номером должен
/// быть отвергнут базой.
pub fn duplicate_seq_is_rejected_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)
  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.User, "a"))

  let duplicate = "INSERT INTO messages
       (id, session_id, seq, role, content, status, hand_edited, created_at)
     VALUES ('msg_dup', '" <> session.id <> "', 1, 'user', 'b', 'ok', 0, 0)"

  assert sqlight.exec(duplicate, connection) |> result.is_error
}

/// Все поля сообщения должны переживать запись и чтение — это основа
/// отладочной ценности каркаса.
pub fn message_roundtrip_all_fields_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)
  let params =
    types.RequestOptions(..types.default_options(), temperature: Some(0.7))

  let draft =
    messages.NewMessage(
      ..messages.new(session.id, types.Assistant, "ответ"),
      reasoning: Some("рассуждения"),
      provider_id: Some("veai"),
      model_id: Some("Anthropic/sonnet-5"),
      status: types.Done,
      params: Some(params),
      hand_edited: True,
      raw_request: Some("{\"model\":\"m\"}"),
      raw_response: Some("{\"choices\":[]}"),
      http_status: Some(200),
      latency_ms: Some(842),
      usage: Some(types.Usage(10, 20, 30)),
    )

  let assert Ok(inserted) = messages.insert(connection, draft)
  let assert Ok(loaded) = messages.get(connection, inserted.id)

  assert loaded.reasoning == Some("рассуждения")
  assert loaded.params == Some(params)
  assert loaded.hand_edited == True
  assert loaded.raw_request == Some("{\"model\":\"m\"}")
  assert loaded.raw_response == Some("{\"choices\":[]}")
  assert loaded.http_status == Some(200)
  assert loaded.latency_ms == Some(842)
  assert loaded.usage == Some(types.Usage(10, 20, 30))
}

pub fn failed_message_roundtrip_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)

  let assert Ok(inserted) =
    messages.insert(
      connection,
      messages.NewMessage(
        ..messages.new(session.id, types.Assistant, ""),
        status: types.Failed,
        error: Some("429 rate limit"),
        raw_response: Some("{\"error\":{}}"),
        http_status: Some(429),
      ),
    )

  let assert Ok(loaded) = messages.get(connection, inserted.id)
  assert loaded.status == types.Failed
  assert loaded.error == Some("429 rate limit")
  // Сырое тело сохраняется даже у неудачного ответа.
  assert loaded.raw_response == Some("{\"error\":{}}")
}

// ─── Удаление обмена ─────────────────────────────────────────────────────────

/// Пара находится по явной связи, даже когда номера не соседние.
///
/// Так выглядят параллельные отправки: между запросом и его ответом
/// успевают вклиниться чужие строки.
pub fn delete_exchange_uses_reply_to_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)

  let assert Ok(first) =
    messages.insert(connection, messages.new(session.id, types.User, "в1"))
  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.User, "в2"))

  // Ответ на первый запрос приходит после второго — seq не соседние.
  let assert Ok(answer) =
    messages.insert(
      connection,
      messages.NewMessage(
        ..messages.new(session.id, types.Assistant, "о1"),
        reply_to: Some(first.id),
      ),
    )
  assert answer.seq == 3

  let assert Ok(deleted) = messages.delete_exchange(connection, first.id)
  assert list.length(deleted) == 2

  // Чужой запрос, оказавшийся между парой, не задет.
  let assert Ok(rest) = messages.list_for_session(connection, session.id)
  assert list.map(rest, fn(message) { message.content }) == ["в2"]
}

/// Связь работает и в обратную сторону — от ответа к запросу.
pub fn delete_exchange_from_answer_by_link_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)

  let assert Ok(question) =
    messages.insert(connection, messages.new(session.id, types.User, "в1"))
  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.User, "в2"))
  let assert Ok(answer) =
    messages.insert(
      connection,
      messages.NewMessage(
        ..messages.new(session.id, types.Assistant, "о1"),
        reply_to: Some(question.id),
      ),
    )

  let assert Ok(deleted) = messages.delete_exchange(connection, answer.id)
  assert list.length(deleted) == 2
  let assert Ok(rest) = messages.list_for_session(connection, session.id)
  assert list.map(rest, fn(message) { message.content }) == ["в2"]
}

/// Запасной путь для сообщений без `reply_to` — так выглядят строки,
/// записанные до появления поля. Пара определяется соседним номером.
pub fn delete_exchange_legacy_without_link_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)

  let assert Ok(question) =
    messages.insert(connection, messages.new(session.id, types.User, "в1"))
  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.Assistant, "о1"))
  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.User, "в2"))
  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.Assistant, "о2"))

  let assert Ok(deleted) = messages.delete_exchange(connection, question.id)
  assert list.length(deleted) == 2

  // Второй обмен не пострадал.
  let assert Ok(rest) = messages.list_for_session(connection, session.id)
  assert list.map(rest, fn(message) { message.content }) == ["в2", "о2"]
}

/// Удаление ответа забирает и вопрос — симметрично.
pub fn delete_exchange_from_answer_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)

  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.User, "в1"))
  let assert Ok(answer) =
    messages.insert(connection, messages.new(session.id, types.Assistant, "о1"))

  let assert Ok(deleted) = messages.delete_exchange(connection, answer.id)
  assert list.length(deleted) == 2
  let assert Ok([]) = messages.list_for_session(connection, session.id)
}

/// Вопрос без ответа (провайдер не ответил) удаляется в одиночку.
pub fn delete_exchange_without_pair_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)
  let assert Ok(lonely) =
    messages.insert(connection, messages.new(session.id, types.User, "в1"))

  let assert Ok(deleted) = messages.delete_exchange(connection, lonely.id)
  assert list.length(deleted) == 1
  let assert Ok([]) = messages.list_for_session(connection, session.id)
}

pub fn delete_missing_message_test() {
  use connection <- with_db
  assert messages.delete_exchange(connection, "нет-такого")
    == Error(messages.NotFound)
}

/// Удаление не должно сбивать нумерацию следующих сообщений.
pub fn delete_exchange_keeps_seq_monotonic_test() {
  use connection <- with_db
  let assert Ok(session) = sessions.create(connection, None, None, None)

  let assert Ok(first) =
    messages.insert(connection, messages.new(session.id, types.User, "в1"))
  let assert Ok(_) =
    messages.insert(connection, messages.new(session.id, types.Assistant, "о1"))

  let assert Ok(_) = messages.delete_exchange(connection, first.id)

  // Номер считается от максимума, поэтому после полной очистки нумерация
  // начинается заново — дыры в последовательности безвредны.
  let assert Ok(next) =
    messages.insert(connection, messages.new(session.id, types.User, "в2"))
  assert next.seq == 1
}

/// Сообщение нельзя привязать к несуществующей сессии.
pub fn message_requires_session_test() {
  use connection <- with_db
  let assert Error(_) =
    messages.insert(connection, messages.new("нет-такой", types.User, "a"))
  Nil
}

// ─── Агенты ──────────────────────────────────────────────────────────────────

fn sample_agent(name: String) -> agents.NewAgent {
  agents.new(name, "veai", "Anthropic/sonnet-5")
}

pub fn agent_roundtrip_test() {
  use connection <- with_db

  let draft =
    agents.NewAgent(
      ..sample_agent("Рецензент"),
      description: "разбирает текст",
      system_prompt: "Ты строгий редактор",
      params: types.RequestOptions(
        ..types.default_options(),
        temperature: Some(0.3),
      ),
      max_steps: 5,
      tools: ["now", "calc"],
    )

  let assert Ok(created) = agents.create(connection, draft)
  let assert Ok(loaded) = agents.get(connection, created.id)

  assert loaded.name == "Рецензент"
  assert loaded.description == "разбирает текст"
  assert loaded.system_prompt == "Ты строгий редактор"
  assert loaded.params.temperature == Some(0.3)
  assert loaded.max_steps == 5
  assert loaded.tools == ["now", "calc"]
  assert loaded.created_at == loaded.updated_at
}

/// Заготовка не включает инструменты: доступ к ним — осознанное решение.
pub fn agent_defaults_are_safe_test() {
  use connection <- with_db
  let assert Ok(agent) = agents.create(connection, sample_agent("Простой"))

  assert agent.tools == []
  assert agent.max_steps == types.single_step
  assert agent.system_prompt == ""
}

pub fn agent_missing_test() {
  use connection <- with_db
  assert agents.get(connection, "нет-такого") == Error(agents.NotFound)
  assert agents.exists(connection, "нет-такого") == Ok(False)
}

/// Частичное обновление не затирает незаданные поля.
pub fn agent_partial_update_test() {
  use connection <- with_db
  let assert Ok(agent) =
    agents.create(
      connection,
      agents.NewAgent(..sample_agent("Было"), system_prompt: "промпт"),
    )

  let assert Ok(updated) =
    agents.update(
      connection,
      agent.id,
      Some("Стало"),
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
    )

  assert updated.name == "Стало"
  assert updated.system_prompt == "промпт"
  assert updated.model_id == agent.model_id
}

/// Пустой список инструментов должен сохраняться, а не трактоваться
/// как «поле не задано».
pub fn agent_tools_can_be_cleared_test() {
  use connection <- with_db
  let assert Ok(agent) =
    agents.create(
      connection,
      agents.NewAgent(..sample_agent("С инструментами"), tools: ["now"]),
    )

  let assert Ok(updated) =
    agents.update(
      connection,
      agent.id,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      Some([]),
      None,
    )

  assert updated.tools == []
}

/// Список агентов несёт число запусков — для подписи в панели.
pub fn agent_list_counts_sessions_test() {
  use connection <- with_db
  let assert Ok(agent) = agents.create(connection, sample_agent("С запусками"))
  let assert Ok(_) = agents.create(connection, sample_agent("Без запусков"))

  let assert Ok(_) =
    sessions.create_for_agent(connection, Some(agent.id), None, None, None)
  let assert Ok(_) =
    sessions.create_for_agent(connection, Some(agent.id), None, None, None)

  let assert Ok(list) = agents.list(connection)
  let counts =
    list.map(list, fn(summary) { #(summary.name, summary.session_count) })

  assert list.key_find(counts, "С запусками") == Ok(2)
  assert list.key_find(counts, "Без запусков") == Ok(0)
}

/// Агента с запусками удалять нельзя: за ними стоит история работы.
pub fn agent_with_sessions_is_protected_test() {
  use connection <- with_db
  let assert Ok(agent) = agents.create(connection, sample_agent("Занятый"))
  let assert Ok(session) =
    sessions.create_for_agent(connection, Some(agent.id), None, None, None)

  assert agents.delete(connection, agent.id) == Error(agents.InUse(1))

  // После удаления запуска агент убирается обычным образом.
  let assert Ok(Nil) = sessions.delete(connection, session.id)
  let assert Ok(Nil) = agents.delete(connection, agent.id)
  assert agents.exists(connection, agent.id) == Ok(False)
}

/// Сессия помнит своего агента; сессия без агента остаётся допустимой.
pub fn session_links_to_agent_test() {
  use connection <- with_db
  let assert Ok(agent) = agents.create(connection, sample_agent("Хозяин"))

  let assert Ok(instance) =
    sessions.create_for_agent(
      connection,
      Some(agent.id),
      Some("запуск 1"),
      Some("veai"),
      Some("Anthropic/sonnet-5"),
    )
  let assert Ok(loaded) = sessions.get(connection, instance.id)
  assert loaded.agent_id == Some(agent.id)

  let assert Ok(plain) = sessions.create(connection, None, None, None)
  let assert Ok(loaded_plain) = sessions.get(connection, plain.id)
  assert loaded_plain.agent_id == None

  // Список запусков агента не включает чужие сессии.
  let assert Ok(runs) = sessions.list_for_agent(connection, agent.id)
  assert list.map(runs, fn(run) { run.id }) == [instance.id]
}

// ─── Задания ─────────────────────────────────────────────────────────────────

fn session_with_agent(connection: Connection) -> types.Session {
  let assert Ok(agent) = agents.create(connection, sample_agent("Агент"))
  let assert Ok(session) =
    sessions.create_for_agent(connection, Some(agent.id), None, None, None)
  session
}

pub fn task_lifecycle_test() {
  use connection <- with_db
  let session = session_with_agent(connection)

  let assert Ok(task) = tasks.create(connection, session.id, "сделай дело")
  assert task.seq == 1
  assert task.status == types.Running
  assert task.result == None
  assert task.finished_at == None

  let assert Ok(Nil) = tasks.set_steps(connection, task.id, 2)

  let assert Ok(finished) =
    tasks.finish(connection, task.id, types.TaskDone, Some("готово"), None, 3)

  assert finished.status == types.TaskDone
  assert finished.result == Some("готово")
  assert finished.steps == 3
  assert option.is_some(finished.finished_at)
}

/// Пока задание выполняется, второе в той же сессии не создаётся.
pub fn task_runs_one_at_a_time_test() {
  use connection <- with_db
  let session = session_with_agent(connection)

  let assert Ok(first) = tasks.create(connection, session.id, "первое")
  assert tasks.create(connection, session.id, "второе")
    == Error(tasks.AlreadyRunning(first.id))

  // После завершения очередь открывается.
  let assert Ok(_) =
    tasks.finish(connection, first.id, types.TaskDone, Some("ок"), None, 1)
  let assert Ok(second) = tasks.create(connection, session.id, "второе")
  assert second.seq == 2
}

/// Ограничение действует на сессию, а не на агента: разные запуски
/// одного агента работают параллельно.
pub fn tasks_of_different_sessions_are_independent_test() {
  use connection <- with_db
  let assert Ok(agent) = agents.create(connection, sample_agent("Общий"))
  let assert Ok(one) =
    sessions.create_for_agent(connection, Some(agent.id), None, None, None)
  let assert Ok(two) =
    sessions.create_for_agent(connection, Some(agent.id), None, None, None)

  let assert Ok(_) = tasks.create(connection, one.id, "задание")
  let assert Ok(other) = tasks.create(connection, two.id, "задание")

  assert other.seq == 1
  let assert Ok(Some(_)) = tasks.running(connection, one.id)
}

/// Упавшее задание не блокирует следующие.
pub fn failed_task_unblocks_session_test() {
  use connection <- with_db
  let session = session_with_agent(connection)

  let assert Ok(first) = tasks.create(connection, session.id, "упадёт")
  let assert Ok(_) =
    tasks.finish(
      connection,
      first.id,
      types.TaskFailed,
      None,
      Some("провайдер недоступен"),
      1,
    )

  assert tasks.running(connection, session.id) == Ok(None)
  let assert Ok(_) = tasks.create(connection, session.id, "следующее")
  Nil
}

/// Шаги задания читаются отдельно и уходят вместе с ним.
pub fn task_steps_are_linked_and_cascade_test() {
  use connection <- with_db
  let session = session_with_agent(connection)
  let assert Ok(task) = tasks.create(connection, session.id, "задание")

  let assert Ok(question) =
    messages.insert(
      connection,
      messages.NewMessage(
        ..messages.new(session.id, types.User, "шаг 1"),
        task_id: Some(task.id),
        step: Some(1),
      ),
    )
  let assert Ok(_) =
    messages.insert(
      connection,
      messages.NewMessage(
        ..messages.new(session.id, types.Assistant, "ответ 1"),
        reply_to: Some(question.id),
        task_id: Some(task.id),
        step: Some(1),
      ),
    )
  // Сообщение вне задания — не должно попасть в выборку.
  let assert Ok(_) =
    messages.insert(
      connection,
      messages.new(session.id, types.User, "отдельно"),
    )

  let assert Ok(steps) = messages.list_for_task(connection, task.id)
  assert list.map(steps, fn(step) { step.content }) == ["шаг 1", "ответ 1"]

  // Удаление задания забирает его шаги, но не трогает остальное.
  let assert Ok(Nil) = tasks.delete(connection, task.id)
  let assert Ok(rest) = messages.list_for_session(connection, session.id)
  assert list.map(rest, fn(message) { message.content }) == ["отдельно"]
}

pub fn task_missing_test() {
  use connection <- with_db
  assert tasks.get(connection, "нет-такого") == Error(tasks.NotFound)
  assert tasks.delete(connection, "нет-такого") == Error(tasks.NotFound)
}

// ─── Декодеры для служебных запросов ─────────────────────────────────────────

fn decode_first_string() {
  decode.at([0], decode.string)
}

fn decode_first_int() {
  decode.at([0], decode.int)
}
