//// Хранение фактов и пересказов — того, что агент помнит о запуске.
////
//// Оба привязаны к сессии, а не к агенту: у агента для постоянных знаний
//// есть системный промпт, а здесь то, что выяснилось в ходе конкретного
//// запуска.
////
//// Пересказ **не заменяет** сообщения: исходные шаги остаются в БД со
//// всеми сырыми телами, и наблюдаемость не страдает. Пересказ — только
//// то, что подставляется вместо них в запрос к модели.

import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/result
import gleam/string
import server/ids
import shared/types.{type Fact, type Summary}
import sqlight.{type Connection}

pub type RepoError {
  Sql(sqlight.Error)
  NotFound
}

// ─── Факты ───────────────────────────────────────────────────────────────────

const fact_columns = "id, session_id, text, created_at"

fn fact_decoder() -> Decoder(Fact) {
  use id <- decode.field(0, decode.string)
  use session_id <- decode.field(1, decode.string)
  use text <- decode.field(2, decode.string)
  use created_at <- decode.field(3, decode.int)
  decode.success(types.Fact(id:, session_id:, text:, created_at:))
}

/// Запоминает факт. Повтор игнорируется: модель склонна повторять
/// «запомни» на каждом шаге, и без этого список заполнился бы дублями.
pub fn remember(
  connection: Connection,
  session_id: String,
  text: String,
) -> Result(Fact, RepoError) {
  let trimmed = string.trim(text)

  use existing <- result.try(list_facts(connection, session_id))

  case list.find(existing, fn(fact) { same_text(fact.text, trimmed) }) {
    Ok(fact) -> Ok(fact)
    Error(Nil) -> {
      let stored =
        types.Fact(
          id: ids.fact_id(),
          session_id:,
          text: trimmed,
          created_at: ids.now_ms(),
        )

      { "INSERT INTO facts (" <> fact_columns <> ") VALUES (?, ?, ?, ?)" }
      |> sqlight.query(
        on: connection,
        with: [
          sqlight.text(stored.id),
          sqlight.text(stored.session_id),
          sqlight.text(stored.text),
          sqlight.int(stored.created_at),
        ],
        expecting: decode.dynamic,
      )
      |> result.map_error(Sql)
      |> result.replace(stored)
    }
  }
}

fn same_text(left: String, right: String) -> Bool {
  string.lowercase(string.trim(left)) == string.lowercase(string.trim(right))
}

pub fn list_facts(
  connection: Connection,
  session_id: String,
) -> Result(List(Fact), RepoError) {
  {
    "SELECT "
    <> fact_columns
    <> " FROM facts WHERE session_id = ? ORDER BY created_at"
  }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(session_id)],
    expecting: fact_decoder(),
  )
  |> result.map_error(Sql)
}

/// Забывает факт по подстроке.
///
/// По тексту, а не по идентификатору: модель оперирует содержанием, а не
/// `fct_…`. Возвращает, сколько удалено, — ноль означает «не нашлось»,
/// и агенту полезно об этом знать.
pub fn forget(
  connection: Connection,
  session_id: String,
  query: String,
) -> Result(Int, RepoError) {
  let pattern = "%" <> string.lowercase(string.trim(query)) <> "%"

  use matching <- result.try(
    { "SELECT " <> fact_columns <> " FROM facts
         WHERE session_id = ? AND lower(text) LIKE ?" }
    |> sqlight.query(
      on: connection,
      with: [sqlight.text(session_id), sqlight.text(pattern)],
      expecting: fact_decoder(),
    )
    |> result.map_error(Sql),
  )

  use _ <- result.try(
    "DELETE FROM facts WHERE session_id = ? AND lower(text) LIKE ?"
    |> sqlight.query(
      on: connection,
      with: [sqlight.text(session_id), sqlight.text(pattern)],
      expecting: decode.dynamic,
    )
    |> result.map_error(Sql),
  )

  Ok(list.length(matching))
}

// ─── Пересказы ───────────────────────────────────────────────────────────────

const summary_columns =
  "id, session_id, text, covers_through_seq,
                         message_count, created_at"

fn summary_decoder() -> Decoder(Summary) {
  use id <- decode.field(0, decode.string)
  use session_id <- decode.field(1, decode.string)
  use text <- decode.field(2, decode.string)
  use covers_through_seq <- decode.field(3, decode.int)
  use message_count <- decode.field(4, decode.int)
  use created_at <- decode.field(5, decode.int)
  decode.success(types.Summary(
    id:,
    session_id:,
    text:,
    covers_through_seq:,
    message_count:,
    created_at:,
  ))
}

/// Последний пересказ сессии.
///
/// Нужен в двух местах: подставить в запрос и передать на вход
/// следующему сжатию — пересказывается пересказ, а не вся история заново.
pub fn latest_summary(
  connection: Connection,
  session_id: String,
) -> Result(Summary, RepoError) {
  { "SELECT " <> summary_columns <> " FROM summaries WHERE session_id = ?
         ORDER BY covers_through_seq DESC, created_at DESC LIMIT 1" }
  |> sqlight.query(
    on: connection,
    with: [sqlight.text(session_id)],
    expecting: summary_decoder(),
  )
  |> result.map_error(Sql)
  |> result.try(fn(rows) {
    case rows {
      [first, ..] -> Ok(first)
      [] -> Error(NotFound)
    }
  })
}

pub fn save_summary(
  connection: Connection,
  session_id: String,
  text: String,
  covers_through_seq: Int,
  message_count: Int,
) -> Result(Summary, RepoError) {
  let stored =
    types.Summary(
      id: ids.summary_id(),
      session_id:,
      text: string.trim(text),
      covers_through_seq:,
      message_count:,
      created_at: ids.now_ms(),
    )

  { "INSERT INTO summaries (" <> summary_columns <> ")
     VALUES (?, ?, ?, ?, ?, ?)" }
  |> sqlight.query(
    on: connection,
    with: [
      sqlight.text(stored.id),
      sqlight.text(stored.session_id),
      sqlight.text(stored.text),
      sqlight.int(stored.covers_through_seq),
      sqlight.int(stored.message_count),
      sqlight.int(stored.created_at),
    ],
    expecting: decode.dynamic,
  )
  |> result.map_error(Sql)
  |> result.replace(stored)
}

pub fn describe(error: RepoError) -> String {
  case error {
    NotFound -> "не найдено"
    Sql(error) -> string.inspect(error)
  }
}
