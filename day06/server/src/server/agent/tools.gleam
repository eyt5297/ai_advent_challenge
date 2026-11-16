//// Реестр инструментов агента.
////
//// Инструменты вкомпилированы, а не лежат в БД: у каждого есть
//// реализация, и хранить рядом декларацию в базе означало бы риск
//// расхождения между описанием и поведением.
////
//// Агент получает доступ к инструменту только явно (`agents.tools`).
//// По умолчанию список пуст.

import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/http
import gleam/http/request as http_request
import gleam/httpc
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import server/config.{type Sandbox}
import server/ids
import server/repo/memory
import server/repo/tasks
import simplifile
import sqlight.{type Connection}

/// Как запустить другого агента: имя, подзадача, цепочка вызовов,
/// остаток бюджета шагов.
///
/// Функция, а не прямой вызов `loop`: иначе `tools` и `loop` ссылались бы
/// друг на друга, а Gleam циклических зависимостей между модулями не
/// допускает.
pub type Delegate =
  fn(String, String, List(String), Int) -> Result(String, String)

/// Что инструмент может получить от окружения.
///
/// Чистые инструменты поля игнорируют; остальным нужны то данные, то
/// сеть, то ограничения песочницы.
pub type ToolContext {
  ToolContext(
    db: Connection,
    session_id: String,
    task_id: String,
    sandbox: Sandbox,
    run_agent: Delegate,
    /// Цепочка агентов от корня — для защиты `call_agent` от рекурсии.
    /// Первый элемент: агент, которому выдано исходное задание.
    chain: List(String),
    /// Сколько шагов ещё можно потратить на всё дерево вызовов.
    budget: Int,
  )
}

pub type ToolError {
  /// Аргументы не разбираются или не того вида.
  BadArguments(String)
  /// Инструмент не смог выполниться.
  Failed(String)
}

pub type Tool {
  Tool(
    id: String,
    /// Описание для модели — от него зависит, догадается ли она вызвать.
    description: String,
    /// JSON Schema параметров, уходит в тело запроса.
    parameters: Json,
    run: fn(ToolContext, String) -> Result(Json, ToolError),
  )
}

/// Все известные инструменты.
///
/// Порядок фиксирован: он виден в UI и в теле запроса, и стабильность
/// упрощает сравнение запросов между собой.
pub fn registry() -> List(Tool) {
  [
    now_tool(),
    calc_tool(),
    dice_tool(),
    find_task_tool(),
    remember_tool(),
    forget_tool(),
    read_file_tool(),
    http_request_tool(),
    call_agent_tool(),
  ]
}

pub fn find(id: String) -> Result(Tool, Nil) {
  list.find(registry(), fn(tool) { tool.id == id })
}

/// Проверяет, что все идентификаторы известны.
///
/// Возвращает неизвестные: сообщить сразу обо всех полезнее, чем
/// заставлять исправлять их по одному.
pub fn unknown_ids(ids: List(String)) -> List(String) {
  list.filter(ids, fn(id) { find(id) |> result.is_error })
}

/// Инструменты агента в порядке реестра, без неизвестных.
pub fn selected(ids: List(String)) -> List(Tool) {
  list.filter(registry(), fn(tool) { list.contains(ids, tool.id) })
}

// ─── Объявление для провайдера ───────────────────────────────────────────────

/// Описание инструмента в формате OpenAI.
pub fn to_json(tool: Tool) -> Json {
  json.object([
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(tool.id)),
        #("description", json.string(tool.description)),
        #("parameters", tool.parameters),
      ]),
    ),
  ])
}

/// JSON Schema объекта с параметрами.
fn schema(properties: List(#(String, Json)), required: List(String)) -> Json {
  json.object([
    #("type", json.string("object")),
    #("properties", json.object(properties)),
    #("required", json.array(required, json.string)),
  ])
}

fn param(kind: String, description: String) -> Json {
  json.object([
    #("type", json.string(kind)),
    #("description", json.string(description)),
  ])
}

// ─── Выполнение ──────────────────────────────────────────────────────────────

/// Выполняет вызов по имени.
///
/// Ошибка инструмента — это результат вызова, а не сбой: она вернётся
/// модели, чтобы та могла исправиться. Поэтому наружу всегда отдаётся
/// JSON, а признак неудачи лежит внутри него.
pub fn run(
  context: ToolContext,
  available: List(String),
  name: String,
  arguments: String,
) -> #(Json, Bool) {
  case find(name) {
    Error(Nil) -> #(
      error_json("инструмент " <> name <> " не существует"),
      False,
    )

    Ok(tool) ->
      case list.contains(available, tool.id) {
        // Модель запросила инструмент, которого агенту не давали.
        // Объясняем ей это, а не падаем.
        False -> #(
          error_json("инструмент " <> name <> " недоступен этому агенту"),
          False,
        )

        True ->
          case tool.run(context, arguments) {
            Ok(value) -> #(value, True)
            Error(BadArguments(detail)) -> #(
              error_json("неверные аргументы: " <> detail),
              False,
            )
            Error(Failed(detail)) -> #(error_json(detail), False)
          }
      }
  }
}

