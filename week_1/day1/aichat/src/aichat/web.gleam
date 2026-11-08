import aichat/ai
import aichat/db
import gleam/http
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import wisp.{type Request, type Response}

pub type Context {
  Context(api_key: Result(String, Nil))
}

pub fn handle_request(ctx: Context, req: Request) -> Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  case wisp.path_segments(req) {
    [] -> home(ctx, req)
    ["ask"] -> ask(ctx, req)
    ["exchanges", id] -> show(id)
    _ -> wisp.not_found()
  }
}

fn home(ctx: Context, req: Request) -> Response {
  use <- wisp.require_method(req, http.Get)
  let history = db.recent(20) |> result.unwrap([])
  let body = ai.build_request_json(ai.default_model, "")
  page(form_html(ctx, "", ai.pretty(body)) <> history_html(history))
}

fn ask(ctx: Context, req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)
  use form <- wisp.require_form(req)

  // The textarea is the source of truth: whatever the user edited is sent.
  let edited = string.trim(field(form.values, "request_json"))
  let question = field(form.values, "question")

  case edited, ai.is_valid(edited), ctx.api_key {
    "", _, _ ->
      retry(ctx, question, edited, "JSON запроса не может быть пустым.")
    _, False, _ ->
      retry(ctx, question, edited, "Это не валидный JSON — исправь и отправь снова.")
    _, True, Error(_) ->
      retry(ctx, question, edited, "Не задана переменная окружения OPENAI_API_KEY.")
    request_json, True, Ok(key) ->
      case ai.send(body: request_json, api_key: key) {
        Error(e) -> retry(ctx, question, request_json, describe(e))
        Ok(response_json) -> {
          let model =
            ai.extract_model(request_json) |> result.unwrap(ai.default_model)
          let asked = case ai.extract_question(request_json) {
            Ok(q) -> q
            Error(_) -> question
          }
          case
            db.insert(
              model:,
              question: asked,
              request_json:,
              response_json:,
            )
          {
            Ok(id) -> wisp.redirect(to: "/exchanges/" <> int.to_string(id))
            Error(_) ->
              page(
                error_html("Ответ получен, но не сохранён в базу.")
                <> exchange_html(model, asked, request_json, response_json),
              )
          }
        }
      }
  }
}

fn retry(
  ctx: Context,
  question: String,
  request_json: String,
  message: String,
) -> Response {
  page(error_html(message) <> form_html(ctx, question, request_json))
}

fn show(id: String) -> Response {
  case int.parse(id) |> result.try(fn(i) { db.get(i) }) {
    Ok(e) ->
      page(
        "<p><a href=\"/\">← Новый вопрос</a></p>"
        <> exchange_html(e.model, e.question, e.request_json, e.response_json),
      )
    Error(_) -> wisp.not_found()
  }
}

fn describe(error: ai.AiError) -> String {
  case error {
    ai.MissingApiKey -> "Нет API-ключа."
    ai.HttpError(m) -> "Ошибка запроса: " <> m
    ai.ApiError(status, body) ->
      "API вернул " <> int.to_string(status) <> ": " <> body
  }
}

