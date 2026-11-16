//// Тесты точек расширения: сборка запроса, нормализация параметров,
//// разбор ответа. Это то, что будет меняться чаще всего, поэтому покрыто
//// плотнее остального.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import server/agent/tools
import server/llm/chat
import server/llm/request
import server/llm/response
import shared/catalog
import shared/types.{type ModelInfo, type Provider}

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── Фикстуры ────────────────────────────────────────────────────────────────

fn veai() -> Provider {
  let assert Ok(provider) = catalog.provider("veai")
  provider
}

fn kimi() -> Provider {
  let assert Ok(provider) = catalog.provider("kimi")
  provider
}

/// veai, рассуждения опциональны, шкала из пяти значений.
fn sonnet() -> ModelInfo {
  let assert Ok(model) = catalog.model("veai", "Anthropic/sonnet-5")
  model
}

/// veai, рассуждений нет вовсе.
fn haiku() -> ModelInfo {
  let assert Ok(model) = catalog.model("veai", "Anthropic/haiku-4.5")
  model
}

/// kimi, рассуждения всегда включены, шкала из трёх значений.
fn k3() -> ModelInfo {
  let assert Ok(model) = catalog.model("kimi", "k3.1-pro")
  model
}

fn context(
  model: ModelInfo,
  options: types.RequestOptions,
) -> request.RequestContext {
  request.RequestContext(
    provider: veai(),
    model: model,
    user_content: Some("привет"),
    history: [],
    options: options,
    tools: [],
  )
}

fn body(ctx: request.RequestContext) -> String {
  ctx |> request.build_request_body |> json.to_string
}

// ─── build_request_body ──────────────────────────────────────────────────────

/// Минимальный запрос: ничего лишнего, только model и messages.
pub fn build_minimal_body_test() {
  let result = body(context(sonnet(), types.default_options()))
  assert result
    == "{\"model\":\"Anthropic/sonnet-5\",\"messages\":[{\"role\":\"user\",\"content\":\"привет\"}]}"
}

/// Незаданные параметры не должны появляться в теле даже как null.
pub fn build_omits_unset_params_test() {
  let result = body(context(sonnet(), types.default_options()))
  assert !contains(result, "temperature")
  assert !contains(result, "max_tokens")
  assert !contains(result, "reasoning")
  assert !contains(result, "stream")
}

pub fn build_includes_set_params_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      temperature: Some(0.7),
      max_tokens: Some(4096),
    )
  let result = body(context(sonnet(), options))
  assert contains(result, "\"temperature\":0.7")
  assert contains(result, "\"max_tokens\":4096")
}

/// Явный ноль — это значение, а не отсутствие значения.
pub fn build_includes_zero_temperature_test() {
  let options =
    types.RequestOptions(..types.default_options(), temperature: Some(0.0))
  assert contains(body(context(sonnet(), options)), "\"temperature\":0.0")
}

pub fn build_adds_system_prompt_first_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      system_prompt: Some("будь краток"),
    )
  let result = body(context(sonnet(), options))
  assert contains(
    result,
    "[{\"role\":\"system\",\"content\":\"будь краток\"},{\"role\":\"user\"",
  )
}

/// Пустой system prompt не должен порождать пустое сообщение.
pub fn build_skips_blank_system_prompt_test() {
  let options =
    types.RequestOptions(..types.default_options(), system_prompt: Some("   "))
  assert !contains(body(context(sonnet(), options)), "system")
}

/// veai принимает объект reasoning.
pub fn build_reasoning_object_for_veai_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      reasoning_enabled: Some(True),
      reasoning_effort: Some("xhigh"),
    )
  let result = body(context(sonnet(), options))
  assert contains(
    result,
    "\"reasoning\":{\"enabled\":true,\"effort\":\"xhigh\"}",
  )
}

