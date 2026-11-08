import aichat/db
import aichat/web
import envoy
import gleam/erlang/process
import gleam/int
import gleam/result
import mist
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let assert Ok(_) = db.migrate() as "не удалось создать таблицу в sqlite"

  let ctx = web.Context(api_key: envoy.get("OPENAI_API_KEY"))
  let secret_key_base = wisp.random_string(64)
  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(8000)

  let assert Ok(_) =
    wisp_mist.handler(web.handle_request(ctx, _), secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  wisp.log_info("Открой http://localhost:" <> int.to_string(port))
  process.sleep_forever()
}
