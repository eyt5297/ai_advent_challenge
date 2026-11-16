import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import shared/api
import shared/catalog
import shared/codec
import shared/types.{AlwaysReasoning, NoReasoning, OptionalReasoning}

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── Каталог ─────────────────────────────────────────────────────────────────

pub fn catalog_has_both_providers_test() {
  let ids = catalog.providers() |> list.map(fn(provider) { provider.id })
  assert ids == ["veai", "kimi"]
}

pub fn catalog_model_counts_test() {
  assert list.length(catalog.models("veai")) == 36
  assert list.length(catalog.models("kimi")) == 6
}

pub fn catalog_default_models_exist_test() {
  let assert Ok(veai) = catalog.provider("veai")
  let assert Ok(_) = types.find_model(veai, veai.default_model)

  let assert Ok(kimi) = catalog.provider("kimi")
  let assert Ok(_) = types.find_model(kimi, kimi.default_model)
}

pub fn catalog_model_ids_are_unique_test() {
  list.each(["veai", "kimi"], fn(provider_id) {
    let ids = catalog.models(provider_id) |> list.map(fn(model) { model.id })
    assert list.length(ids) == list.length(list.unique(ids))
  })
}

/// Алиасы маршрутизации veai собраны в отдельную группу.
pub fn catalog_veai_auto_group_test() {
  let assert Ok(veai) = catalog.provider("veai")
  let assert Ok(aliases) =
    list.find(veai.groups, fn(group) { group.title == "Авто" })
  let ids =
    aliases.models
    |> list.map(fn(model) { model.id })
    |> list.sort(string.compare)
  assert ids == ["auto", "autopilot", "free"]
}

/// Эти две модели не рассуждают — для них панель ⚙ прячет блок reasoning.
pub fn catalog_models_without_reasoning_test() {
  let assert Ok(haiku) = catalog.model("veai", "Anthropic/haiku-4.5")
  assert haiku.reasoning == NoReasoning

  let assert Ok(lite) = catalog.model("veai", "Google/gemini-3.5-flash-lite")
  assert lite.reasoning == NoReasoning
}

/// Шкалы усилий у провайдеров разные — это и проверяем.
pub fn catalog_effort_scales_differ_test() {
  let assert Ok(sonnet) = catalog.model("veai", "Anthropic/sonnet-5")
  assert types.reasoning_efforts(sonnet)
    == ["low", "medium", "high", "xhigh", "max"]

  let assert Ok(k3) = catalog.model("kimi", "k3.1-pro")
  assert types.reasoning_efforts(k3) == ["low", "high", "max"]
}

/// У kimi рассуждения выключить нельзя, у veai — можно.
pub fn catalog_reasoning_toggle_test() {
  let assert Ok(k3) = catalog.model("kimi", "k3.1-pro")
  assert types.can_disable_reasoning(k3) == False
  let assert AlwaysReasoning(..) = k3.reasoning

  let assert Ok(sonnet) = catalog.model("veai", "Anthropic/sonnet-5")
  assert types.can_disable_reasoning(sonnet) == True
  let assert OptionalReasoning(..) = sonnet.reasoning
}

pub fn catalog_default_model_falls_back_test() {
  let assert Some(model) = catalog.default_model("veai")
  assert model.id == "Anthropic/sonnet-5"

  assert catalog.default_model("нет-такого") == None
}

pub fn catalog_unknown_lookups_test() {
  assert catalog.provider("нет-такого") == Error(Nil)
  assert catalog.model("veai", "нет-такой") == Error(Nil)
  assert catalog.models("нет-такого") == []
}

// ─── RequestOptions ──────────────────────────────────────────────────────────

pub fn options_default_is_empty_test() {
  let options = types.default_options()
  assert types.active_option_count(options) == 0
  assert options.stream == False
}

pub fn options_active_count_test() {
  let options =
    types.RequestOptions(
      ..types.default_options(),
      temperature: Some(0.7),
      reasoning_effort: Some("medium"),
    )
  assert types.active_option_count(options) == 2
}

/// Ключевое свойство: None и Some(0.0) — разные вещи, и это переживает
/// round-trip через JSON.
pub fn options_roundtrip_preserves_none_test() {
  let explicit_zero =
    types.RequestOptions(..types.default_options(), temperature: Some(0.0))
  let encoded = codec.options_to_string(explicit_zero)
  assert codec.options_from_string(encoded) == explicit_zero

  let untouched = types.default_options()
  assert codec.options_from_string(codec.options_to_string(untouched))
    == untouched

  assert explicit_zero != untouched
}

pub fn options_roundtrip_full_test() {
  let options =
    types.RequestOptions(
      temperature: Some(1.25),
      max_tokens: Some(4096),
      system_prompt: Some("ты лаконичен"),
      reasoning_enabled: Some(True),
      reasoning_effort: Some("xhigh"),
      stream: False,
    )
  assert codec.options_from_string(codec.options_to_string(options)) == options
}

