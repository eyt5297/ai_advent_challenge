//// Поток событий сессии: `GET /api/sessions/:id/events`.
////
//// Единственное место, где mist используется напрямую, минуя wisp.
//// Причина простая: `mist.server_sent_events` требует
//// `Request(mist.Connection)`, а wisp этот тип уже спрятал за своей
//// абстракцией. SSE — принципиально другой вид ответа, который wisp не
//// моделирует, поэтому маршрут раздваивается до него (SPEC_AGENTS.md,
//// п. 14.6).
////
//// Подписка идёт на **сессию**, а не на задание: так она переживает смену
//// заданий, и клиенту не нужно переподключаться на каждое новое.

import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/json.{type Json}
import gleam/otp/actor
import gleam/string_tree
import mist
import server/events.{type Event}
import server/repo/messages
import server/repo/tasks
import server/web.{type Context}
import shared/api
import sqlight.{type Connection}

/// Как часто слать `ping`.
///
/// Прокси и балансировщики закрывают тихое соединение через минуту-две.
/// Тридцать секунд — с запасом, и при этом не шумно.
const ping_interval_ms = 30_000

/// Что знает процесс соединения.
type State {
  State(
    db: Connection,
    session_id: String,
    /// Собственный ящик: в него приходят и события шины, и таймер ping.
    inbox: Subject(Event),
  )
}

/// Отдельный тип сообщения не нужен: ping — это обычное событие шины,
/// которое процесс шлёт сам себе. Так в цикле ровно один вид входящих.
fn ping_event(session_id: String) -> Event {
  events.TaskChanged(session_id:, task_id: "")
}

pub fn handle(
  request: Request(mist.Connection),
  context: Context,
  session_id: String,
) -> response.Response(mist.ResponseData) {
  mist.server_sent_events(
    request:,
    // Заголовки `text/event-stream`, `no-cache` и `keep-alive` mist
    // проставляет сам — без них прокси буферизует поток, и весь этап
    // теряет смысл.
    initial_response: response.new(200),
    init: fn(subject) {
      events.subscribe(session_id, subject)
      schedule_ping(subject, session_id)
      State(db: context.db, session_id:, inbox: subject)
    },
    loop: fn(state, event, connection) { step(state, event, connection) },
  )
}

fn step(
  state: State,
  event: Event,
  connection: mist.SSEConnection,
) -> actor.Next(State, Event) {
  let outcome = case event {
    // Пустой task_id — наш собственный ping, а не настоящее изменение.
    events.TaskChanged(task_id: "", ..) -> {
      schedule_ping(state.inbox, state.session_id)
      send(connection, "ping", json.object([]))
    }

    events.TaskChanged(task_id:, ..) ->
      case tasks.get(state.db, task_id) {
        Ok(task) ->
          send(connection, "task", api.task_event_to_json(api.TaskEvent(task:)))
        Error(_) -> Ok(Nil)
      }

    events.StepFinished(task_id:, step:, ..) ->
      case messages.list_for_step(state.db, task_id, step) {
        // Шага ещё нет в базе — объявлять нечего.
        Ok([]) -> Ok(Nil)
        Ok(rows) ->
          send(
            connection,
            "step",
            api.step_event_to_json(api.StepEvent(
              task_id:,
              step:,
              messages: rows,
            )),
          )
        Error(_) -> Ok(Nil)
      }
  }

  case outcome {
    Ok(Nil) -> actor.continue(state)
    // Клиент отключился — закрываем процесс. Шина уберёт подписку сама
    // при следующей рассылке.
    Error(Nil) -> actor.stop()
  }
}

/// Отправляет именованное событие с телом-объектом.
///
/// Тело — полный объект, а не идентификатор: иначе на каждое событие
/// клиент отвечал бы запросом, и мы получили бы ту же задержку плюс
/// лишний трафик. Декодеры при этом те же, что у `GET /api/tasks/:id`.
fn send(
  connection: mist.SSEConnection,
  name: String,
  body: Json,
) -> Result(Nil, Nil) {
  mist.event(string_tree.from_string(json.to_string(body)))
  |> mist.event_name(name)
  |> mist.send_event(connection, _)
}

fn schedule_ping(inbox: Subject(Event), session_id: String) -> Nil {
  let _timer =
    process.send_after(inbox, ping_interval_ms, ping_event(session_id))
  Nil
}

/// Маршрут потока: `/api/sessions/:id/events`.
///
/// Распознаётся до wisp, поэтому проверка пути живёт здесь, а не в
/// роутере.
pub fn match(segments: List(String)) -> Result(String, Nil) {
  case segments {
    ["api", "sessions", id, "events"] -> Ok(id)
    _ -> Error(Nil)
  }
}