fn error_json(message: String) -> Json {
  json.object([
    #("error", json.string(message)),
    #("ok", json.bool(False)),
  ])
}

fn decode_args(arguments: String, decoder: Decoder(a)) -> Result(a, ToolError) {
  // Пустая строка — частый случай для инструментов без параметров.
  let text = case string.trim(arguments) {
    "" -> "{}"
    other -> other
  }

  json.parse(text, decoder)
  |> result.replace_error(BadArguments(preview(text)))
}

fn preview(text: String) -> String {
  case string.length(text) > 120 {
    True -> string.slice(text, at_index: 0, length: 120) <> "…"
    False -> text
  }
}

// ─── now ─────────────────────────────────────────────────────────────────────

/// Текущее время. Модель его не знает — её веса заморожены на момент
/// обучения, и без инструмента она либо выдумает дату, либо откажется.
fn now_tool() -> Tool {
  Tool(
    id: "now",
    description: "Текущие дата и время по UTC. Вызывай, когда нужно знать, "
      <> "который час или какое сегодня число.",
    parameters: schema([], []),
    run: fn(_context, _arguments) {
      let ms = ids.now_ms()
      Ok(
        json.object([
          #("unix_ms", json.int(ms)),
          #("iso", json.string(format_iso(ms))),
        ]),
      )
    },
  )
}

@external(erlang, "server_time_ffi", "format_iso")
fn format_iso(unix_ms: Int) -> String

// ─── calc ────────────────────────────────────────────────────────────────────