/// Битый params_json из БД не должен ронять загрузку сессии.
pub fn options_from_broken_json_test() {
  assert codec.options_from_string("не json") == types.default_options()
  assert codec.options_from_string("{}") == types.default_options()
}

// ─── Сообщения ───────────────────────────────────────────────────────────────

fn sample_message() -> types.Message {
  types.Message(
    id: "msg-1",
    session_id: "ses-1",
    seq: 2,
    role: types.Assistant,
    content: "Связь есть.",
    reasoning: Some("думаю…"),
    provider_id: Some("veai"),
    model_id: Some("Anthropic/sonnet-5"),
    status: types.Done,
    error: None,
    params: Some(
      types.RequestOptions(..types.default_options(), temperature: Some(0.7)),
    ),
    hand_edited: False,
    raw_request: None,
    raw_response: Some("{\"choices\":[]}"),
    http_status: Some(200),
    latency_ms: Some(842),
    usage: Some(types.Usage(10, 20, 30)),
    reply_to: Some("msg-0"),
    task_id: Some("tsk-1"),
    step: Some(1),
    tool_calls: [types.ToolCall("call-1", "now", "{}")],
    tool_call_id: None,
    created_at: 1_763_000_000_000,
  )
}

pub fn message_roundtrip_test() {
  let message = sample_message()
  let encoded = message |> codec.message_to_json |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, codec.message_decoder())
  assert decoded == message
}

pub fn message_error_roundtrip_test() {
  let message =
    types.Message(
      ..sample_message(),
      status: types.Failed,
      content: "",
      error: Some("429 Too Many Requests"),
      usage: None,
      hand_edited: True,
    )
  let encoded = message |> codec.message_to_json |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, codec.message_decoder())
  assert decoded == message
}

pub fn role_and_status_strings_test() {
  list.each([types.System, types.User, types.Assistant, types.Tool], fn(role) {
    assert types.role_from_string(types.role_to_string(role)) == Ok(role)
  })
  list.each([types.Pending, types.Done, types.Failed], fn(status) {
    assert types.status_from_string(types.status_to_string(status))
      == Ok(status)
  })
  assert types.role_from_string("function") == Error(Nil)
  assert types.status_from_string("???") == Error(Nil)
}

// ─── Сессии ──────────────────────────────────────────────────────────────────

pub fn session_roundtrip_test() {
  let session =
    types.Session(
      id: "ses-1",
      title: "Проверка связи",
      created_at: 1,
      updated_at: 2,
      agent_id: Some("agt-1"),
      provider_id: Some("kimi"),
      model_id: Some("k3.1-pro"),
      params: types.RequestOptions(
        ..types.default_options(),
        max_tokens: Some(1024),
      ),
    )
  let encoded = session |> codec.session_to_json |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, codec.session_decoder())
  assert decoded == session
}

// ─── API DTO ─────────────────────────────────────────────────────────────────

pub fn send_request_roundtrip_test() {
  let request =
    api.SendRequest(
      provider_id: "veai",
      model_id: "Anthropic/sonnet-5",
      content: "привет",
      params: types.RequestOptions(
        ..types.default_options(),
        temperature: Some(0.3),
      ),
      raw_request_override: None,
    )
  let encoded = request |> api.send_request_to_json |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, api.send_request_decoder())
  assert decoded == request
}

/// Минимальное тело запроса от клиента должно разбираться: params
/// и override необязательны.
pub fn send_request_minimal_test() {
  let assert Ok(request) =
    json.parse(
      "{\"provider_id\":\"veai\",\"model_id\":\"m\",\"content\":\"привет\"}",
      api.send_request_decoder(),
    )
  assert request.params == types.default_options()
  assert request.raw_request_override == None
}

pub fn preview_response_roundtrip_test() {
  let response =
    api.PreviewResponse(
      raw_request: "{\n  \"model\": \"m\"\n}",
      effective_params: types.default_options(),
      warnings: ["effort 'xhigh' не поддерживается kimi, заменён на 'high'"],
    )
  let encoded = response |> api.preview_response_to_json |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, api.preview_response_decoder())
  assert decoded == response
}

pub fn catalog_response_roundtrip_test() {
  let assert Ok(veai) = catalog.provider("veai")
  let response =
    api.CatalogResponse(providers: [types.ProviderStatus(veai, True)])
  let encoded = response |> api.catalog_response_to_json |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, api.catalog_response_decoder())
  assert decoded == response
}

pub fn api_error_decoder_test() {
  let encoded = codec.error_to_json("bad_request", "нет поля content")
  let assert Ok(error) =
    json.parse(json.to_string(encoded), codec.api_error_decoder())
  assert error == codec.ApiError("bad_request", "нет поля content")
}
