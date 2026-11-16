//// ★ ТОЧКА РАСШИРЕНИЯ №1 — сборка тела запроса к провайдеру.
////
//// Сигнатуры `build_request_body` и `normalize_options` заморожены: вся
//// будущая работа (история диалога, стриминг, tools, вложения) происходит
//// внутри них, не затрагивая UI, БД и транспорт.

import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import shared/types.{
  type Message, type ModelInfo, type Provider, type RequestOptions,
  AlwaysReasoning, NoReasoning, OptionalReasoning,
}

/// Всё, из чего собирается запрос.
///
/// `history` уже здесь, хотя в MVP всегда пустой: включение мультитёрнового
/// режима не изменит сигнатуру — только тело `build_request_body`.
pub type RequestContext {
  RequestContext(
    provider: Provider,
    model: ModelInfo,
    /// Новое сообщение пользователя.
    ///
    /// None — запрос продолжает историю: так выглядит шаг агента после
    /// вызова инструментов. Повторять там задание нельзя, модель сочла
    /// бы его новой просьбой и вызвала инструмент ещё раз.
    user_content: Option(String),
    /// Предыдущие сообщения сессии. В MVP всегда [].
    history: List(Message),
    /// Уже нормализованные параметры (см. normalize_options).
    options: RequestOptions,
    /// Объявления инструментов в формате провайдера. Пусто — поле `tools`
    /// в теле не появляется вовсе: модели без него спокойнее.
    tools: List(Json),
  )
}

/// Собирает JSON-тело запроса.
///
/// Текущая реализация — OpenAI-совместимый chat/completions. Оба провайдера
/// говорят на нём, поэтому ветвления по провайдеру пока нет; когда появится
/// несовместимый провайдер, `case ctx.provider.id` добавляется здесь.
pub fn build_request_body(ctx: RequestContext) -> Json {
  let fields =
    [#("model", json.string(ctx.model.id)), #("messages", build_messages(ctx))]
    |> append_option("temperature", ctx.options.temperature, json.float)
    |> append_option("max_tokens", ctx.options.max_tokens, json.int)
    |> append_reasoning(ctx)
    |> append_tools(ctx)
    |> append_stream(ctx)

  json.object(fields)
}

/// Список сообщений: system (если задан) + история + текущий вопрос.
fn build_messages(ctx: RequestContext) -> Json {
  let system = case ctx.options.system_prompt {
    Some(prompt) ->
      case string.trim(prompt) {
        "" -> []
        text -> [chat_message("system", text)]
      }
    None -> []
  }

  // Внутри задания агента история — это предыдущие шаги; у обычной
  // сессии она пуста, и каждый запрос независим.
  //
  // Служебные строки отбрасываются: у шага, инициированного циклом,
  // текст запроса пуст — он существует ради `raw_request` в БД. В теле
  // запроса пустое `user` между результатом инструмента и следующим
  // ответом только сбивает модель, а некоторые провайдеры его отвергают.
  let history =
    ctx.history
    |> list.filter(carries_meaning)
    |> list.map(history_message)

  let current = case ctx.user_content {
    Some(content) -> [chat_message("user", content)]
    None -> []
  }

  json.preprocessed_array(list.flatten([system, history, current]))
}

/// Несёт ли сообщение что-то для модели.
///
/// Отбрасываются только пустые служебные строки: у шага, инициированного
/// циклом, текст запроса пуст — он существует ради `raw_request` в БД.
///
/// По статусу **не фильтруем**. Неудачный вызов инструмента помечен
/// `error`, но именно его модель и должна увидеть: иначе она попросит
/// то же самое снова и будет повторять до исчерпания лимита шагов.
/// Отказ — это ответ, а не отсутствие ответа.
fn carries_meaning(message: Message) -> Bool {
  string.trim(message.content) != "" || message.tool_calls != []
}

/// Сообщение истории в формате провайдера.
///
/// Протокол требовательнее, чем кажется: ответ с вызовом инструмента
/// должен вернуться вместе со своими `tool_calls`, а результат — со
/// ссылкой `tool_call_id`. Без этого провайдер отвергает запрос.
fn history_message(message: Message) -> Json {
  let role = types.role_to_string(message.role)

  case message.role, message.tool_calls {
    types.Tool, _ ->
      json.object([
        #("role", json.string(role)),
        #("content", json.string(message.content)),
        #("tool_call_id", json.string(option.unwrap(message.tool_call_id, ""))),
      ])

    _, [_, ..] ->
      json.object([
        #("role", json.string(role)),
        #("content", json.string(message.content)),
        #("tool_calls", json.array(message.tool_calls, outgoing_tool_call)),
      ])

    _, [] -> chat_message(role, message.content)
  }
}

/// Вызов в том виде, в каком его ждёт провайдер обратно.
fn outgoing_tool_call(call: types.ToolCall) -> Json {
  json.object([
    #("id", json.string(call.id)),
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(call.name)),
        #("arguments", json.string(call.arguments)),
      ]),
    ),
  ])
}

