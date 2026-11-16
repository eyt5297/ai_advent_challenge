//// Тесты реестра инструментов.
////
//// Три чистых инструмента проверяются целиком: у них нет внешних
//// зависимостей, поэтому любая неудача указывает на наш код.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import server/agent/tools
import server/config
import server/db
import server/repo/agents
import server/repo/sessions
import server/repo/tasks
import shared/types
import simplifile
import sqlight

fn with_context(run: fn(tools.ToolContext) -> a) -> a {
  use context <- with_sandbox(closed_sandbox())
  run(context)
}

/// Песочница, в которой всё выключено, — состояние по умолчанию.
fn closed_sandbox() -> config.Sandbox {
  config.Sandbox(
    files_root: None,
    max_file_bytes: 64_000,
    http_allowlist: [],
    max_http_bytes: 64_000,
    max_depth: 3,
  )
}

fn with_sandbox(sandbox: config.Sandbox, run: fn(tools.ToolContext) -> a) -> a {
  let assert Ok(connection) = db.connect_memory()
  let result =
    run(tools.ToolContext(
      db: connection,
      session_id: "ses",
      task_id: "tsk",
      sandbox:,
      chain: [],
      budget: 10,
      // Вложенные запуски проверяются e2e-тестом против живого цикла;
      // здесь достаточно заглушки.
      run_agent: fn(name, _task, _chain, _budget) {
        case name {
          "Сломанный" -> Error("агент не справился")
          _ -> Ok("итог от " <> name)
        }
      },
    ))
  let assert Ok(Nil) = sqlight.close(connection)
  result
}

const all = [
  "now", "calc", "roll_dice", "find_task", "remember", "forget", "read_file",
  "http_request", "call_agent",
]

/// Выполняет вызов и возвращает тело ответа строкой.
fn call(
  context: tools.ToolContext,
  name: String,
  args: String,
) -> #(String, Bool) {
  let #(payload, ok) = tools.run(context, all, name, args)
  #(json.to_string(payload), ok)
}

// ─── Реестр ──────────────────────────────────────────────────────────────────

pub fn registry_lists_known_tools_test() {
  let ids = list.map(tools.registry(), fn(tool) { tool.id })
  assert ids
    == [
      "now", "calc", "roll_dice", "find_task", "remember", "forget", "read_file",
      "http_request", "call_agent",
    ]
}

pub fn unknown_ids_reports_all_test() {
  // Сообщить обо всех сразу полезнее, чем заставлять исправлять по одному.
  assert tools.unknown_ids(["now", "нет", "тоже нет"]) == ["нет", "тоже нет"]
  assert tools.unknown_ids(["now", "calc"]) == []
}

pub fn selected_keeps_registry_order_test() {
  let ids = tools.selected(["roll_dice", "now"]) |> list.map(fn(t) { t.id })
  // Порядок реестра, а не порядок запроса: он виден в теле запроса,
  // и стабильность упрощает сравнение.
  assert ids == ["now", "roll_dice"]
}

/// Объявление должно быть в формате, который понимает провайдер.
pub fn tool_declaration_shape_test() {
  let assert Ok(tool) = tools.find("calc")
  let declaration = json.to_string(tools.to_json(tool))

  assert string.contains(declaration, "\"type\":\"function\"")
  assert string.contains(declaration, "\"name\":\"calc\"")
  assert string.contains(declaration, "\"expression\"")
  assert string.contains(declaration, "\"required\"")
}

// ─── now ─────────────────────────────────────────────────────────────────────

pub fn now_returns_time_test() {
  use context <- with_context
  let #(body, ok) = call(context, "now", "{}")

  assert ok
  assert string.contains(body, "unix_ms")
  // ISO-формат: модели проще прочитать дату, чем миллисекунды.
  assert string.contains(body, "T")
  assert string.contains(body, "Z")
}

/// Инструмент без параметров должен принимать пустые аргументы:
/// модели присылают и `{}`, и пустую строку.
pub fn now_accepts_empty_arguments_test() {
  use context <- with_context
  let #(_, ok) = call(context, "now", "")
  assert ok
}

