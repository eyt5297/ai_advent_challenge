//// Доступ к таблице `tasks`.
////
//// Задание — единица работы агента и единица наблюдения в интерфейсе:
//// текст от пользователя, итог и шаги между ними. Статус живёт здесь,
//// а не у сессии: сессия копит задания, каждое из которых одноразово.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/ids
import shared/types.{type Task, type TaskStatus}
import sqlight.{type Connection}

pub type RepoError {
  Sql(sqlight.Error)
  NotFound
  /// В сессии уже выполняется задание. Параллельные задания одной сессии
  /// дали бы агенту чересполосицу в истории шагов.
  AlreadyRunning(task_id: String)
}

const columns =
  "id, session_id, seq, prompt, result, status, error,
                 steps, created_at, finished_at"

// ─── Декодер строки ──────────────────────────────────────────────────────────

fn task_decoder() -> Decoder(Task) {
  use id <- decode.field(0, decode.string)
  use session_id <- decode.field(1, decode.string)
  use seq <- decode.field(2, decode.int)
  use prompt <- decode.field(3, decode.string)
  use result <- decode.field(4, decode.optional(decode.string))
  use status_text <- decode.field(5, decode.string)
  use error <- decode.field(6, decode.optional(decode.string))
  use steps <- decode.field(7, decode.int)
  use created_at <- decode.field(8, decode.int)
  use finished_at <- decode.field(9, decode.optional(decode.int))

  decode.success(types.Task(
    id:,
    session_id:,
    seq:,
    prompt:,
    result:,
    // Неизвестный статус не должен ронять загрузку списка заданий.
    status: types.task_status_from_string(status_text)
      |> result.unwrap(types.TaskFailed),
    error:,
    steps:,
    created_at:,
    finished_at:,
  ))
}

// ─── Чтение ──────────────────────────────────────────────────────────────────

pub fn list_for_session(
  connection: Connection,
  session_id: String,
) -> Result(List(Task), RepoError) {
  { "SELECT " <> columns <> " FROM tasks WHERE session_id = ? ORDER BY seq" }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(session_id)],
    expecting: task_decoder(),
  )
  |> result.map_error(Sql)
}

/// Поиск по завершённым заданиям сессии — для инструмента `find_task`.
///
/// Только `done`: выполняющееся задание — это текущее, а упавшее не несёт
/// полезного итога. Поиск по подстроке в задании и в результате.
pub fn search(
  connection: Connection,
  session_id: String,
  query: String,
  limit: Int,
) -> Result(List(Task), RepoError) {
  let pattern = "%" <> string.lowercase(query) <> "%"

  { "SELECT " <> columns <> " FROM tasks
         WHERE session_id = ?
           AND status = 'done'
           AND (lower(prompt) LIKE ? OR lower(COALESCE(result, '')) LIKE ?)
         ORDER BY seq DESC
         LIMIT ?" }
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.text(session_id),
      sqlight.text(pattern),
      sqlight.text(pattern),
      sqlight.int(limit),
    ],
    expecting: task_decoder(),
  )
  |> result.map_error(Sql)
}

pub fn get(connection: Connection, id: String) -> Result(Task, RepoError) {
  { "SELECT " <> columns <> " FROM tasks WHERE id = ?" }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(id)],
    expecting: task_decoder(),
  )
  |> result.map_error(Sql)
  |> result.try(first_row)
}

/// Выполняющееся задание сессии, если оно есть.
pub fn running(
  connection: Connection,
  session_id: String,
) -> Result(Option(Task), RepoError) {
  {
    "SELECT "
    <> columns
    <> " FROM tasks WHERE session_id = ? AND status = 'running'
        ORDER BY seq LIMIT 1"
  }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(session_id)],
    expecting: task_decoder(),
  )
  |> result.map_error(Sql)
  |> result.map(fn(rows) {
    case rows {
      [task, ..] -> Some(task)
      [] -> None
    }
  })
}

fn first_row(rows: List(a)) -> Result(a, RepoError) {
  case rows {
    [row, ..] -> Ok(row)
    [] -> Error(NotFound)
  }
}

// ─── Запись ──────────────────────────────────────────────────────────────────

/// Создаёт задание в статусе `running`.
///
/// Номер присваивается внутри оператора — по той же причине, что и у
/// сообщений: между чтением максимума и вставкой может вклиниться
/// соседний процесс.
///
/// Отказывает, если в сессии уже есть выполняющееся задание. Проверка и
/// вставка не атомарны, но гонка здесь безобидна: уникальный индекс по
/// `(session_id, seq)` не даст создать два задания с одним номером, а
/// повторная проверка перед запуском цикла поймает остаток.
pub fn create(
  connection: Connection,
  session_id: String,
  prompt: String,
) -> Result(Task, RepoError) {
  use active <- result.try(running(connection, session_id))

  case active {
    Some(task) -> Error(AlreadyRunning(task.id))
    None -> insert(connection, session_id, prompt)
  }
}

fn insert(
  connection: Connection,
  session_id: String,
  prompt: String,
) -> Result(Task, RepoError) {
  let id = ids.task_id()
  let now = ids.now_ms()

  {
    "INSERT INTO tasks ("
    <> columns
    <> ") SELECT ?, ?, COALESCE(MAX(seq), 0) + 1, ?, NULL, ?, NULL, 0, ?, NULL
           FROM tasks WHERE session_id = ?
         RETURNING seq"
  }
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.text(id),
      sqlight.text(session_id),
      sqlight.text(prompt),
      sqlight.text(types.task_status_to_string(types.Running)),
      sqlight.int(now),
      sqlight.text(session_id),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(Sql)
  |> result.try(fn(rows) {
    case rows {
      [seq, ..] ->
        Ok(types.Task(
          id:,
          session_id:,
          seq:,
          prompt:,
          result: None,
          status: types.Running,
          error: None,
          steps: 0,
          created_at: now,
          finished_at: None,
        ))
      [] -> Error(NotFound)
    }
  })
}

/// Отмечает число выполненных шагов — вызывается после каждого обмена,
/// чтобы ход работы был виден снаружи, а не только изнутри процесса.
pub fn set_steps(
  connection: Connection,
  id: String,
  steps: Int,
) -> Result(Nil, RepoError) {
  "UPDATE tasks SET steps = ? WHERE id = ?"
  |> sqlight.query(
    on: connection,
    with: [sqlight.int(steps), sqlight.text(id)],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.replace(Nil)
}

/// Завершает задание: статус, итог или ошибка, время окончания.
pub fn finish(
  connection: Connection,
  id: String,
  status: TaskStatus,
  task_result: Option(String),
  error: Option(String),
  steps: Int,
) -> Result(Task, RepoError) {
  "UPDATE tasks
      SET status = ?, result = ?, error = ?, steps = ?, finished_at = ?
    WHERE id = ?"
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.text(types.task_status_to_string(status)),
      sqlight.nullable(sqlight.text, task_result),
      sqlight.nullable(sqlight.text, error),
      sqlight.int(steps),
      sqlight.int(ids.now_ms()),
      sqlight.text(id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.try(fn(_) { get(connection, id) })
}

/// Удаляет задание вместе с его шагами.
///
/// Шаги уходят каскадом (`messages.task_id ... ON DELETE CASCADE`):
/// удалять их по одному нельзя — они связаны историей, и задание без
/// части шагов невоспроизводимо.
pub fn delete(connection: Connection, id: String) -> Result(Nil, RepoError) {
  use _task <- result.try(get(connection, id))

  "DELETE FROM tasks WHERE id = ?"
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(id)],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.replace(Nil)
}
