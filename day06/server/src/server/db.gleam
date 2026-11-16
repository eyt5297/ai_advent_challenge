//// Соединение с SQLite и миграции схемы.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import sqlight.{type Connection}

pub type DbError {
  /// Ошибка самой SQLite.
  Sql(sqlight.Error)
  /// Не удалось создать каталог для файла БД.
  Storage(String)
}

/// Открывает БД, создаёт каталог при необходимости и накатывает миграции.
pub fn connect(path: String) -> Result(Connection, DbError) {
  use _ <- result.try(ensure_parent_dir(path))
  use connection <- result.try(sqlight.open(path) |> result.map_error(Sql))
  use _ <- result.try(configure(connection))
  use _ <- result.try(migrate(connection))
  Ok(connection)
}

/// Соединение в памяти — для тестов.
pub fn connect_memory() -> Result(Connection, DbError) {
  use connection <- result.try(
    sqlight.open(":memory:") |> result.map_error(Sql),
  )
  use _ <- result.try(configure(connection))
  use _ <- result.try(migrate(connection))
  Ok(connection)
}

fn configure(connection: Connection) -> Result(Nil, DbError) {
  // WAL — чтобы чтение не блокировалось записью: запрос к LLM может идти
  // долго, а список сессий должен открываться мгновенно.
  "PRAGMA journal_mode = WAL;
   PRAGMA foreign_keys = ON;
   PRAGMA busy_timeout = 5000;"
  |> sqlight.exec(connection)
  |> result.map_error(Sql)
}

fn ensure_parent_dir(path: String) -> Result(Nil, DbError) {
  case string.split(path, "/") {
    [] | [_] -> Ok(Nil)
    parts -> {
      let dir =
        parts
        |> list.take(list.length(parts) - 1)
        |> string.join("/")
      case dir {
        "" -> Ok(Nil)
        _ ->
          simplifile.create_directory_all(dir)
          |> result.map_error(fn(error) {
            Storage(dir <> ": " <> simplifile.describe_error(error))
          })
      }
    }
  }
}

// ─── Миграции ────────────────────────────────────────────────────────────────

