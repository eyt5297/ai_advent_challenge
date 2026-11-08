import gleam/dynamic/decode
import sqlight

pub type Exchange {
  Exchange(
    id: Int,
    created_at: String,
    model: String,
    question: String,
    request_json: String,
    response_json: String,
  )
}

pub const path = "aichat.sqlite"

/// Create the table if it does not exist yet.
pub fn migrate() -> Result(Nil, sqlight.Error) {
  use conn <- with_connection
  sqlight.exec(
    "create table if not exists exchanges (
      id integer primary key autoincrement,
      created_at text not null default (datetime('now')),
      model text not null,
      question text not null,
      request_json text not null,
      response_json text not null
    );",
    conn,
  )
}

pub fn with_connection(f: fn(sqlight.Connection) -> a) -> a {
  sqlight.with_connection(path, f)
}

pub fn insert(
  model model: String,
  question question: String,
  request_json request_json: String,
  response_json response_json: String,
) -> Result(Int, sqlight.Error) {
  use conn <- with_connection
  let rows =
    sqlight.query(
      "insert into exchanges (model, question, request_json, response_json)
       values (?, ?, ?, ?) returning id;",
      on: conn,
      with: [
        sqlight.text(model),
        sqlight.text(question),
        sqlight.text(request_json),
        sqlight.text(response_json),
      ],
      expecting: decode.at([0], decode.int),
    )
  case rows {
    Ok([id, ..]) -> Ok(id)
    Ok([]) -> Ok(0)
    Error(e) -> Error(e)
  }
}

fn exchange_decoder() -> decode.Decoder(Exchange) {
  use id <- decode.field(0, decode.int)
  use created_at <- decode.field(1, decode.string)
  use model <- decode.field(2, decode.string)
  use question <- decode.field(3, decode.string)
  use request_json <- decode.field(4, decode.string)
  use response_json <- decode.field(5, decode.string)
  decode.success(Exchange(
    id:,
    created_at:,
    model:,
    question:,
    request_json:,
    response_json:,
  ))
}

const columns = "id, created_at, model, question, request_json, response_json"

pub fn recent(limit: Int) -> Result(List(Exchange), sqlight.Error) {
  use conn <- with_connection
  sqlight.query(
    "select " <> columns <> " from exchanges order by id desc limit ?;",
    on: conn,
    with: [sqlight.int(limit)],
    expecting: exchange_decoder(),
  )
}

pub fn get(id: Int) -> Result(Exchange, Nil) {
  use conn <- with_connection
  let rows =
    sqlight.query(
      "select " <> columns <> " from exchanges where id = ?;",
      on: conn,
      with: [sqlight.int(id)],
      expecting: exchange_decoder(),
    )
  case rows {
    Ok([row, ..]) -> Ok(row)
    _ -> Error(Nil)
  }
}