/// kimi управляет усилием плоским полем и не умеет выключать рассуждения.
pub fn build_reasoning_effort_for_kimi_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      reasoning_effort: Some("high"),
    )
  let ctx =
    request.RequestContext(
      provider: kimi(),
      model: k3(),
      user_content: Some("привет"),
      history: [],
      options: options,
      tools: [],
    )
  let result = body(ctx)
  assert contains(result, "\"reasoning_effort\":\"high\"")
  assert !contains(result, "\"reasoning\":{")
}

/// Модели без рассуждений не должны получать эти поля ни в каком виде.
pub fn build_no_reasoning_for_unsupported_model_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      reasoning_enabled: Some(True),
      reasoning_effort: Some("high"),
    )
  assert !contains(body(context(haiku(), options)), "reasoning")
}

/// В MVP история пуста, но механизм уже работает.
pub fn build_includes_history_test() {
  let history = [
    sample_message(types.User, "первый вопрос"),
    sample_message(types.Assistant, "первый ответ"),
  ]
  let ctx =
    request.RequestContext(
      ..context(sonnet(), types.default_options()),
      history: history,
    )
  let result = body(ctx)
  assert contains(result, "первый вопрос")
  assert contains(result, "первый ответ")
}

fn sample_message(role: types.Role, content: String) -> types.Message {
  types.Message(
    id: "m",
    session_id: "s",
    seq: 1,
    role: role,
    content: content,
    reasoning: None,
    provider_id: None,
    model_id: None,
    status: types.Done,
    error: None,
    params: None,
    hand_edited: False,
    raw_request: None,
    raw_response: None,
    http_status: None,
    latency_ms: None,
    usage: None,
    reply_to: None,
    task_id: None,
    step: None,
    tool_calls: [],
    tool_call_id: None,
    created_at: 0,
  )
}

// ─── normalize_options ───────────────────────────────────────────────────────

fn normalize(
  provider: Provider,
  model: ModelInfo,
  options: types.RequestOptions,
) -> #(types.RequestOptions, List(String)) {
  let #(normalized, warnings) =
    request.normalize_options(provider, model, options)
  #(normalized, list.map(warnings, fn(warning) { warning.message }))
}

pub fn normalize_passes_valid_options_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      temperature: Some(0.7),
      max_tokens: Some(1024),
      reasoning_effort: Some("medium"),
    )
  let #(normalized, warnings) = normalize(veai(), sonnet(), options)
  assert normalized == options
  assert warnings == []
}

pub fn normalize_clamps_temperature_test() {
  let options =
    types.RequestOptions(..types.default_options(), temperature: Some(5.0))
  let #(normalized, warnings) = normalize(veai(), sonnet(), options)
  assert normalized.temperature == Some(2.0)
  assert list.length(warnings) == 1
}

pub fn normalize_clamps_max_tokens_test() {
  let options =
    types.RequestOptions(..types.default_options(), max_tokens: Some(999_999))
  let #(normalized, warnings) = normalize(veai(), sonnet(), options)
  assert normalized.max_tokens == Some(sonnet().max_output_tokens)
  assert list.length(warnings) == 1
}

/// kimi не сообщает лимит вывода — значит и ограничивать нечем.
pub fn normalize_keeps_max_tokens_when_limit_unknown_test() {
  let options =
    types.RequestOptions(..types.default_options(), max_tokens: Some(999_999))
  let #(normalized, warnings) = normalize(kimi(), k3(), options)
  assert normalized.max_tokens == Some(999_999)
  assert warnings == []
}

/// Главный сценарий расхождения шкал: xhigh есть у veai, нет у kimi.
pub fn normalize_replaces_unsupported_effort_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      reasoning_effort: Some("xhigh"),
    )
  let #(normalized, warnings) = normalize(kimi(), k3(), options)
  assert normalized.reasoning_effort == Some("max")
  assert list.length(warnings) == 1
}

/// medium у kimi тоже нет — ближайшим оказывается high.
pub fn normalize_replaces_medium_for_kimi_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      reasoning_effort: Some("medium"),
    )
  let #(normalized, _) = normalize(kimi(), k3(), options)
  assert normalized.reasoning_effort == Some("high")
}

