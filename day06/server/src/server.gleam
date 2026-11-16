//// Точка входа: читает конфиг, открывает БД, поднимает HTTP-сервер.

import envoy
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import mist
import server/config.{type Config}
import server/db
import server/events
import server/router
import server/sse
import server/web
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()
  let config = config.load()

  case db.connect(config.db_path) {
    Error(error) -> {
      wisp.log_critical("не удалось открыть БД: " <> db.describe(error))
      // Без базы работать нечему — выходим с ненулевым кодом.
      halt(1)
    }

    Ok(connection) -> {
      let context = web.Context(config:, db: connection)

      // Шина наблюдения. Неудача не фатальна: без неё работает всё, кроме
      // живого потока событий, а задания важнее наблюдения за ними.
      case events.start() {
        Ok(_) -> Nil
        Error(Nil) ->
          wisp.log_warning("шина событий не поднялась: поток SSE недоступен")
      }

      // Занятый порт роняет mist изнутри супервизора, до возврата из
      // `start`, поэтому перехватить это здесь нельзя — порт заранее
      // проверяет run.sh.
      let wisp_handler =
        wisp_mist.handler(router.handle(_, context), secret_key_base())

      case
        dispatch(_, context, wisp_handler)
        |> mist.new
        |> mist.port(config.port)
        |> mist.bind("0.0.0.0")
        |> mist.start
      {
        Ok(_) -> {
          report_startup(config)
          process.sleep_forever()
        }

        Error(_) -> {
          io.println_error(
            "\nОШИБКА: не удалось запустить HTTP-сервер на порту "
            <> int.to_string(config.port)
            <> ".\nУкажите другой, например: PORT=8090 ./run.sh serve\n",
          )
          halt(1)
        }
      }
    }
  }
}

/// Развилка до wisp.
///
/// SSE требует `Request(mist.Connection)`, который wisp уже спрятал за
/// своей абстракцией, поэтому поток событий отводится раньше. Это
/// единственное место, где слои смешиваются, и оно того стоит: весь
/// остальной API продолжает жить в `router.gleam` без изменений.
fn dispatch(
  request: Request(mist.Connection),
  context: web.Context,
  wisp_handler: fn(Request(mist.Connection)) -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case sse.match(request.path_segments(request)) {
    Ok(session_id) -> sse.handle(request, context, session_id)
    Error(Nil) -> wisp_handler(request)
  }
}

/// Сводка при старте: сразу видно, какие провайдеры реально доступны.
fn report_startup(config: Config) -> Nil {
  wisp.log_info(
    "сервер слушает http://localhost:" <> int.to_string(config.port),
  )
  wisp.log_info("БД: " <> config.db_path)

  list.each(config.providers, fn(entry) {
    let state = case config.is_available(entry) {
      True -> "готов"
      False -> "НЕТ КЛЮЧА"
    }
    wisp.log_info(
      "провайдер "
      <> entry.provider.title
      <> " ("
      <> entry.base_url
      <> "): "
      <> state,
    )
  })

  case list.any(config.providers, config.is_available) {
    True -> Nil
    False ->
      wisp.log_warning(
        "ни один провайдер не настроен — задайте OPENAI_API_KEY и/или KIMI_API_KEY",
      )
  }
}

/// Ключ подписи куки. Сессий пользователей пока нет, но wisp требует его;
/// при отсутствии переменной генерируем случайный на время работы.
fn secret_key_base() -> String {
  case envoy.get("SECRET_KEY_BASE") {
    Ok(value) if value != "" -> value
    _ -> wisp.random_string(64)
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
