//// Цикл агента: задание → N обменов с LLM → итог.
////
//// Надстройка над `llm/chat`, а не замена: каждый шаг — обычный обмен,
//// который сохраняется со всеми сырыми телами. Благодаря этому наблюдение
//// за работой агента ничего не требует от транспорта.
////
//// Модуль не импортирует `wisp` и `mist`: его должен уметь вызвать любой
//// канал, не только HTTP (см. SPEC_AGENTS.md, п. 10.1).

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/agent/memory
import server/agent/summarize
import server/agent/tools
import server/config.{type Config}
import server/events
import server/llm/chat
import server/repo/agents
import server/repo/messages
import server/repo/sessions
import server/repo/tasks
import shared/types.{
  type Agent, type Message, type RequestOptions, type Session, type Task,
}
import sqlight.{type Connection}

pub type TaskError {
  /// Сессия не принадлежит агенту: выдавать ей задания некому.
  NoAgent
  /// В сессии уже выполняется задание.
  Busy(task_id: String)
  /// Задание пустое.
  EmptyPrompt
  Storage(String)
}

// ─── Слияние настроек ────────────────────────────────────────────────────────

/// Настройки агента, поверх них — переопределения сессии.
///
/// Вся «агентность» слоя запроса собрана здесь: ниже по течению
/// `build_request_body` получает готовые опции и про агентов не знает.
///
/// `system_prompt` берётся у агента всегда. Переопределять его на уровне
/// запуска значит запускать другого агента — для этого есть создание
/// нового агента, а не правка параметров сессии.
pub fn merge_options(agent: Agent, session: Session) -> RequestOptions {
  let base = agent.params
  let over = session.params

  types.RequestOptions(
    temperature: option.or(over.temperature, base.temperature),
    max_tokens: option.or(over.max_tokens, base.max_tokens),
    system_prompt: non_empty(agent.system_prompt),
    reasoning_enabled: option.or(over.reasoning_enabled, base.reasoning_enabled),
    reasoning_effort: option.or(over.reasoning_effort, base.reasoning_effort),
    stream: base.stream,
  )
}

fn non_empty(text: String) -> Option(String) {
  case string.trim(text) {
    "" -> None
    trimmed -> Some(trimmed)
  }
}

/// Провайдер и модель: сессия переопределяет агента.
pub fn merge_model(agent: Agent, session: Session) -> #(String, String) {
  #(
    option.unwrap(session.provider_id, agent.provider_id),
    option.unwrap(session.model_id, agent.model_id),
  )
}

// ─── Запуск задания ──────────────────────────────────────────────────────────

/// Создаёт задание в статусе `running`, ничего не выполняя.
///
/// Отделено от `run`, чтобы асинхронный режим мог вернуть `202` сразу:
/// задание уже видно снаружи, пока цикл только начинается.
pub fn start(
  connection: Connection,
  session: Session,
  prompt: String,
) -> Result(Task, TaskError) {
  use <- require_agent(session)
  use trimmed <- require_prompt(prompt)

  tasks.create(connection, session.id, trimmed)
  |> result.map(announce)
  |> result.map_error(fn(error) {
    case error {
      tasks.AlreadyRunning(id) -> Busy(id)
      other -> Storage(string.inspect(other))
    }
  })
}

/// Выполняет созданное задание до конца.
///
/// Любая неудача становится состоянием задания, а не ошибкой вызова:
/// задание со `status = failed` вместе со всеми шагами полезнее, чем
/// пустой результат с сообщением об ошибке.
pub fn run(
  connection: Connection,
  config: Config,
  agent: Agent,
  session: Session,
  task: Task,
) -> Task {
  run_nested(connection, config, agent, session, task, [], agent.max_steps)
}

/// Запуск внутри другого задания — для инструмента `call_agent`.
///
/// `chain` — цепочка агентов от корня, `budget` — остаток шагов на всё
/// дерево. Бюджет общий намеренно: три агента по пять шагов иначе дали бы
/// сто двадцать пять обращений к модели.
pub fn run_nested(
  connection: Connection,
  config: Config,
  agent: Agent,
  session: Session,
  task: Task,
  chain: List(String),
  budget: Int,
) -> Task {
  iterate(connection, config, agent, session, task, [], 1, chain, budget)
}