/// Рассуждения у kimi не выключаются — флаг снимается с предупреждением.
pub fn normalize_drops_disable_for_always_reasoning_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      reasoning_enabled: Some(False),
    )
  let #(normalized, warnings) = normalize(kimi(), k3(), options)
  assert normalized.reasoning_enabled == None
  assert list.length(warnings) == 1
}

/// Для модели без рассуждений параметры отбрасываются — иначе провайдер
/// ответит 400.
pub fn normalize_clears_reasoning_for_unsupported_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      reasoning_enabled: Some(True),
      reasoning_effort: Some("high"),
    )
  let #(normalized, warnings) = normalize(veai(), haiku(), options)
  assert normalized.reasoning_enabled == None
  assert normalized.reasoning_effort == None
  assert list.length(warnings) == 1
}

pub fn normalize_trims_blank_system_prompt_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      system_prompt: Some("  \n "),
    )
  let #(normalized, _) = normalize(veai(), sonnet(), options)
  assert normalized.system_prompt == None
}

/// Нормализация не должна «будить» незаданные параметры.
pub fn normalize_keeps_defaults_untouched_test() {
  let #(normalized, warnings) =
    normalize(veai(), sonnet(), types.default_options())
  assert normalized == types.default_options()
  assert warnings == []
}

// ─── parse_response_body ─────────────────────────────────────────────────────

fn parse(status: Int, body: String) {
  response.parse_response_body(veai(), status, body)
}

pub fn parse_simple_response_test() {
  let assert Ok(parsed) =
    parse(
      200,
      "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Связь есть.\"},\"finish_reason\":\"stop\"}]}",
    )
  assert parsed.content == "Связь есть."
  assert parsed.finish_reason == Some("stop")
}

// ─── Инструменты в теле запроса ──────────────────────────────────────────────

/// Без инструментов поле `tools` не появляется вовсе: пустой массив часть
/// провайдеров считает ошибкой.
pub fn request_omits_tools_when_empty_test() {
  let rendered = body(context(sonnet(), types.default_options()))
  assert !string.contains(rendered, "tools")
}

pub fn request_declares_tools_test() {
  let rendered =
    body(
      request.RequestContext(
        ..context(sonnet(), types.default_options()),
        tools: list.map(tools.selected(["now", "calc"]), tools.to_json),
      ),
    )

  assert string.contains(rendered, "\"tools\"")
  assert string.contains(rendered, "\"name\":\"now\"")
  assert string.contains(rendered, "\"name\":\"calc\"")
  assert string.contains(rendered, "\"tool_choice\":\"auto\"")
  // Не выданный агенту инструмент не объявляется.
  assert !string.contains(rendered, "roll_dice")
}

/// Ответ с вызовом должен вернуться модели вместе со своими tool_calls,
/// а результат — со ссылкой tool_call_id. Иначе провайдер отвергнет запрос.
pub fn request_replays_tool_protocol_test() {
  let answer =
    types.Message(..sample_message(types.Assistant, ""), tool_calls: [
      types.ToolCall("call_1", "now", "{}"),
    ])
  let result =
    types.Message(
      ..sample_message(types.Tool, "{\"iso\":\"2026-01-01T00:00:00Z\"}"),
      tool_call_id: Some("call_1"),
    )

  let rendered =
    body(
      request.RequestContext(
        ..context(sonnet(), types.default_options()),
        user_content: None,
        history: [sample_message(types.User, "который час"), answer, result],
      ),
    )

  assert string.contains(rendered, "\"tool_calls\"")
  assert string.contains(rendered, "\"id\":\"call_1\"")
  assert string.contains(rendered, "\"tool_call_id\":\"call_1\"")
  assert string.contains(rendered, "\"role\":\"tool\"")
}

