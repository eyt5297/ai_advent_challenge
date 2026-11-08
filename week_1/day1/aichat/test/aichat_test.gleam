import aichat/ai
import aichat/db
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn build_request_json_test() {
  assert ai.build_request_json(model: "m", question: "привет")
    == "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"привет\"}]}"
}

pub fn extract_answer_test() {
  let body =
    "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"На связи!\"},\"finish_reason\":\"stop\"}]}"
  assert ai.extract_answer(body) == Ok("На связи!")
}

pub fn pretty_test() {
  assert ai.pretty("{\"a\":1,\"b\":[1,2]}")
    == "{\n  \"a\": 1,\n  \"b\": [\n    1,\n    2\n  ]\n}"
}

pub fn pretty_keeps_strings_intact_test() {
  // Braces, colons and commas inside strings must not be reformatted.
  assert ai.pretty("{\"a\":\"x, y: {z}\"}") == "{\n  \"a\": \"x, y: {z}\"\n}"
}

pub fn pretty_empty_containers_test() {
  assert ai.pretty("{\"a\":{},\"b\":[]}") == "{\n  \"a\": {},\n  \"b\": []\n}"
}

pub fn pretty_leaves_invalid_json_alone_test() {
  assert ai.pretty("not json") == "not json"
}

pub fn is_valid_test() {
  assert ai.is_valid("{\"a\":1}")
  assert !ai.is_valid("{\"a\":}")
}

pub fn extract_from_request_test() {
  let body = ai.build_request_json(model: "m", question: "привет")
  assert ai.extract_model(body) == Ok("m")
  assert ai.extract_question(body) == Ok("привет")
}

pub fn store_and_read_test() {
  let assert Ok(_) = db.migrate()
  let assert Ok(id) =
    db.insert(
      model: "m",
      question: "q",
      request_json: "{\"a\":1}",
      response_json: "{\"b\":2}",
    )
  let assert Ok(row) = db.get(id)
  assert row.question == "q"
  assert row.response_json == "{\"b\":2}"
  let assert Ok([first, ..]) = db.recent(5)
  assert first.id == id
}