/// Создать и сразу выполнить — синхронный режим `POST /tasks`.
pub fn start_and_run(
  connection: Connection,
  config: Config,
  agent: Agent,
  session: Session,
  prompt: String,
) -> Result(Task, TaskError) {
  use task <- result.try(start(connection, session, prompt))
  Ok(run(connection, config, agent, session, task))
}

fn iterate(
  connection: Connection,
  config: Config,
  agent: Agent,
  session: Session,
  task: Task,
  history: List(Message),
  step: Int,
  chain: List(String),
  budget: Int,
) -> Task {
  // Исчерпание лимита — результат работы агента, а не сбой сервера:
  // сохраняем вместе со всеми шагами, чтобы было видно, на чём он
  // зациклился.
  // Предел считается по общему бюджету дерева, а не по шагам одного
  // агента: вложенные запуски тратят тот же запас.
  case step > budget {
    True ->
      fail(
        connection,
        task,
        "исчерпан лимит шагов (" <> int.to_string(budget) <> ")",
        step - 1,
      )

    False -> {
      let #(provider_id, model_id) = merge_model(agent, session)

      let available = tools.selected(agent.tools)

      // Память собирается один раз, на первом шаге: дальше история
      // задания растёт сама, и перечитывать прошлое незачем.
      let recalled = case step {
        1 ->
          recall(
            connection,
            config,
            agent,
            session,
            task,
            provider_id,
            model_id,
          )
        _ -> []
      }

      let prepared =
        chat.prepare(
          config,
          provider_id,
          model_id,
          // Задание отправляется один раз, на первом шаге. Дальше запрос
          // продолжает историю: повтори мы его, модель сочла бы это новой
          // просьбой и пошла бы на второй круг с тем же инструментом.
          case step {
            1 -> Some(task.prompt)
            _ -> None
          },
          merge_options(agent, session),
          None,
          list.append(recalled, history),
          list.map(available, tools.to_json),
        )

      case prepared {
        // Сборка запроса не удалась: модель исчезла из каталога, нет ключа.
        // Шагов при этом нет вовсе, записывать нечего.
        Error(error) -> fail(connection, task, chat.describe(error), step - 1)

        Ok(prepared) ->
          case
            chat.send(
              connection,
              config,
              session,
              prepared,
              case step {
                1 -> Some(task.prompt)
                _ -> None
              },
              chat.Step(task_id: task.id, step:),
            )
          {
            Error(error) ->
              fail(connection, task, chat.describe(error), step - 1)

            Ok(exchange) -> {
              // Отмечаем прогресс сразу: ход работы должен быть виден
              // снаружи, а не только изнутри процесса.
              let _ = tasks.set_steps(connection, task.id, step)

              case exchange.assistant.status {
                types.Failed -> {
                  // Неудачный шаг тоже записан и тоже интересен: в нём
                  // видно, что ответил провайдер.
                  announce_step(task, step)
                  fail(
                    connection,
                    task,
                    option.unwrap(
                      exchange.assistant.error,
                      "провайдер вернул ошибку",
                    ),
                    step,
                  )
                }

                _ ->
                  case exchange.assistant.tool_calls {
                    // Модель ответила текстом — задание завершено.
                    // Это и есть честный признак, которого не хватало,
                    // пока инструментов не было.
                    [] -> {
                      announce_step(task, step)
                      finish(connection, task, exchange.assistant.content, step)
                    }

                    // Модель просит вызвать инструменты: выполняем их,
                    // кладём результаты в историю и идём на новый круг.
                    calls -> {
                      let results =
                        run_calls(
                          connection,
                          config,
                          agent,
                          session,
                          task,
                          step,
                          calls,
                          chain,
                          budget - step,
                        )

                      // Объявляем только теперь, когда дописаны и ответ
                      // модели, и результаты вызовов: подписчик читает
                      // шаг из БД, и объявить раньше значило бы показать
                      // его наполовину.
                      announce_step(task, step)

                      iterate(
                        connection,
                        config,
                        agent,
                        session,
                        task,
                        list.flatten([
                          history,
                          [exchange.user, exchange.assistant],
                          results,
                        ]),
                        step + 1,
                        chain,
                        budget,
                      )
                    }
                  }
              }
            }
          }
      }
    }
  }
}