/// Продолжение истории не повторяет задание: модель сочла бы это новой
/// просьбой и вызвала инструмент ещё раз.
pub fn request_without_new_message_test() {
  let rendered =
    body(
      request.RequestContext(
        ..context(sonnet(), types.default_options()),
        user_content: None,
        history: [sample_message(types.User, "посчитай")],
      ),
    )

  let assert Ok(parsed) =
    json.parse(rendered, decode.at(["messages"], decode.list(decode.dynamic)))
  assert list.length(parsed) == 1
}

/// Вызов инструмента: пустой content здесь норма, вся нагрузка в tool_calls.
pub fn parse_tool_calls_test() {
  let assert Ok(parsed) =
    parse(
      200,
      "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,"
        <> "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\","
        <> "\"function\":{\"name\":\"roll_dice\",\"arguments\":\"{\\\"sides\\\":6}\"}}]},"
        <> "\"finish_reason\":\"tool_calls\"}]}",
    )

  assert parsed.content == ""
  assert parsed.finish_reason == Some("tool_calls")
  assert parsed.tool_calls
    == [types.ToolCall("call_1", "roll_dice", "{\"sides\":6}")]
}

/// Несколько вызовов за один раз — модель вправе так сделать.
pub fn parse_multiple_tool_calls_test() {
  let assert Ok(parsed) =
    parse(
      200,
      "{\"choices\":[{\"message\":{\"content\":\"\",\"tool_calls\":["
        <> "{\"id\":\"a\",\"function\":{\"name\":\"now\",\"arguments\":\"{}\"}},"
        <> "{\"id\":\"b\",\"function\":{\"name\":\"calc\",\"arguments\":\"{}\"}}]}}]}",
    )

  assert list.map(parsed.tool_calls, fn(call) { call.name }) == ["now", "calc"]
}

/// Невалидный JSON в аргументах не должен ронять разбор всего ответа:
/// это ошибка конкретного инструмента, он сам о ней сообщит модели.
pub fn parse_keeps_broken_arguments_test() {
  let assert Ok(parsed) =
    parse(
      200,
      "{\"choices\":[{\"message\":{\"content\":\"\",\"tool_calls\":["
        <> "{\"id\":\"a\",\"function\":{\"name\":\"calc\",\"arguments\":\"не json\"}}]}}]}",
    )

  assert list.map(parsed.tool_calls, fn(call) { call.arguments }) == ["не json"]
}

/// Обычный ответ инструментов не содержит — список пуст, а не отсутствует.
pub fn parse_without_tools_test() {
  let assert Ok(parsed) =
    parse(200, "{\"choices\":[{\"message\":{\"content\":\"просто текст\"}}]}")

  assert parsed.tool_calls == []
}

/// Пустой ответ без инструментов по-прежнему считается ошибкой.
pub fn parse_empty_without_tools_fails_test() {
  let assert Error(_) =
    parse(200, "{\"choices\":[{\"message\":{\"content\":\"\"}}]}")
  Nil
}

pub fn parse_usage_test() {
  let assert Ok(parsed) =
    parse(
      200,
      "{\"choices\":[{\"message\":{\"content\":\"ок\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}",
    )
  assert parsed.usage == Some(types.Usage(10, 5, 15))
}

/// Рассуждения kimi не должны ломать разбор и не теряются.
pub fn parse_reasoning_content_test() {
  let assert Ok(parsed) =
    parse(
      200,
      "{\"choices\":[{\"message\":{\"content\":\"ответ\",\"reasoning_content\":\"размышления\"}}]}",
    )
  assert parsed.content == "ответ"
  assert parsed.reasoning == Some("размышления")
}

/// content может прийти массивом частей.
pub fn parse_content_parts_test() {
  let assert Ok(parsed) =
    parse(
      200,
      "{\"choices\":[{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"часть 1\"},{\"type\":\"text\",\"text\":\" часть 2\"}]}}]}",
    )
  assert parsed.content == "часть 1 часть 2"
}

/// content: null при наличии рассуждений — валидный ответ.
pub fn parse_null_content_with_reasoning_test() {
  let assert Ok(parsed) =
    parse(
      200,
      "{\"choices\":[{\"message\":{\"content\":null,\"reasoning_content\":\"только думал\"}}]}",
    )
  assert parsed.content == ""
  assert parsed.reasoning == Some("только думал")
}