/// Инструменты добавляются только когда они есть: пустой массив `tools`
/// некоторые провайдеры воспринимают как ошибку.
fn append_tools(
  fields: List(#(String, Json)),
  ctx: RequestContext,
) -> List(#(String, Json)) {
  case ctx.tools {
    [] -> fields
    tools ->
      list.append(fields, [
        #("tools", json.preprocessed_array(tools)),
        #("tool_choice", json.string("auto")),
      ])
  }
}

fn chat_message(role: String, content: String) -> Json {
  json.object([
    #("role", json.string(role)),
    #("content", json.string(content)),
  ])
}

fn append_option(
  fields: List(#(String, Json)),
  key: String,
  value: Option(a),
  encode: fn(a) -> Json,
) -> List(#(String, Json)) {
  case value {
    Some(inner) -> list.append(fields, [#(key, encode(inner))])
    None -> fields
  }
}

/// Блок рассуждений в формате провайдера.
///
/// Единственное место, где диалекты расходятся: veai принимает объект
/// `reasoning: { enabled, effort }`, kimi управляет усилием через
/// `reasoning_effort` и выключать рассуждения не умеет.
fn append_reasoning(
  fields: List(#(String, Json)),
  ctx: RequestContext,
) -> List(#(String, Json)) {
  let enabled = ctx.options.reasoning_enabled
  let effort = ctx.options.reasoning_effort

  case ctx.model.reasoning, enabled, effort {
    // Модель не рассуждает — не шлём ничего, иначе провайдер ответит 400.
    NoReasoning, _, _ -> fields

    // Ничего не задано — пусть решает провайдер.
    _, None, None -> fields

    AlwaysReasoning(..), _, _ ->
      case effort {
        Some(value) ->
          list.append(fields, [#("reasoning_effort", json.string(value))])
        None -> fields
      }

    OptionalReasoning(..), _, _ -> {
      let inner =
        []
        |> append_option("enabled", enabled, json.bool)
        |> append_option("effort", effort, json.string)
      list.append(fields, [#("reasoning", json.object(inner))])
    }
  }
}

fn append_stream(
  fields: List(#(String, Json)),
  ctx: RequestContext,
) -> List(#(String, Json)) {
  case ctx.options.stream {
    True -> list.append(fields, [#("stream", json.bool(True))])
    // В MVP ключ не пишем вовсе — чтобы сырой JSON оставался минимальным.
    False -> fields
  }
}

// ─── Нормализация параметров ─────────────────────────────────────────────────

/// Что пришлось поправить, чтобы запрос не отвергли.
pub type Warning {
  Warning(message: String)
}

/// Приводит параметры к тому, что понимает конкретная модель.
///
/// Вызывается до `build_request_body`; её результат сохраняется в
/// `messages.params_json`, то есть в БД лежит то, что действительно ушло.
pub fn normalize_options(
  provider: Provider,
  model: ModelInfo,
  options: RequestOptions,
) -> #(RequestOptions, List(Warning)) {
  let #(options, temperature_warnings) = normalize_temperature(options)
  let #(options, tokens_warnings) = normalize_max_tokens(model, options)
  let #(options, prompt_warnings) = normalize_system_prompt(options)
  let #(options, reasoning_warnings) =
    normalize_reasoning(provider, model, options)

  #(
    options,
    list.flatten([
      temperature_warnings,
      tokens_warnings,
      prompt_warnings,
      reasoning_warnings,
    ]),
  )
}

fn normalize_temperature(
  options: RequestOptions,
) -> #(RequestOptions, List(Warning)) {
  case options.temperature {
    None -> #(options, [])
    Some(value) -> {
      let clamped = clamp_float(value, 0.0, 2.0)
      case clamped == value {
        True -> #(options, [])
        False -> #(types.RequestOptions(..options, temperature: Some(clamped)), [
          Warning(
            "temperature "
            <> float_to_string(value)
            <> " вне диапазона 0.0–2.0, заменена на "
            <> float_to_string(clamped),
          ),
        ])
      }
    }
  }
}

fn normalize_max_tokens(
  model: ModelInfo,
  options: RequestOptions,
) -> #(RequestOptions, List(Warning)) {
  case options.max_tokens {
    None -> #(options, [])
    Some(value) -> {
      // Лимит модели известен не у всех провайдеров (kimi его не сообщает).
      let upper = case model.max_output_tokens {
        0 -> value
        limit -> limit
      }
      let clamped = clamp_int(value, 1, upper)
      case clamped == value {
        True -> #(options, [])
        False -> #(types.RequestOptions(..options, max_tokens: Some(clamped)), [
          Warning(
            "max_tokens "
            <> int_to_string(value)
            <> " превышает лимит модели, уменьшен до "
            <> int_to_string(clamped),
          ),
        ])
      }
    }
  }
}

/// Пустой system prompt равнозначен его отсутствию.
fn normalize_system_prompt(
  options: RequestOptions,
) -> #(RequestOptions, List(Warning)) {
  case options.system_prompt {
    Some(prompt) ->
      case string.trim(prompt) {
        "" -> #(types.RequestOptions(..options, system_prompt: None), [])
        _ -> #(options, [])
      }
    None -> #(options, [])
  }
}

/// Главное место расхождения провайдеров: шкалы усилий и возможность
/// выключить рассуждения различаются.
fn normalize_reasoning(
  provider: Provider,
  model: ModelInfo,
  options: RequestOptions,
) -> #(RequestOptions, List(Warning)) {
  case model.reasoning {
    NoReasoning -> {
      let had_settings =
        option.is_some(options.reasoning_enabled)
        || option.is_some(options.reasoning_effort)
      let cleared =
        types.RequestOptions(
          ..options,
          reasoning_enabled: None,
          reasoning_effort: None,
        )
      case had_settings {
        True -> #(cleared, [
          Warning(
            "модель "
            <> model.title
            <> " не поддерживает рассуждения, "
            <> "параметры reasoning отброшены",
          ),
        ])
        False -> #(cleared, [])
      }
    }

    AlwaysReasoning(..) -> {
      // Выключить нельзя — снимаем флаг, но усилие оставляем.
      let #(options, disable_warnings) = case options.reasoning_enabled {
        Some(False) -> #(
          types.RequestOptions(..options, reasoning_enabled: None),
          [
            Warning(
              provider.title
              <> " не позволяет отключить рассуждения у модели "
              <> model.title,
            ),
          ],
        )
        _ -> #(types.RequestOptions(..options, reasoning_enabled: None), [])
      }
      let #(options, effort_warnings) = normalize_effort(model, options)
      #(options, list.flatten([disable_warnings, effort_warnings]))
    }

    OptionalReasoning(..) -> normalize_effort(model, options)
  }
}