/// Что агент помнит, начиная задание.
///
/// Сжатие идёт **до** сборки: иначе свежий пересказ не попал бы в
/// текущий запрос и применился бы только к следующему заданию.
fn recall(
  connection: Connection,
  config: Config,
  agent: Agent,
  session: Session,
  task: Task,
  provider_id: String,
  model_id: String,
) -> List(Message) {
  summarize.maybe_compress(
    connection,
    config,
    session,
    agent.memory,
    provider_id,
    model_id,
  )

  case config.find_model(config, provider_id, model_id) {
    // Модель неизвестна — бюджет посчитать не от чего. Сборка запроса
    // всё равно упадёт следом с внятной ошибкой.
    Error(Nil) -> []
    Ok(model) ->
      memory.build(connection, session.id, task.id, agent.memory, model, [])
  }
}

// ─── Вызовы инструментов ─────────────────────────────────────────────────────

/// Выполняет запрошенные вызовы и сохраняет каждый отдельной строкой.
///
/// Строка с ролью `Tool` несёт аргументы в `raw_request` и результат в
/// `raw_response`, поэтому существующая кнопка `{} JSON` показывает вызов
/// без каких-либо доработок.
///
/// Ошибка инструмента не прерывает задание: она возвращается модели как
/// результат вызова, чтобы та могла исправиться. Тот же принцип, по
/// которому ошибка провайдера становится сообщением, а не сбоем.
fn run_calls(
  connection: Connection,
  config: Config,
  agent: Agent,
  session: Session,
  task: Task,
  step: Int,
  calls: List(types.ToolCall),
  chain: List(String),
  budget: Int,
) -> List(Message) {
  let context =
    tools.ToolContext(
      db: connection,
      session_id: session.id,
      task_id: task.id,
      sandbox: config.sandbox,
      // Агент добавляет себя в цепочку: по ней `call_agent` распознаёт
      // цикл, когда кто-то пытается позвать уже работающего.
      chain: list.append(chain, [agent.id]),
      budget:,
      run_agent: fn(name, prompt, parent_chain, remaining) {
        start_subagent(
          connection,
          config,
          session,
          name,
          prompt,
          parent_chain,
          remaining,
        )
      },
    )

  list.filter_map(calls, fn(call) {
    let #(payload, ok) =
      tools.run(context, agent.tools, call.name, call.arguments)
    let body = json.to_string(payload)

    messages.NewMessage(
      ..messages.new(session.id, types.Tool, body),
      status: case ok {
        True -> types.Done
        False -> types.Failed
      },
      error: case ok {
        True -> None
        False -> Some("вызов " <> call.name <> " не удался")
      },
      raw_request: Some(call_preview(call)),
      raw_response: Some(body),
      task_id: Some(task.id),
      step: Some(step),
      tool_call_id: Some(call.id),
    )
    |> messages.insert(connection, _)
    |> result.replace_error(Nil)
  })
}

/// Аргументы вызова в читаемом виде — то, что видно под кнопкой JSON.
fn call_preview(call: types.ToolCall) -> String {
  json.to_string(
    json.object([
      #("tool", json.string(call.name)),
      #("arguments", json.string(call.arguments)),
    ]),
  )
}

fn finish(
  connection: Connection,
  task: Task,
  answer: String,
  steps: Int,
) -> Task {
  tasks.finish(connection, task.id, types.TaskDone, Some(answer), None, steps)
  |> result.unwrap(
    types.Task(..task, status: types.TaskDone, result: Some(answer), steps:),
  )
  |> announce
}

