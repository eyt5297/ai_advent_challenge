//// Шина событий: «что-то изменилось в сессии».
////
//// Нужна, чтобы цикл агента мог сообщить о готовом шаге, ничего не зная о
//// том, слушает ли его кто-нибудь. Модуль не импортирует ни `wisp`, ни
//// `mist`, ни репозитории: он переносит уведомления, а не данные.
////
//// **В событии только идентификаторы.** Тело читает подписчик, сам, из БД.
//// Иначе цикл собирал бы JSON на каждое соединение — в том числе когда их
//// ноль. Источник правды остаётся в базе (SPEC_AGENTS.md, п. 10.2), а шина
//// лишь говорит «посмотри туда»: пропущенное событие не теряет данные, а
//// значит, клиент узнает о шаге чуть позже — и только.

import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result

/// Что произошло. Расширяется добавлением — подписчик игнорирует
/// незнакомое.
pub type Event {
  /// Шаг задания завершён и записан в БД.
  StepFinished(session_id: String, task_id: String, step: Int)
  /// Задание сменило состояние: создано, завершилось, упало.
  TaskChanged(session_id: String, task_id: String)
}

pub fn session_id(event: Event) -> String {
  case event {
    StepFinished(session_id:, ..) -> session_id
    TaskChanged(session_id:, ..) -> session_id
  }
}

// ─── Протокол шины ───────────────────────────────────────────────────────────

pub opaque type Message {
  Publish(Event)
  Subscribe(session_id: String, subscriber: Subject(Event))
  /// Только для тестов: сколько подписок сейчас живо.
  Count(reply: Subject(Int))
}

type Subscription {
  Subscription(session_id: String, subscriber: Subject(Event))
}

/// Имя шины — фиксированный атом из FFI.
///
/// `process.new_name` порождает новый атом при каждом вызове, и звать её
/// из разных мест значило бы заполнять таблицу атомов. Фиксированный атом
/// позволяет публиковать событие откуда угодно, не протаскивая `Subject`
/// через всю цепочку вызовов.
@external(erlang, "server_events_ffi", "bus_name")
fn bus_name() -> Name(Message)

/// Поднимает шину. Зовётся один раз при старте.
///
/// Повторный запуск — не ошибка: имя уже занято, значит шина работает.
pub fn start() -> Result(Pid, Nil) {
  case process.named(bus_name()) {
    Ok(pid) -> Ok(pid)
    Error(Nil) ->
      actor.new([])
      |> actor.on_message(handle)
      |> actor.named(bus_name())
      |> actor.start
      |> result.map(fn(started) { started.pid })
      |> result.replace_error(Nil)
  }
}

/// Сообщает об изменении. Ничего не стоит, если никто не слушает.
///
/// Намеренно возвращает `Nil`, а не `Result`: цикл агента не должен
/// прерываться из-за того, что шина не поднялась. Наблюдение — удобство,
/// а работа агента — суть.
pub fn publish(event: Event) -> Nil {
  case process.named(bus_name()) {
    Ok(_) -> process.send(process.named_subject(bus_name()), Publish(event))
    Error(Nil) -> Nil
  }
}

/// Подписывает `subscriber` на события одной сессии.
pub fn subscribe(session_id: String, subscriber: Subject(Event)) -> Nil {
  case process.named(bus_name()) {
    Ok(_) ->
      process.send(
        process.named_subject(bus_name()),
        Subscribe(session_id:, subscriber:),
      )
    Error(Nil) -> Nil
  }
}

/// Число живых подписок — для тестов и диагностики.
pub fn subscriber_count() -> Int {
  case process.named(bus_name()) {
    Error(Nil) -> 0
    Ok(_) -> process.call(process.named_subject(bus_name()), 1000, Count)
  }
}

// ─── Поведение ───────────────────────────────────────────────────────────────

fn handle(
  state: List(Subscription),
  message: Message,
) -> actor.Next(List(Subscription), Message) {
  case message {
    Subscribe(session_id:, subscriber:) ->
      actor.continue([Subscription(session_id:, subscriber:), ..state])

    Publish(event) -> {
      // Мёртвые подписки убираются здесь же: браузер закрывают посреди
      // задания, и это норма, а не сбой. Монитор на каждое соединение был
      // бы точнее, но `send` мёртвому процессу в Erlang безвреден, так что
      // ленивой уборки достаточно.
      let alive = list.filter(state, is_alive)

      list.each(alive, fn(subscription) {
        case subscription.session_id == events_session(event) {
          True -> process.send(subscription.subscriber, event)
          False -> Nil
        }
      })

      actor.continue(alive)
    }

    Count(reply:) -> {
      let alive = list.filter(state, is_alive)
      process.send(reply, list.length(alive))
      actor.continue(alive)
    }
  }
}

fn events_session(event: Event) -> String {
  session_id(event)
}

fn is_alive(subscription: Subscription) -> Bool {
  case process.subject_owner(subscription.subscriber) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
}
