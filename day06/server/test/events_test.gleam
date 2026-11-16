//// Тесты шины событий.
////
//// Шина — то место, где встречаются цикл агента и HTTP-соединение, не
//// зная друг о друге. Проверяется именно развязка: доставка нужным
//// подписчикам, молчание при их отсутствии и живучесть при их гибели.

import gleam/erlang/process
import server/events

/// Подписчик получает события своей сессии.
pub fn delivers_to_subscriber_test() {
  let assert Ok(_) = events.start()
  let inbox = process.new_subject()
  events.subscribe("ses_a", inbox)

  events.publish(events.StepFinished("ses_a", "tsk_1", 2))

  let assert Ok(event) = process.receive(inbox, 200)
  assert event == events.StepFinished("ses_a", "tsk_1", 2)
}

/// Утечка между сессиями означала бы показ чужой переписки.
pub fn isolates_sessions_test() {
  let assert Ok(_) = events.start()
  let mine = process.new_subject()
  let foreign = process.new_subject()
  events.subscribe("ses_mine", mine)
  events.subscribe("ses_foreign", foreign)

  events.publish(events.TaskChanged("ses_mine", "tsk_1"))

  let assert Ok(_) = process.receive(mine, 200)
  assert process.receive(foreign, 100) == Error(Nil)
}

/// Публикация без подписчиков ничего не стоит и ничего не ломает:
/// задания чаще выполняются при закрытом браузере, чем при открытом.
pub fn publish_without_subscribers_is_safe_test() {
  let assert Ok(_) = events.start()
  events.publish(events.StepFinished("ses_nobody", "tsk_1", 1))

  // Шина жива и продолжает обслуживать: публикация в пустоту не убила её.
  let inbox = process.new_subject()
  events.subscribe("ses_nobody", inbox)
  events.publish(events.TaskChanged("ses_nobody", "tsk_1"))
  let assert Ok(_) = process.receive(inbox, 200)
}

/// До старта шины публикация тоже допустима — цикл агента не обязан
/// знать, поднято ли наблюдение.
pub fn publish_before_start_is_safe_test() {
  events.publish(events.TaskChanged("ses_x", "tsk_x"))
  assert events.subscriber_count() >= 0
}

/// Один подписчик получает все события подряд, в порядке публикации.
pub fn preserves_order_test() {
  let assert Ok(_) = events.start()
  let inbox = process.new_subject()
  events.subscribe("ses_order", inbox)

  events.publish(events.StepFinished("ses_order", "tsk_1", 1))
  events.publish(events.StepFinished("ses_order", "tsk_1", 2))
  events.publish(events.TaskChanged("ses_order", "tsk_1"))

  let assert Ok(events.StepFinished(step: 1, ..)) = process.receive(inbox, 200)
  let assert Ok(events.StepFinished(step: 2, ..)) = process.receive(inbox, 200)
  let assert Ok(events.TaskChanged(..)) = process.receive(inbox, 200)
}

/// Несколько окон на одну сессию — обычное дело.
pub fn broadcasts_to_all_subscribers_test() {
  let assert Ok(_) = events.start()
  let first = process.new_subject()
  let second = process.new_subject()
  events.subscribe("ses_many", first)
  events.subscribe("ses_many", second)

  events.publish(events.TaskChanged("ses_many", "tsk_1"))

  let assert Ok(_) = process.receive(first, 200)
  let assert Ok(_) = process.receive(second, 200)
}

/// Браузер закрывают посреди задания. Мёртвая подписка должна исчезнуть
/// сама, а шина — продолжить работу.
pub fn forgets_dead_subscribers_test() {
  let assert Ok(_) = events.start()
  let before = events.subscriber_count()

  // Процесс, который подписывается и сразу умирает.
  let pid =
    process.spawn_unlinked(fn() {
      events.subscribe("ses_dead", process.new_subject())
      Nil
    })

  // Ждём, пока он завершится.
  let _ = wait_until_dead(pid, 20)

  let survivor = process.new_subject()
  events.subscribe("ses_dead", survivor)
  events.publish(events.TaskChanged("ses_dead", "tsk_1"))

  let assert Ok(_) = process.receive(survivor, 200)
  // Мёртвая подписка убрана, живая осталась.
  assert events.subscriber_count() == before + 1
}

fn wait_until_dead(pid: process.Pid, attempts: Int) -> Nil {
  case attempts <= 0 || !process.is_alive(pid) {
    True -> Nil
    False -> {
      process.sleep(10)
      wait_until_dead(pid, attempts - 1)
    }
  }
}

/// Повторный `start` — не ошибка: шина уже работает.
pub fn start_is_idempotent_test() {
  let assert Ok(first) = events.start()
  let assert Ok(second) = events.start()
  assert first == second
}