/// Значение усилия вне шкалы модели заменяется ближайшим, а не отбрасывается
/// молча: veai знает `xhigh`, kimi — нет.
fn normalize_effort(
  model: ModelInfo,
  options: RequestOptions,
) -> #(RequestOptions, List(Warning)) {
  case options.reasoning_effort {
    None -> #(options, [])
    Some(requested) -> {
      let allowed = types.reasoning_efforts(model)
      case list.contains(allowed, requested) {
        True -> #(options, [])
        False ->
          case nearest_effort(requested, allowed) {
            Some(replacement) -> #(
              types.RequestOptions(
                ..options,
                reasoning_effort: Some(replacement),
              ),
              [
                Warning(
                  "усилие '"
                  <> requested
                  <> "' не поддерживается моделью "
                  <> model.title
                  <> ", заменено на '"
                  <> replacement
                  <> "'",
                ),
              ],
            )
            None -> #(types.RequestOptions(..options, reasoning_effort: None), [
              Warning(
                "усилие '" <> requested <> "' не поддерживается, отброшено",
              ),
            ])
          }
      }
    }
  }
}

/// Шкала усилий упорядочена по возрастанию, поэтому «ближайшее» считаем
/// по позиции в общей шкале, а не по имени.
fn effort_rank(effort: String) -> Int {
  case effort {
    "none" | "off" -> 0
    "minimal" -> 1
    "low" -> 2
    "medium" -> 3
    "high" -> 4
    "xhigh" -> 5
    "max" -> 6
    _ -> 3
  }
}

/// При равном расстоянии выбираем большее усилие: лучше подумать дольше,
/// чем молча срезать качество ответа. Для kimi это даёт
/// `xhigh → max` и `medium → high`.
fn nearest_effort(requested: String, allowed: List(String)) -> Option(String) {
  let target = effort_rank(requested)
  allowed
  |> list.map(fn(candidate) {
    let rank = effort_rank(candidate)
    #(int.absolute_value(rank - target), rank, candidate)
  })
  |> list.sort(fn(a, b) {
    let #(distance_a, rank_a, _) = a
    let #(distance_b, rank_b, _) = b
    case int.compare(distance_a, distance_b) {
      order.Eq -> int.compare(rank_b, rank_a)
      other -> other
    }
  })
  |> list.first
  |> option.from_result
  |> option.map(fn(entry) { entry.2 })
}

// ─── Мелкие помощники ────────────────────────────────────────────────────────

fn clamp_float(value: Float, lower: Float, upper: Float) -> Float {
  float.clamp(value, min: lower, max: upper)
}

fn clamp_int(value: Int, lower: Int, upper: Int) -> Int {
  int.clamp(value, min: lower, max: upper)
}

fn float_to_string(value: Float) -> String {
  float.to_string(value)
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}
