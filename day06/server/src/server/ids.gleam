//// Идентификаторы и время.

import gleam/bit_array
import gleam/crypto
import gleam/string

@external(erlang, "erlang", "system_time")
fn erlang_system_time(unit: TimeUnit) -> Int

type TimeUnit {
  Millisecond
}

/// Текущее время в миллисекундах Unix epoch.
pub fn now_ms() -> Int {
  erlang_system_time(Millisecond)
}

/// Случайный идентификатор с человекочитаемым префиксом: `ses_a1b2…`.
///
/// Не UUID: 128 бит случайности в base64url короче и так же уникальны,
/// а префикс помогает при чтении логов и БД.
pub fn generate(prefix: String) -> String {
  let random =
    crypto.strong_random_bytes(16)
    |> bit_array.base64_url_encode(False)
    |> string.replace("=", "")
  prefix <> "_" <> random
}

pub fn session_id() -> String {
  generate("ses")
}

pub fn message_id() -> String {
  generate("msg")
}

pub fn agent_id() -> String {
  generate("agt")
}

pub fn fact_id() -> String {
  generate("fct")
}

pub fn summary_id() -> String {
  generate("sum")
}

pub fn task_id() -> String {
  generate("tsk")
}