/// Список миграций. Добавлять только в конец, не менять уже выпущенные.
fn migrations() -> List(String) {
  [
    // 1: базовая схема
    "CREATE TABLE sessions (
       id           TEXT PRIMARY KEY,
       title        TEXT NOT NULL,
       created_at   INTEGER NOT NULL,
       updated_at   INTEGER NOT NULL,
       provider_id  TEXT,
       model_id     TEXT,
       params_json  TEXT
     );

     CREATE TABLE messages (
       id            TEXT PRIMARY KEY,
       session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
       seq           INTEGER NOT NULL,
       role          TEXT NOT NULL,
       content       TEXT NOT NULL,
       reasoning     TEXT,
       provider_id   TEXT,
       model_id      TEXT,
       status        TEXT NOT NULL,
       error         TEXT,
       params_json   TEXT,
       hand_edited   INTEGER NOT NULL DEFAULT 0,
       raw_request   TEXT,
       raw_response  TEXT,
       http_status   INTEGER,
       latency_ms    INTEGER,
       usage_json    TEXT,
       created_at    INTEGER NOT NULL
     );

     CREATE INDEX idx_messages_session ON messages(session_id, seq);
     CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC);",
    // 2: уникальность seq внутри сессии и явная связь ответа с запросом.
    //
    // Раньше номер вычислялся отдельным SELECT, а вставка происходила уже
    // после ответа провайдера — через секунды. Параллельные отправки в одну
    // сессию читали один и тот же максимум и получали одинаковый seq.
    // Вставка стала атомарной (repo/messages.insert), а индекс превращает
    // возможный промах из молчаливой порчи данных в явную ошибку.
    //
    // На базе с уже существующими дублями миграция упадёт — это намеренно:
    // лучше не стартовать, чем работать на испорченных данных.
    //
    // `reply_to` появился следом за атомарной вставкой: номера пары больше
    // не соседние (между ними успевают вклиниться чужие запросы), поэтому
    // искать пару по seq ± 1 нельзя. Связь теперь хранится, а не угадывается.
    // Старые строки остаются с NULL — для них работает прежний поиск.
    "CREATE UNIQUE INDEX idx_messages_seq ON messages(session_id, seq);

     ALTER TABLE messages ADD COLUMN reply_to TEXT REFERENCES messages(id);

     CREATE INDEX idx_messages_reply ON messages(reply_to);",
    // 3: агенты и задания.
    //
    // Агент — настройка, сессия — его запущенный экземпляр, задание —
    // единица работы внутри запуска. Статус живёт у задания, а не у
    // сессии: сессия копит задания, каждое из которых одноразово.
    //
    // agent_id и task_id допускают NULL: так выглядят сессии и сообщения,
    // созданные до этой миграции. Служебного агента «по умолчанию» для них
    // не заводим — честный Option лучше скрытого состояния.
    "CREATE TABLE agents (
       id            TEXT PRIMARY KEY,
       name          TEXT NOT NULL,
       description   TEXT NOT NULL DEFAULT '',
       system_prompt TEXT NOT NULL DEFAULT '',
       provider_id   TEXT NOT NULL,
       model_id      TEXT NOT NULL,
       params_json   TEXT,
       max_steps     INTEGER NOT NULL DEFAULT 1,
       tools_json    TEXT,
       created_at    INTEGER NOT NULL,
       updated_at    INTEGER NOT NULL
     );

     CREATE TABLE tasks (
       id          TEXT PRIMARY KEY,
       session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
       seq         INTEGER NOT NULL,
       prompt      TEXT NOT NULL,
       result      TEXT,
       status      TEXT NOT NULL,
       error       TEXT,
       steps       INTEGER NOT NULL DEFAULT 0,
       created_at  INTEGER NOT NULL,
       finished_at INTEGER
     );

     ALTER TABLE sessions ADD COLUMN agent_id TEXT REFERENCES agents(id);
     ALTER TABLE messages ADD COLUMN task_id  TEXT REFERENCES tasks(id) ON DELETE CASCADE;
     ALTER TABLE messages ADD COLUMN step     INTEGER;

     CREATE UNIQUE INDEX idx_tasks_seq ON tasks(session_id, seq);
     CREATE INDEX idx_tasks_session ON tasks(session_id, seq);
     CREATE INDEX idx_messages_task ON messages(task_id, step);
     CREATE INDEX idx_sessions_agent ON sessions(agent_id);",
    // 4: вызовы инструментов.
    //
    // Хранятся, а не восстанавливаются из raw_response: протокол требует
    // вернуть модели её же tool_calls вместе с результатами, и разбирать
    // ради этого сырое тело на каждом шаге — лишняя хрупкость.
    //
    // tool_calls_json заполняется у ответа модели, tool_call_id — у строки
    // с результатом вызова (role = 'tool'). Они всегда в паре.
    "ALTER TABLE messages ADD COLUMN tool_calls_json TEXT;
     ALTER TABLE messages ADD COLUMN tool_call_id    TEXT;",
    // 5: память агента между заданиями.
    //
    // memory_json у существующих агентов остаётся NULL, что декодер
    // читает как «без памяти»: поведение не меняется молча, менять его
    // должен человек в форме.
    //
    // facts и summaries привязаны к сессии, а не к агенту: у агента для
    // постоянных знаний есть system_prompt, а здесь — то, что выяснилось
    // в конкретном запуске. ON DELETE CASCADE, потому что без своей
    // сессии они бессмысленны.
    "ALTER TABLE agents ADD COLUMN memory_json TEXT;

     CREATE TABLE facts (
       id          TEXT PRIMARY KEY,
       session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
       text        TEXT NOT NULL,
       created_at  INTEGER NOT NULL
     );
     CREATE INDEX idx_facts_session ON facts(session_id, created_at);

     CREATE TABLE summaries (
       id                 TEXT PRIMARY KEY,
       session_id         TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
       text               TEXT NOT NULL,
       covers_through_seq INTEGER NOT NULL,
       message_count      INTEGER NOT NULL,
       created_at         INTEGER NOT NULL
     );
     CREATE INDEX idx_summaries_session ON summaries(session_id, created_at);",
  ]
}

fn migrate(connection: Connection) -> Result(Nil, DbError) {
  use _ <- result.try(
    "CREATE TABLE IF NOT EXISTS schema_migrations (
       version    INTEGER PRIMARY KEY,
       applied_at INTEGER NOT NULL
     );"
    |> sqlight.exec(connection)
    |> result.map_error(Sql),
  )

  use applied <- result.try(current_version(connection))

  migrations()
  |> list.index_map(fn(sql, index) { #(index + 1, sql) })
  |> list.filter(fn(entry) { entry.0 > applied })
  |> list.try_each(fn(entry) { apply(connection, entry.0, entry.1) })
}

fn apply(
  connection: Connection,
  version: Int,
  sql: String,
) -> Result(Nil, DbError) {
  // sqlight сам оборачивает exec в транзакцию только для одного statement,
  // поэтому границы задаём явно: миграция применяется целиком или никак.
  let script =
    "BEGIN;\n" <> sql <> "\nINSERT INTO schema_migrations (version, applied_at)
          VALUES (" <> int.to_string(version) <> ", CAST(strftime('%s','now') AS INTEGER) * 1000);\nCOMMIT;"

  case sqlight.exec(script, connection) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK;", connection)
      Error(Sql(error))
    }
  }
}

fn current_version(connection: Connection) -> Result(Int, DbError) {
  "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;"
  |> sqlight.query(
    on: connection,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(Sql)
  |> result.map(fn(rows) {
    case rows {
      [version, ..] -> version
      [] -> 0
    }
  })
}

// ─── Описание ошибок ─────────────────────────────────────────────────────────

pub fn describe(error: DbError) -> String {
  case error {
    Storage(message) -> message
    Sql(sqlight.SqlightError(code, message, offset)) ->
      "sqlite "
      <> string.inspect(code)
      <> ": "
      <> message
      <> case offset {
        -1 -> ""
        _ -> " (позиция " <> int.to_string(offset) <> ")"
      }
  }
}