/// Арифметика. Языковые модели считают ненадёжно, особенно многозначные
/// числа, поэтому вычисление лучше делегировать.
fn calc_tool() -> Tool {
  Tool(
    id: "calc",
    description: "Вычисляет арифметическое выражение: + - * / и скобки. "
      <> "Пример: (2 + 3) * 4.1",
    parameters: schema(
      [#("expression", param("string", "Выражение, например (2+3)*4"))],
      ["expression"],
    ),
    run: fn(_context, arguments) {
      use expression <- result.try(
        decode_args(arguments, {
          use expression <- decode.field("expression", decode.string)
          decode.success(expression)
        }),
      )

      case evaluate(expression) {
        Ok(value) ->
          Ok(
            json.object([
              #("expression", json.string(expression)),
              #("result", json.float(value)),
            ]),
          )
        Error(reason) -> Error(Failed(reason))
      }
    },
  )
}

// ─── roll_dice ───────────────────────────────────────────────────────────────

/// Бросок кубика.
///
/// Проверочный инструмент: честный случайный результат модель выдумать
/// не может, поэтому по ответу сразу видно, был ли вызов настоящим.
fn dice_tool() -> Tool {
  Tool(
    id: "roll_dice",
    description: "Бросает кубики. Параметры: count — сколько кубиков (1–100), "
      <> "sides — сколько граней (2–1000).",
    parameters: schema(
      [
        #("count", param("integer", "Количество кубиков, 1–100")),
        #("sides", param("integer", "Количество граней, 2–1000")),
      ],
      ["sides"],
    ),
    run: fn(_context, arguments) {
      use #(count, sides) <- result.try(
        decode_args(arguments, {
          use count <- decode.optional_field("count", 1, decode.int)
          use sides <- decode.field("sides", decode.int)
          decode.success(#(count, sides))
        }),
      )

      use Nil <- result.try(case count >= 1 && count <= 100 {
        True -> Ok(Nil)
        False -> Error(Failed("count должен быть от 1 до 100"))
      })
      use Nil <- result.try(case sides >= 2 && sides <= 1000 {
        True -> Ok(Nil)
        False -> Error(Failed("sides должен быть от 2 до 1000"))
      })

      let rolls = list.repeat(Nil, count) |> list.map(fn(_) { roll(sides) })

      Ok(
        json.object([
          #("rolls", json.array(rolls, json.int)),
          #("total", json.int(int.sum(rolls))),
        ]),
      )
    },
  )
}

/// `rand:uniform(N)` возвращает 1..N включительно — сдвигать не нужно.
fn roll(sides: Int) -> Int {
  random_int(sides)
}

@external(erlang, "rand", "uniform")
fn random_int(max: Int) -> Int

// ─── remember / forget ───────────────────────────────────────────────────────

/// Запоминание факта на весь запуск.
///
/// Факты не вытесняются из контекста никогда — в этом их смысл. Поэтому
/// описание прямо просит складывать сюда немногое: иначе агент набьёт
/// список пересказом каждого шага и съест бюджет, который берёг.
fn remember_tool() -> Tool {
  Tool(
    id: "remember",
    description: "Запоминает короткий факт на всё время работы в этой "
      <> "сессии. Факт не забудется, даже когда переписка станет длинной. "
      <> "Используй для важного и немногословного: имена, предпочтения, "
      <> "принятые решения. Не пересказывай сюда ход работы.",
    parameters: schema(
      [#("fact", param("string", "Что запомнить, одним предложением"))],
      ["fact"],
    ),
    run: fn(context, arguments) {
      use fact <- result.try(
        decode_args(arguments, {
          use fact <- decode.field("fact", decode.string)
          decode.success(fact)
        }),
      )

      case string.trim(fact) {
        "" -> Error(BadArguments("пустой факт"))
        trimmed ->
          case memory.remember(context.db, context.session_id, trimmed) {
            Error(_) -> Error(Failed("не удалось запомнить"))
            Ok(stored) ->
              Ok(
                json.object([
                  #("remembered", json.string(stored.text)),
                  #("total", json.int(fact_count(context))),
                ]),
              )
          }
      }
    },
  )
}

fn forget_tool() -> Tool {
  Tool(
    id: "forget",
    description: "Забывает ранее запомненные факты, содержащие указанную "
      <> "подстроку. Пригодится, когда сведения устарели.",
    parameters: schema(
      [#("query", param("string", "Подстрока в тексте факта"))],
      ["query"],
    ),
    run: fn(context, arguments) {
      use query <- result.try(
        decode_args(arguments, {
          use query <- decode.field("query", decode.string)
          decode.success(query)
        }),
      )

      case string.trim(query) {
        "" -> Error(BadArguments("пустой запрос"))
        trimmed ->
          case memory.forget(context.db, context.session_id, trimmed) {
            Error(_) -> Error(Failed("не удалось забыть"))
            // Ноль — не ошибка, но агенту полезно знать, что ничего не
            // совпало: иначе он решит, что сведения удалены.
            Ok(count) ->
              Ok(
                json.object([
                  #("forgotten", json.int(count)),
                  #("total", json.int(fact_count(context))),
                ]),
              )
          }
      }
    },
  )
}

fn fact_count(context: ToolContext) -> Int {
  case memory.list_facts(context.db, context.session_id) {
    Ok(facts) -> list.length(facts)
    Error(_) -> 0
  }
}

// ─── find_task ───────────────────────────────────────────────────────────────

/// Поиск по прошлым заданиям этой же сессии.
///
/// Агент не получает прошлый контекст автоматически — иначе он упирался бы
/// в лимит модели. Вместо этого он может найти нужное, если сочтёт нужным.
fn find_task_tool() -> Tool {
  Tool(
    id: "find_task",
    description: "Ищет среди выполненных ранее заданий этой сессии по "
      <> "подстроке. Возвращает их текст и результат. Пригодится, когда "
      <> "нужно вспомнить, о чём шла речь раньше.",
    parameters: schema([#("query", param("string", "Что искать, подстрока"))], [
      "query",
    ]),
    run: fn(context, arguments) {
      use query <- result.try(
        decode_args(arguments, {
          use query <- decode.field("query", decode.string)
          decode.success(query)
        }),
      )

      case string.trim(query) {
        "" -> Error(BadArguments("пустой запрос"))
        trimmed ->
          case tasks.search(context.db, context.session_id, trimmed, 5) {
            Error(_) -> Error(Failed("не удалось выполнить поиск"))
            Ok(found) ->
              Ok(
                json.object([
                  #("count", json.int(list.length(found))),
                  #(
                    "tasks",
                    json.array(found, fn(task) {
                      json.object([
                        #("prompt", json.string(task.prompt)),
                        #("result", json.string(option.unwrap(task.result, ""))),
                      ])
                    }),
                  ),
                ]),
              )
          }
      }
    },
  )
}

// ─── read_file ───────────────────────────────────────────────────────────────

/// Чтение файла внутри песочницы.
///
/// Без `AGENT_FILES_ROOT` инструмент именно **недоступен**, а не читает
/// откуда угодно: выключенная по умолчанию возможность безопаснее, чем
/// включённая с оговорками.
fn read_file_tool() -> Tool {
  Tool(
    id: "read_file",
    description: "Читает текстовый файл проекта по относительному пути. "
      <> "Доступ ограничен заранее заданным каталогом.",
    parameters: schema(
      [#("path", param("string", "Путь относительно корня проекта"))],
      ["path"],
    ),
    run: fn(context, arguments) {
      use path <- result.try(
        decode_args(arguments, {
          use path <- decode.field("path", decode.string)
          decode.success(path)
        }),
      )

      use root <- result.try(case context.sandbox.files_root {
        None ->
          Error(Failed("чтение файлов выключено: не задан AGENT_FILES_ROOT"))
        Some(root) -> Ok(root)
      })

      use resolved <- result.try(resolve_in_root(root, path))

      case simplifile.read(resolved) {
        Error(_) -> Error(Failed("файл не найден или не читается: " <> path))
        Ok(content) -> {
          let size = string.byte_size(content)
          case size > context.sandbox.max_file_bytes {
            True ->
              Error(Failed(
                "файл слишком велик: "
                <> int.to_string(size)
                <> " байт при пределе "
                <> int.to_string(context.sandbox.max_file_bytes),
              ))
            False ->
              Ok(
                json.object([
                  #("path", json.string(path)),
                  #("bytes", json.int(size)),
                  #("content", json.string(content)),
                ]),
              )
          }
        }
      }
    },
  )
}

/// Приводит путь к каноническому виду и проверяет принадлежность корню.
///
/// Проверка идёт **после** развёртывания `..` и символических ссылок:
/// проверять до — классическая дыра, через которую уходят из песочницы.
fn resolve_in_root(root: String, path: String) -> Result(String, ToolError) {
  use Nil <- result.try(case string.starts_with(path, "/") {
    True -> Error(Failed("путь должен быть относительным"))
    False -> Ok(Nil)
  })

  let real_root = canonical(root)
  let candidate = canonical(root <> "/" <> path)

  // Сравниваем с разделителем, иначе `/srv/data-secret` прошёл бы как
  // «начинается с /srv/data».
  case
    candidate == real_root || string.starts_with(candidate, real_root <> "/")
  {
    True -> Ok(candidate)
    False -> Error(Failed("путь выходит за пределы разрешённого каталога"))
  }
}

@external(erlang, "server_path_ffi", "canonical")
fn canonical(path: String) -> String

// ─── http_request ────────────────────────────────────────────────────────────

/// Запрос к внешнему API.
///
/// Разрешены только хосты из `AGENT_HTTP_ALLOWLIST`. Пустой список —
/// полный запрет: иначе агент дотянулся бы до внутренней сети, включая
/// собственный API сервера.
fn http_request_tool() -> Tool {
  Tool(
    id: "http_request",
    description: "Выполняет GET-запрос к разрешённому внешнему адресу и "
      <> "возвращает тело ответа.",
    parameters: schema(
      [#("url", param("string", "Полный URL, только https или http"))],
      ["url"],
    ),
    run: fn(context, arguments) {
      use url <- result.try(
        decode_args(arguments, {
          use url <- decode.field("url", decode.string)
          decode.success(url)
        }),
      )

      use request <- result.try(
        uri.parse(url)
        |> result.replace_error(BadArguments("не разбирается как URL: " <> url))
        |> result.try(fn(parsed) {
          http_request.from_uri(parsed)
          |> result.replace_error(BadArguments("неподдерживаемый адрес"))
        }),
      )

      use Nil <- result.try(check_host(context.sandbox, request.host))

      case
        httpc.configure()
        |> httpc.timeout(15_000)
        |> httpc.dispatch(http_request.set_method(request, http.Get))
      {
        Error(_) -> Error(Failed("запрос не удался: " <> url))
        Ok(response) -> {
          let body = truncate(response.body, context.sandbox.max_http_bytes)
          Ok(
            json.object([
              #("status", json.int(response.status)),
              #("body", json.string(body)),
            ]),
          )
        }
      }
    },
  )
}

/// Хост должен быть в списке и не вести во внутреннюю сеть.
fn check_host(sandbox: Sandbox, host: String) -> Result(Nil, ToolError) {
  let normalized = string.lowercase(host)

  case sandbox.http_allowlist {
    [] ->
      Error(Failed("сетевые запросы выключены: не задан AGENT_HTTP_ALLOWLIST"))
    allowed ->
      case list.contains(allowed, normalized) {
        False ->
          Error(Failed(
            "хост "
            <> host
            <> " не в списке разрешённых: "
            <> string.join(allowed, ", "),
          ))
        True ->
          case is_private(normalized) {
            // Страховка на случай, если приватный адрес попал в список
            // по недосмотру: до внутренней сети агент дотянуться не должен.
            True -> Error(Failed("адреса внутренней сети запрещены"))
            False -> Ok(Nil)
          }
      }
  }
}

fn is_private(host: String) -> Bool {
  host == "localhost"
  || host == "127.0.0.1"
  || host == "0.0.0.0"
  || host == "::1"
  || string.starts_with(host, "127.")
  || string.starts_with(host, "10.")
  || string.starts_with(host, "192.168.")
  || string.starts_with(host, "169.254.")
  || is_carrier_range(host)
}

/// 172.16.0.0/12 — диапазон, который легко пропустить: «172.» слишком
/// широко, а перечислять 172.16…172.31 по одному некрасиво.
fn is_carrier_range(host: String) -> Bool {
  case string.split(host, ".") {
    ["172", second, ..] ->
      case int.parse(second) {
        Ok(value) -> value >= 16 && value <= 31
        Error(Nil) -> False
      }
    _ -> False
  }
}

fn truncate(body: String, limit: Int) -> String {
  case string.byte_size(body) > limit {
    True -> string.slice(body, at_index: 0, length: limit) <> "…(обрезано)"
    False -> body
  }
}

// ─── call_agent ──────────────────────────────────────────────────────────────

/// Делегирование подзадачи другому агенту.
///
/// Самый опасный инструмент: агент А зовёт Б, тот снова А — и так до
/// исчерпания памяти. Защита тройная (SPEC_AGENTS.md, п. 11.4):
/// предел глубины, обнаружение цикла по цепочке и общий бюджет шагов.
/// Первые две проверки здесь, третья — в самом цикле.
fn call_agent_tool() -> Tool {
  Tool(
    id: "call_agent",
    description: "Поручает подзадачу другому агенту по его имени и "
      <> "возвращает полученный результат.",
    parameters: schema(
      [
        #("name", param("string", "Имя агента-исполнителя")),
        #("task", param("string", "Что именно поручить")),
      ],
      ["name", "task"],
    ),
    run: fn(context, arguments) {
      use #(name, task) <- result.try(
        decode_args(arguments, {
          use name <- decode.field("name", decode.string)
          use task <- decode.field("task", decode.string)
          decode.success(#(name, task))
        }),
      )

      use Nil <- result.try(case list.length(context.chain) {
        depth if depth >= 1 ->
          case depth > context.sandbox.max_depth {
            True ->
              Error(Failed(
                "превышена глубина делегирования ("
                <> int.to_string(context.sandbox.max_depth)
                <> ")",
              ))
            False -> Ok(Nil)
          }
        _ -> Ok(Nil)
      })

      use Nil <- result.try(case string.trim(task) {
        "" -> Error(BadArguments("пустая подзадача"))
        _ -> Ok(Nil)
      })

      case context.run_agent(name, task, context.chain, context.budget) {
        Error(reason) -> Error(Failed(reason))
        Ok(result) ->
          Ok(
            json.object([
              #("agent", json.string(name)),
              #("result", json.string(result)),
            ]),
          )
      }
    },
  )
}

// ─── Вычисление выражений ────────────────────────────────────────────────────

/// Разбор выражения методом рекурсивного спуска.
///
/// Своя реализация вместо вызова `eval`: выполнять присланный моделью код
/// недопустимо даже в арифметическом виде.
fn evaluate(input: String) -> Result(Float, String) {
  let tokens = tokenize(string.to_graphemes(input), [])

  case tokens {
    Error(reason) -> Error(reason)
    Ok(tokens) ->
      case parse_sum(tokens) {
        Error(reason) -> Error(reason)
        Ok(#(value, [])) -> Ok(value)
        Ok(#(_, rest)) ->
          Error("лишние символы после выражения: " <> join_tokens(rest))
      }
  }
}

type Token {
  Num(Float)
  Plus
  Minus
  Star
  Slash
  LParen
  RParen
}

fn tokenize(
  chars: List(String),
  acc: List(Token),
) -> Result(List(Token), String) {
  case chars {
    [] -> Ok(list.reverse(acc))

    [" ", ..rest] | ["\t", ..rest] -> tokenize(rest, acc)
    ["+", ..rest] -> tokenize(rest, [Plus, ..acc])
    ["-", ..rest] -> tokenize(rest, [Minus, ..acc])
    ["*", ..rest] -> tokenize(rest, [Star, ..acc])
    ["/", ..rest] -> tokenize(rest, [Slash, ..acc])
    ["(", ..rest] -> tokenize(rest, [LParen, ..acc])
    [")", ..rest] -> tokenize(rest, [RParen, ..acc])

    [char, ..] ->
      case is_digit(char) {
        False -> Error("непонятный символ: " <> char)
        True -> {
          let #(number, rest) = take_number(chars, "")
          case parse_number(number) {
            Ok(value) -> tokenize(rest, [Num(value), ..acc])
            Error(Nil) -> Error("не число: " <> number)
          }
        }
      }
  }
}

fn take_number(chars: List(String), acc: String) -> #(String, List(String)) {
  case chars {
    [char, ..rest] ->
      case is_digit(char) || char == "." {
        True -> take_number(rest, acc <> char)
        False -> #(acc, chars)
      }
    [] -> #(acc, [])
  }
}

fn is_digit(char: String) -> Bool {
  case char {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn parse_number(text: String) -> Result(Float, Nil) {
  case float.parse(text) {
    Ok(value) -> Ok(value)
    // `float.parse` не принимает целые без точки.
    Error(Nil) -> int.parse(text) |> result.map(int.to_float)
  }
}

/// Сложение и вычитание — самый низкий приоритет.
fn parse_sum(tokens: List(Token)) -> Result(#(Float, List(Token)), String) {
  use #(left, rest) <- result.try(parse_product(tokens))
  continue_sum(left, rest)
}

fn continue_sum(
  left: Float,
  tokens: List(Token),
) -> Result(#(Float, List(Token)), String) {
  case tokens {
    [Plus, ..rest] -> {
      use #(right, tail) <- result.try(parse_product(rest))
      continue_sum(left +. right, tail)
    }
    [Minus, ..rest] -> {
      use #(right, tail) <- result.try(parse_product(rest))
      continue_sum(left -. right, tail)
    }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_product(tokens: List(Token)) -> Result(#(Float, List(Token)), String) {
  use #(left, rest) <- result.try(parse_atom(tokens))
  continue_product(left, rest)
}

fn continue_product(
  left: Float,
  tokens: List(Token),
) -> Result(#(Float, List(Token)), String) {
  case tokens {
    [Star, ..rest] -> {
      use #(right, tail) <- result.try(parse_atom(rest))
      continue_product(left *. right, tail)
    }
    [Slash, ..rest] -> {
      use #(right, tail) <- result.try(parse_atom(rest))
      case right == 0.0 {
        True -> Error("деление на ноль")
        False -> continue_product(left /. right, tail)
      }
    }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_atom(tokens: List(Token)) -> Result(#(Float, List(Token)), String) {
  case tokens {
    [Num(value), ..rest] -> Ok(#(value, rest))

    // Унарный минус: -5 и -(2+3).
    [Minus, ..rest] -> {
      use #(value, tail) <- result.try(parse_atom(rest))
      Ok(#(0.0 -. value, tail))
    }

    [LParen, ..rest] -> {
      use #(value, tail) <- result.try(parse_sum(rest))
      case tail {
        [RParen, ..after] -> Ok(#(value, after))
        _ -> Error("не закрыта скобка")
      }
    }

    [] -> Error("выражение оборвалось")
    [token, ..] -> Error("неожиданный символ: " <> token_text(token))
  }
}

fn join_tokens(tokens: List(Token)) -> String {
  tokens |> list.map(token_text) |> string.join(" ")
}

fn token_text(token: Token) -> String {
  case token {
    Num(value) -> float.to_string(value)
    Plus -> "+"
    Minus -> "-"
    Star -> "*"
    Slash -> "/"
    LParen -> "("
    RParen -> ")"
  }
}
