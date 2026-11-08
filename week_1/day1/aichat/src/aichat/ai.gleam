import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

pub const default_model = "Anthropic/sonnet-5"

pub const api_host = "api.veai.ru"

pub const api_path = "/openai/api/v1/chat/completions"

/// Build the JSON body that will be sent to the AI provider.
pub fn build_request_json(model model: String, question question: String) -> String {
  json.object([
    #("model", json.string(model)),
    #(
      "messages",
      json.preprocessed_array([
        json.object([
          #("role", json.string("user")),
          #("content", json.string(question)),
        ]),
      ]),
    ),
  ])
  |> json.to_string
}

pub type AiError {
  MissingApiKey
  HttpError(String)
  ApiError(status: Int, body: String)
}

/// Send an already built JSON body to the provider, returning the raw response.
pub fn send(body body: String, api_key api_key: String) -> Result(String, AiError) {
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_scheme(http.Https)
    |> request.set_host(api_host)
    |> request.set_path(api_path)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> api_key)
    |> request.set_body(body)

  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(120_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) { HttpError(string.inspect(e)) }),
  )

  case resp.status {
    status if status >= 200 && status < 300 -> Ok(resp.body)
    status -> Error(ApiError(status, resp.body))
  }
}

/// Pull the assistant message out of a provider response.
pub fn extract_answer(response_json: String) -> Result(String, Nil) {
  let decoder = {
    use choices <- decode.field(
      "choices",
      decode.list({
        use content <- decode.subfield(["message", "content"], decode.string)
        decode.success(content)
      }),
    )
    decode.success(choices)
  }

  json.parse(response_json, decoder)
  |> result.replace_error(Nil)
  |> result.try(list.first)
}

/// Check that a string is valid JSON.
pub fn is_valid(input: String) -> Bool {
  case json.parse(input, decode.dynamic) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Read the `model` field of a request body, if present.
pub fn extract_model(request_json: String) -> Result(String, Nil) {
  json.parse(request_json, decode.at(["model"], decode.string))
  |> result.replace_error(Nil)
}

/// Read the content of the first message of a request body, if present.
pub fn extract_question(request_json: String) -> Result(String, Nil) {
  let decoder =
    decode.at(
      ["messages"],
      decode.list(decode.at(["content"], decode.string)),
    )
  json.parse(request_json, decoder)
  |> result.replace_error(Nil)
  |> result.try(list.first)
}

/// Re-indent a JSON string with two spaces per level.
///
/// Invalid JSON is returned unchanged so that error responses stay readable.
pub fn pretty(input: String) -> String {
  case is_valid(input) {
    False -> input
    True ->
      format(string.to_graphemes(input), 0, False, False, string_tree.new())
      |> string_tree.to_string
  }
}

fn format(
  chars: List(String),
  indent: Int,
  in_string: Bool,
  escaped: Bool,
  acc: StringTree,
) -> StringTree {
  case chars {
    [] -> acc
    [char, ..rest] if in_string -> {
      let acc = string_tree.append(acc, char)
      case escaped, char {
        True, _ -> format(rest, indent, True, False, acc)
        False, "\\" -> format(rest, indent, True, True, acc)
        False, "\"" -> format(rest, indent, False, False, acc)
        False, _ -> format(rest, indent, True, False, acc)
      }
    }
    ["\"", ..rest] ->
      format(rest, indent, True, False, string_tree.append(acc, "\""))
    [open, ..rest] if open == "{" || open == "[" ->
      case skip_space(rest) {
        [close, ..tail] if close == "}" || close == "]" ->
          format(tail, indent, False, False, string_tree.append(acc, open <> close))
        _ ->
          format(
            rest,
            indent + 1,
            False,
            False,
            string_tree.append(acc, open <> newline(indent + 1)),
          )
      }
    [close, ..rest] if close == "}" || close == "]" ->
      format(
        rest,
        indent - 1,
        False,
        False,
        string_tree.append(acc, newline(indent - 1) <> close),
      )
    [",", ..rest] ->
      format(rest, indent, False, False, string_tree.append(acc, "," <> newline(indent)))
    [":", ..rest] -> format(rest, indent, False, False, string_tree.append(acc, ": "))
    [char, ..rest] ->
      case is_space(char) {
        True -> format(rest, indent, False, False, acc)
        False -> format(rest, indent, False, False, string_tree.append(acc, char))
      }
  }
}

fn newline(indent: Int) -> String {
  "\n" <> string.repeat("  ", indent)
}

fn skip_space(chars: List(String)) -> List(String) {
  case chars {
    [char, ..rest] ->
      case is_space(char) {
        True -> skip_space(rest)
        False -> chars
      }
    [] -> []
  }
}

fn is_space(char: String) -> Bool {
  char == " " || char == "\n" || char == "\t" || char == "\r"
}