fn fail(
  connection: Connection,
  task: Task,
  reason: String,
  steps: Int,
) -> Task {
  tasks.finish(connection, task.id, types.TaskFailed, None, Some(reason), steps)
  |> result.unwrap(
    types.Task(..task, status: types.TaskFailed, error: Some(reason), steps:),
  )
  |> announce
}

/// Объявляет о готовности шага.
fn announce_step(task: Task, step: Int) -> Nil {
  events.publish(events.StepFinished(
    session_id: task.session_id,
    task_id: task.id,
    step:,
  ))
}

/// Объявляет о смене состояния задания.
///
/// Возвращает задание неизменным — чтобы вставать в конец конвейера, не
/// меняя его смысла. Наблюдение не влияет на результат работы.
fn announce(task: Task) -> Task {
  events.publish(events.TaskChanged(
    session_id: task.session_id,
    task_id: task.id,
  ))
  task
}

/// Запускает другого агента как подзадачу.
///
/// Вложенный запуск получает **свою сессию** с пометкой о происхождении:
/// так его работа видна в интерфейсе обычным образом, и наблюдаемость —
/// главная ценность проекта — не теряется.
fn start_subagent(
  connection: Connection,
  config: Config,
  parent: Session,
  name: String,
  prompt: String,
  chain: List(String),
  budget: Int,
) -> Result(String, String) {
  use callee <- result.try(
    agents.find_by_name(connection, name)
    |> result.replace_error("агент «" <> name <> "» не найден"),
  )

  // Обнаружение цикла: агент, уже работающий выше по дереву, не может
  // быть вызван снова — иначе получим бесконечную рекурсию.
  use Nil <- result.try(case list.contains(chain, callee.id) {
    True ->
      Error(
        "агент «"
        <> name
        <> "» уже участвует в этой цепочке вызовов — это зациклило бы работу",
      )
    False -> Ok(Nil)
  })

  use Nil <- result.try(case budget > 0 {
    True -> Ok(Nil)
    False -> Error("исчерпан общий бюджет шагов")
  })

  use session <- result.try(
    sessions.create_for_agent(
      connection,
      Some(callee.id),
      Some(callee.name <> " ← " <> parent.title),
      Some(callee.provider_id),
      Some(callee.model_id),
    )
    |> result.replace_error("не удалось создать запуск агента"),
  )

  use task <- result.try(
    tasks.create(connection, session.id, prompt)
    |> result.replace_error("не удалось создать задание"),
  )

  let finished =
    run_nested(connection, config, callee, session, task, chain, budget)

  case finished.status {
    types.TaskDone -> Ok(option.unwrap(finished.result, ""))
    _ ->
      Error(
        "агент «"
        <> name
        <> "» не справился: "
        <> option.unwrap(finished.error, "неизвестная причина"),
      )
  }
}

// ─── Проверки ────────────────────────────────────────────────────────────────

fn require_agent(session: Session, next: fn() -> Result(a, TaskError)) {
  case session.agent_id {
    Some(_) -> next()
    None -> Error(NoAgent)
  }
}

fn require_prompt(
  prompt: String,
  next: fn(String) -> Result(a, TaskError),
) -> Result(a, TaskError) {
  case string.trim(prompt) {
    "" -> Error(EmptyPrompt)
    trimmed -> next(trimmed)
  }
}

// ─── Описание ошибок ─────────────────────────────────────────────────────────

pub fn describe(error: TaskError) -> String {
  case error {
    NoAgent ->
      "сессия не принадлежит агенту: задания выдаются только запускам агентов"
    Busy(id) -> "в сессии уже выполняется задание " <> id
    EmptyPrompt -> "текст задания пуст"
    Storage(detail) -> "ошибка хранилища: " <> detail
  }
}

pub fn error_code(error: TaskError) -> String {
  case error {
    NoAgent -> "session_without_agent"
    Busy(_) -> "task_already_running"
    EmptyPrompt -> "empty_prompt"
    Storage(_) -> "storage_error"
  }
}

pub fn http_status(error: TaskError) -> Int {
  case error {
    NoAgent | EmptyPrompt -> 400
    Busy(_) -> 409
    Storage(_) -> 500
  }
}