pub fn parse_provider_error_test() {
  let assert Error(error) =
    parse(
      429,
      "{\"error\":{\"message\":\"rate limit exceeded\",\"type\":\"rate_limit_error\"}}",
    )
  assert error
    == response.ProviderError("rate_limit_error", "rate limit exceeded")
}

/// Код ошибки иногда приходит числом.
pub fn parse_numeric_error_code_test() {
  let assert Error(response.ProviderError(code, _)) =
    parse(400, "{\"error\":{\"message\":\"bad\",\"code\":40001}}")
  assert code == "40001"
}

/// Ошибка без распознаваемой структуры всё равно должна дать текст для UI.
pub fn parse_plain_text_error_test() {
  let assert Error(response.ProviderError(code, message)) =
    parse(502, "<html>Bad Gateway</html>")
  assert code == "http_502"
  assert message == "<html>Bad Gateway</html>"
}

pub fn parse_empty_body_test() {
  let assert Error(response.ProviderError(_, message)) = parse(500, "")
  assert message == "пустое тело"
}

/// Ошибка в теле с кодом 200 — такое встречается у прокси.
pub fn parse_error_in_200_body_test() {
  let assert Error(response.ProviderError(_, message)) =
    parse(200, "{\"error\":{\"message\":\"что-то пошло не так\"}}")
  assert message == "что-то пошло не так"
}

pub fn parse_unexpected_shape_test() {
  let assert Error(response.UnexpectedShape(_)) =
    parse(200, "{\"result\":\"непонятно\"}")
  Nil
}

pub fn parse_invalid_json_test() {
  let assert Error(response.InvalidJson(_)) = parse(200, "не json вовсе")
  Nil
}

/// Пустой ответ без рассуждений показывать нечем — это ошибка.
pub fn parse_empty_content_is_error_test() {
  let assert Error(response.UnexpectedShape(_)) =
    parse(200, "{\"choices\":[{\"message\":{\"content\":\"\"}}]}")
  Nil
}

pub fn parse_empty_choices_test() {
  let assert Error(_) = parse(200, "{\"choices\":[]}")
  Nil
}

// ─── Форматирование JSON ─────────────────────────────────────────────────────

pub fn pretty_formats_nested_test() {
  let formatted = chat.pretty("{\"a\":1,\"b\":{\"c\":[1,2]}}")
  assert formatted
    == "{\n  \"a\": 1,\n  \"b\": {\n    \"c\": [\n      1,\n      2\n    ]\n  }\n}"
}

pub fn pretty_keeps_empty_containers_inline_test() {
  assert chat.pretty("{\"a\":{},\"b\":[]}") == "{\n  \"a\": {},\n  \"b\": []\n}"
}

/// Скобки и запятые внутри строк не должны влиять на отступы.
pub fn pretty_ignores_punctuation_in_strings_test() {
  assert chat.pretty("{\"text\":\"a,b{c}\"}") == "{\n  \"text\": \"a,b{c}\"\n}"
}

/// Экранированная кавычка не должна «закрывать» строку.
pub fn pretty_handles_escaped_quotes_test() {
  assert chat.pretty("{\"t\":\"\\\"x\\\",y\"}")
    == "{\n  \"t\": \"\\\"x\\\",y\"\n}"
}

/// Отформатированное тело остаётся валидным JSON.
pub fn pretty_output_is_valid_json_test() {
  let original =
    body(context(
      sonnet(),
      types.RequestOptions(
        ..types.default_options(),
        temperature: Some(0.7),
        system_prompt: Some("строка с \"кавычками\" и {скобками}"),
      ),
    ))
  let assert Ok(_) = json.parse(chat.pretty(original), decode.dynamic)
  Nil
}

// ─── Вспомогательное ─────────────────────────────────────────────────────────

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(does: haystack, contain: needle)
}