fn field(values: List(#(String, String)), name: String) -> String {
  list.key_find(values, name) |> result.unwrap("")
}

// --- HTML ---

fn esc(s: String) -> String {
  wisp.escape_html(s)
}

fn page(body: String) -> Response {
  let html =
    "<!doctype html>
<html lang=\"ru\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>AI чат на Gleam</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 48rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }
  textarea, input { width: 100%; font: inherit; padding: .5rem; box-sizing: border-box; }
  textarea.json { font-family: ui-monospace, monospace; font-size: .85rem; }
  pre { background: #f4f4f5; padding: .75rem; border-radius: .5rem; overflow-x: auto; white-space: pre-wrap; font-size: .85rem; }
  .answer { background: #eef6ff; padding: .75rem; border-radius: .5rem; white-space: pre-wrap; }
  .error { background: #fee; color: #900; padding: .75rem; border-radius: .5rem; }
  button { font: inherit; padding: .4rem .9rem; cursor: pointer; }
  .actions { display: flex; gap: .5rem; flex-wrap: wrap; margin-top: .75rem; }
  label { display: block; margin-top: 1rem; font-weight: 600; }
  details { margin-top: 1rem; border: 1px solid #ddd; border-radius: .5rem; padding: .5rem .75rem; }
  details summary { cursor: pointer; font-weight: 600; }
  details[open] summary { margin-bottom: .5rem; }
  table { width: 100%; border-collapse: collapse; margin-top: .5rem; }
  td, th { text-align: left; border-bottom: 1px solid #ddd; padding: .35rem .25rem; }
  .hint { color: #666; font-size: .85rem; margin: .25rem 0 0; }
</style>
</head>
<body>
<h1>AI чат на Gleam</h1>
" <> body <> "
</body>
</html>"
  wisp.html_response(html, 200)
}

fn error_html(message: String) -> String {
  "<p class=\"error\">" <> esc(message) <> "</p>"
}

fn form_html(ctx: Context, question: String, request_json: String) -> String {
  let warning = case ctx.api_key {
    Error(_) ->
      "<p class=\"error\">OPENAI_API_KEY не задан — запрос отправить не получится.</p>"
    Ok(_) -> ""
  }
  warning
  <> "<form method=\"post\" action=\"/ask\">
  <label for=\"question\">Вопрос</label>
  <textarea id=\"question\" name=\"question\" rows=\"4\">" <> esc(question) <> "</textarea>
  <p class=\"hint\">Текст подставляется в JSON ниже. JSON можно править руками — отправляется именно он.</p>
  <details open>
    <summary>JSON запроса</summary>
    <textarea id=\"request_json\" name=\"request_json\" class=\"json\" rows=\"14\" spellcheck=\"false\">" <> esc(request_json) <> "</textarea>
    <p class=\"hint\" id=\"status\"></p>
    <div class=\"actions\">
      <button type=\"button\" id=\"format\">Форматировать</button>
      <button type=\"button\" id=\"reset\">Собрать заново из вопроса</button>
    </div>
  </details>
  <div class=\"actions\"><button type=\"submit\">Отправить</button></div>
</form>
<script>
  const question = document.getElementById('question');
  const editor = document.getElementById('request_json');
  const status = document.getElementById('status');
  const defaultModel = " <> quoted(ai.default_model) <> ";

  const parse = () => {
    try { return JSON.parse(editor.value); } catch (e) { return null; }
  };

  const check = () => {
    const ok = parse() !== null;
    status.textContent = ok ? 'JSON валиден' : 'JSON невалиден — отправка не пройдёт';
    status.style.color = ok ? '#2a7' : '#900';
    return ok;
  };

  const write = (value) => {
    editor.value = JSON.stringify(value, null, 2);
    check();
  };

  // Typing a question updates the first message, keeping any other edits.
  question.addEventListener('input', () => {
    const body = parse();
    if (!body) return;
    if (!Array.isArray(body.messages) || body.messages.length === 0) {
      body.messages = [{ role: 'user', content: '' }];
    }
    body.messages[0].content = question.value;
    write(body);
  });

  editor.addEventListener('input', check);

  document.getElementById('format').addEventListener('click', () => {
    const body = parse();
    if (body) write(body); else check();
  });

  document.getElementById('reset').addEventListener('click', () => {
    const body = parse();
    const model = body && body.model ? body.model : defaultModel;
    write({ model, messages: [{ role: 'user', content: question.value }] });
  });

  check();
</script>"
}

fn exchange_html(
  model: String,
  question: String,
  request_json: String,
  response_json: String,
) -> String {
  let answer =
    ai.extract_answer(response_json)
    |> result.unwrap("(в ответе нет поля choices[0].message.content)")
  "<h2>Вопрос</h2>
<p class=\"answer\">" <> esc(question) <> "</p>
<h2>Ответ (" <> esc(model) <> ")</h2>
<form>
  <textarea class=\"answer\" rows=\"10\" readonly>" <> esc(answer) <> "</textarea>
</form>
<details>
  <summary>JSON запроса</summary>
  <pre>" <> esc(ai.pretty(request_json)) <> "</pre>
</details>
<details>
  <summary>JSON ответа</summary>
  <pre>" <> esc(ai.pretty(response_json)) <> "</pre>
</details>"
}

fn quoted(value: String) -> String {
  "\"" <> value <> "\""
}

fn history_html(items: List(db.Exchange)) -> String {
  case items {
    [] -> ""
    _ -> {
      let rows =
        items
        |> list.map(fn(e) {
          "<tr><td><a href=\"/exchanges/"
          <> int.to_string(e.id)
          <> "\">#"
          <> int.to_string(e.id)
          <> "</a></td><td>"
          <> esc(e.created_at)
          <> "</td><td>"
          <> esc(string.slice(e.question, 0, 60))
          <> "</td></tr>"
        })
        |> string.join("")
      "<h2>История</h2><table><tr><th>ID</th><th>Время (UTC)</th><th>Вопрос</th></tr>"
      <> rows
      <> "</table>"
    }
  }
}