// ─── calc ────────────────────────────────────────────────────────────────────

fn calc(context: tools.ToolContext, expression: String) -> #(String, Bool) {
  call(
    context,
    "calc",
    json.to_string(json.object([#("expression", json.string(expression))])),
  )
}

pub fn calc_respects_precedence_test() {
  use context <- with_context

  let #(body, ok) = calc(context, "2 + 3 * 4")
  assert ok
  assert string.contains(body, "14")
}

pub fn calc_handles_parentheses_test() {
  use context <- with_context
  let #(body, ok) = calc(context, "(2 + 3) * 4.1")
  assert ok
  assert string.contains(body, "20.5")
}

/// Деление должно быть дробным: целочисленное дало бы 2 вместо 2.5.
pub fn calc_divides_as_float_test() {
  use context <- with_context
  let #(body, ok) = calc(context, "10 / 4")
  assert ok
  assert string.contains(body, "2.5")
}

pub fn calc_supports_unary_minus_test() {
  use context <- with_context

  let #(body, ok) = calc(context, "-3 + 2 * (1 + 1)")
  assert ok
  assert string.contains(body, "1.0")
}

/// Деление на ноль — ошибка инструмента, а не падение процесса.
pub fn calc_rejects_division_by_zero_test() {
  use context <- with_context
  let #(body, ok) = calc(context, "1 / 0")

  assert !ok
  assert string.contains(body, "деление на ноль")
}

pub fn calc_rejects_broken_expression_test() {
  use context <- with_context

  let #(_, ok_tail) = calc(context, "2 +")
  assert !ok_tail

  let #(_, ok_paren) = calc(context, "(2 + 3")
  assert !ok_paren
}

/// Вычислитель свой, а не `eval`: выполнять присланный моделью код
/// недопустимо даже под видом арифметики.
pub fn calc_rejects_arbitrary_code_test() {
  use context <- with_context

  let #(body, ok) = calc(context, "os:cmd(\"rm -rf /\")")
  assert !ok
  assert string.contains(body, "непонятный символ")
}

pub fn calc_requires_expression_test() {
  use context <- with_context
  let #(body, ok) = call(context, "calc", "{}")

  assert !ok
  assert string.contains(body, "аргументы")
}

// ─── roll_dice ───────────────────────────────────────────────────────────────

pub fn dice_rolls_within_range_test() {
  use context <- with_context

  // Шесть граней — значит 1..6. Классический промах на единицу дал бы 0 или 7.
  list.each(list.repeat(Nil, 50), fn(_) {
    let #(body, ok) = call(context, "roll_dice", "{\"count\":1,\"sides\":6}")
    assert ok
    let assert Ok(value) = parse_total(body)
    assert value >= 1 && value <= 6
  })
}

pub fn dice_rolls_multiple_test() {
  use context <- with_context
  let #(body, ok) = call(context, "roll_dice", "{\"count\":3,\"sides\":6}")

  assert ok
  let assert Ok(total) = parse_total(body)
  assert total >= 3 && total <= 18
}

/// count необязателен: без него бросается один кубик.
pub fn dice_defaults_to_single_test() {
  use context <- with_context
  let #(body, ok) = call(context, "roll_dice", "{\"sides\":20}")

  assert ok
  let assert Ok(total) = parse_total(body)
  assert total >= 1 && total <= 20
}

pub fn dice_rejects_absurd_input_test() {
  use context <- with_context

  let #(_, many) = call(context, "roll_dice", "{\"count\":5000,\"sides\":6}")
  assert !many

  let #(_, sides) = call(context, "roll_dice", "{\"count\":1,\"sides\":1}")
  assert !sides
}

fn parse_total(body: String) -> Result(Int, Nil) {
  json.parse(body, {
    use total <- decode.field("total", decode.int)
    decode.success(total)
  })
  |> result.replace_error(Nil)
}

// ─── find_task ───────────────────────────────────────────────────────────────

/// Память агента: он может найти прошлое задание, но не получает его
/// автоматически — иначе упёрся бы в лимит контекста.
pub fn find_task_searches_history_test() {
  use context <- with_context

  let assert Ok(agent) =
    agents.create(context.db, agents.new("А", "veai", "Anthropic/sonnet-5"))
  let assert Ok(session) =
    sessions.create_for_agent(context.db, Some(agent.id), None, None, None)

  let assert Ok(first) =
    tasks.create(context.db, session.id, "посчитай налоги за март")
  let assert Ok(_) =
    tasks.finish(
      context.db,
      first.id,
      types.TaskDone,
      Some("вышло 12000"),
      None,
      1,
    )

  let searching = tools.ToolContext(..context, session_id: session.id)
  let #(payload, ok) =
    tools.run(searching, all, "find_task", "{\"query\":\"налоги\"}")
  let body = json.to_string(payload)

  assert ok
  assert string.contains(body, "посчитай налоги")
  assert string.contains(body, "вышло 12000")
}

/// Незавершённые и чужие задания в выдачу не попадают.
pub fn find_task_ignores_unfinished_and_foreign_test() {
  use context <- with_context

  let assert Ok(agent) =
    agents.create(context.db, agents.new("А", "veai", "Anthropic/sonnet-5"))
  let assert Ok(mine) =
    sessions.create_for_agent(context.db, Some(agent.id), None, None, None)
  let assert Ok(other) =
    sessions.create_for_agent(context.db, Some(agent.id), None, None, None)

  // Выполняется прямо сейчас — итога ещё нет.
  let assert Ok(_) = tasks.create(context.db, mine.id, "идёт прямо сейчас")

  // Чужая сессия: агент не должен видеть её историю.
  let assert Ok(foreign) = tasks.create(context.db, other.id, "чужое задание")
  let assert Ok(_) =
    tasks.finish(
      context.db,
      foreign.id,
      types.TaskDone,
      Some("чужой итог"),
      None,
      1,
    )

  let searching = tools.ToolContext(..context, session_id: mine.id)
  let #(payload, _) =
    tools.run(searching, all, "find_task", "{\"query\":\"задание\"}")
  let body = json.to_string(payload)

  assert string.contains(body, "\"count\":0")
  assert !string.contains(body, "чужой итог")
}

// ─── read_file ───────────────────────────────────────────────────────────────

/// Без AGENT_FILES_ROOT инструмент именно недоступен, а не читает
/// откуда угодно.
pub fn read_file_disabled_by_default_test() {
  use context <- with_context
  let #(payload, ok) =
    tools.run(context, all, "read_file", "{\"path\":\"README.md\"}")

  assert !ok
  assert string.contains(json.to_string(payload), "AGENT_FILES_ROOT")
}

fn sandboxed(root: String, run: fn(tools.ToolContext) -> a) -> a {
  with_sandbox(config.Sandbox(..closed_sandbox(), files_root: Some(root)), run)
}

pub fn read_file_reads_inside_root_test() {
  let root = "/tmp/opencode/sandbox_test"
  let assert Ok(_) = simplifile.create_directory_all(root <> "/nested")
  let assert Ok(_) = simplifile.write(root <> "/nested/note.txt", "содержимое")

  use context <- sandboxed(root)
  let #(payload, ok) =
    tools.run(context, all, "read_file", "{\"path\":\"nested/note.txt\"}")

  assert ok
  assert string.contains(json.to_string(payload), "содержимое")
}

/// Выход из песочницы через `..` — первое, что попробует злоумышленник.
pub fn read_file_rejects_traversal_test() {
  let root = "/tmp/opencode/sandbox_test"
  let assert Ok(_) = simplifile.create_directory_all(root)

  use context <- sandboxed(root)
  let #(payload, ok) =
    tools.run(context, all, "read_file", "{\"path\":\"../../etc/passwd\"}")

  assert !ok
  assert string.contains(json.to_string(payload), "за пределы")
}

pub fn read_file_rejects_absolute_path_test() {
  let root = "/tmp/opencode/sandbox_test"
  let assert Ok(_) = simplifile.create_directory_all(root)

  use context <- sandboxed(root)
  let #(_, ok) =
    tools.run(context, all, "read_file", "{\"path\":\"/etc/passwd\"}")

  assert !ok
}

/// Символическая ссылка наружу — вторая попытка обхода. Проверка идёт
/// после разрешения ссылок, поэтому не срабатывает.
pub fn read_file_rejects_symlink_escape_test() {
  let root = "/tmp/opencode/sandbox_link"
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) = simplifile.write("/tmp/opencode/outside.txt", "секрет")
  let _ = simplifile.delete(root <> "/escape.txt")
  let assert Ok(_) =
    simplifile.create_symlink(
      "/tmp/opencode/outside.txt",
      root <> "/escape.txt",
    )

  use context <- sandboxed(root)
  let #(payload, ok) =
    tools.run(context, all, "read_file", "{\"path\":\"escape.txt\"}")

  assert !ok
  assert !string.contains(json.to_string(payload), "секрет")
}

/// Сосед с похожим именем не должен считаться «внутри»: сравнение идёт
/// с разделителем, а не по префиксу строки.
pub fn read_file_rejects_sibling_prefix_test() {
  let assert Ok(_) = simplifile.create_directory_all("/tmp/opencode/box")
  let assert Ok(_) = simplifile.create_directory_all("/tmp/opencode/box-secret")
  let assert Ok(_) =
    simplifile.write("/tmp/opencode/box-secret/key.txt", "ключ")

  use context <- sandboxed("/tmp/opencode/box")
  let #(payload, ok) =
    tools.run(context, all, "read_file", "{\"path\":\"../box-secret/key.txt\"}")

  assert !ok
  assert !string.contains(json.to_string(payload), "ключ")
}

/// `..` в середине пути — обход, который легко пропустить, если
/// нормализовать только начало строки.
pub fn read_file_rejects_midpath_traversal_test() {
  let root = "/tmp/opencode/sandbox_mid"
  let assert Ok(_) = simplifile.create_directory_all(root <> "/sub")
  let assert Ok(_) = simplifile.write("/tmp/opencode/secret_mid.txt", "тайна")

  use context <- sandboxed(root)
  let #(payload, ok) =
    tools.run(
      context,
      all,
      "read_file",
      "{\"path\":\"sub/../../secret_mid.txt\"}",
    )

  assert !ok
  assert !string.contains(json.to_string(payload), "тайна")
}

/// Большой файл съел бы весь контекст модели.
pub fn read_file_rejects_oversized_test() {
  let root = "/tmp/opencode/sandbox_big"
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(root <> "/big.txt", string.repeat("x", 5000))

  use context <- with_sandbox(
    config.Sandbox(
      ..closed_sandbox(),
      files_root: Some(root),
      max_file_bytes: 100,
    ),
  )
  let #(payload, ok) =
    tools.run(context, all, "read_file", "{\"path\":\"big.txt\"}")

  assert !ok
  assert string.contains(json.to_string(payload), "слишком велик")
}

// ─── http_request ────────────────────────────────────────────────────────────

pub fn http_disabled_by_default_test() {
  use context <- with_context
  let #(payload, ok) =
    tools.run(context, all, "http_request", "{\"url\":\"https://example.com\"}")

  assert !ok
  assert string.contains(json.to_string(payload), "AGENT_HTTP_ALLOWLIST")
}

pub fn http_rejects_host_outside_allowlist_test() {
  use context <- with_sandbox(
    config.Sandbox(..closed_sandbox(), http_allowlist: ["example.com"]),
  )
  let #(payload, ok) =
    tools.run(context, all, "http_request", "{\"url\":\"https://evil.test/x\"}")

  assert !ok
  assert string.contains(json.to_string(payload), "не в списке")
}

/// Внутренняя сеть под запретом даже при попадании в список: иначе агент
/// дотянулся бы до собственного API сервера.
pub fn http_rejects_private_network_test() {
  let hosts = [
    "localhost",
    "127.0.0.1",
    "10.0.0.5",
    "192.168.1.1",
    "172.16.0.9",
    "169.254.169.254",
  ]

  list.each(hosts, fn(host) {
    use context <- with_sandbox(
      config.Sandbox(..closed_sandbox(), http_allowlist: [host]),
    )
    let #(payload, ok) =
      tools.run(
        context,
        all,
        "http_request",
        "{\"url\":\"http://" <> host <> "/\"}",
      )

    assert !ok
    assert string.contains(json.to_string(payload), "внутренней сети")
  })
}

/// 172.32 уже публичный — проверка не должна быть слишком широкой.
pub fn http_allows_public_172_test() {
  use context <- with_sandbox(
    config.Sandbox(..closed_sandbox(), http_allowlist: ["172.32.0.1"]),
  )
  let #(payload, ok) =
    tools.run(context, all, "http_request", "{\"url\":\"http://172.32.0.1/\"}")

  // Запрос не пройдёт (адрес недостижим), но причина должна быть сетевой,
  // а не запретом песочницы.
  assert !ok
  assert !string.contains(json.to_string(payload), "внутренней сети")
}

pub fn http_rejects_broken_url_test() {
  use context <- with_sandbox(
    config.Sandbox(..closed_sandbox(), http_allowlist: ["example.com"]),
  )
  let #(_, ok) = tools.run(context, all, "http_request", "{\"url\":\"не url\"}")
  assert !ok
}

// ─── call_agent ──────────────────────────────────────────────────────────────

pub fn call_agent_delegates_test() {
  use context <- with_context
  let #(payload, ok) =
    tools.run(
      context,
      all,
      "call_agent",
      "{\"name\":\"Переводчик\",\"task\":\"переведи\"}",
    )

  assert ok
  assert string.contains(json.to_string(payload), "итог от Переводчик")
}

/// Неудача вложенного агента — ошибка инструмента, а не падение.
pub fn call_agent_reports_failure_test() {
  use context <- with_context
  let #(payload, ok) =
    tools.run(
      context,
      all,
      "call_agent",
      "{\"name\":\"Сломанный\",\"task\":\"сделай\"}",
    )

  assert !ok
  assert string.contains(json.to_string(payload), "не справился")
}

/// Глубина вложенности ограничена: иначе агенты зовут друг друга до
/// исчерпания памяти.
pub fn call_agent_respects_depth_limit_test() {
  use context <- with_sandbox(config.Sandbox(..closed_sandbox(), max_depth: 2))

  let deep = tools.ToolContext(..context, chain: ["a", "b", "c"])
  let #(payload, ok) =
    tools.run(deep, all, "call_agent", "{\"name\":\"Б\",\"task\":\"x\"}")

  assert !ok
  assert string.contains(json.to_string(payload), "глубина")
}

pub fn call_agent_requires_task_test() {
  use context <- with_context
  let #(_, ok) =
    tools.run(context, all, "call_agent", "{\"name\":\"А\",\"task\":\"  \"}")
  assert !ok
}

// ─── Диспетчер ───────────────────────────────────────────────────────────────

/// Неизвестный инструмент — ответ модели, а не сбой: пусть исправится.
pub fn unknown_tool_is_reported_test() {
  use context <- with_context
  let #(body, ok) = call(context, "телепортация", "{}")

  assert !ok
  assert string.contains(body, "не существует")
}

/// Инструмент, не выданный агенту, вызвать нельзя — даже если он есть
/// в реестре. Разрешения на уровне агента, а не глобально.
pub fn forbidden_tool_is_rejected_test() {
  use context <- with_context
  let #(payload, ok) = tools.run(context, ["now"], "calc", "{}")

  assert !ok
  assert string.contains(json.to_string(payload), "недоступен")
}

/// Невалидный JSON в аргументах — частый случай у моделей.
pub fn broken_arguments_are_reported_test() {
  use context <- with_context
  let #(body, ok) = call(context, "calc", "{не json")

  assert !ok
  assert string.contains(body, "аргументы")
}
