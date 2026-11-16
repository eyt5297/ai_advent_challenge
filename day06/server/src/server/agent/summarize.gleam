//// Сжатие вытесненной истории в пересказ.
////
//// Отдельно от `agent/memory.gleam`, потому что это единственная часть
//// памяти, которая **обращается к модели**: стоит денег, занимает время
//// и может не получиться. Остальное — чтение БД и резка списков.
////
//// Пересказ не трогает `messages`: исходные шаги остаются со всеми
//// сырыми телами. Сжимается только то, что подставляется в запрос.
////
//// Запрос идёт мимо `chat.send`, то есть **не сохраняется в ленту**.
//// Иначе служебный вызов выглядел бы шагом задания и путал бы картину
//// наблюдения — ту самую, ради которой проект и строился.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/config.{type Config}
import server/llm/chat
import server/llm/client
import server/llm/response
import server/repo/memory as memory_repo
import server/repo/messages
import shared/types.{type Memory, type Message, type Session, type Summary}
import sqlight.{type Connection}

/// Промпт сжатия.
///
/// Просит сохранить решения и факты, а не «написать красиво»: пересказ
/// нужен агенту для работы, а не человеку для чтения.
const instruction =
  "Ниже — часть диалога между пользователем и агентом.
Изложи её кратко, от третьего лица, сохранив:
- что именно просил пользователь и что было сделано;
- принятые решения и договорённости;
- конкретные факты, имена, числа и названия файлов.

Не выдумывай ничего сверх написанного. Не пересказывай вызовы
инструментов подробно — достаточно их результата. Уложись в 200 слов."

/// Сжимает историю, если накопилось достаточно невошедшего.
///
/// Возвращает `Nil` в любом случае: неудача сжатия не должна срывать
/// задание. Агент в худшем случае получит менее полную память — это
/// хуже, чем могло быть, но лучше, чем упавшее задание.
pub fn maybe_compress(
  connection: Connection,
  config: Config,
  session: Session,
  memory: Memory,
  provider_id: String,
  model_id: String,
) -> Nil {
  case memory.summary {
    types.NoSummary -> Nil
    types.SummarizeEvery(messages: threshold) ->
      compress_if_due(
        connection,
        config,
        session,
        threshold,
        provider_id,
        model_id,
      )
  }
}

fn compress_if_due(
  connection: Connection,
  config: Config,
  session: Session,
  threshold: Int,
  provider_id: String,
  model_id: String,
) -> Nil {
  let previous = case memory_repo.latest_summary(connection, session.id) {
    Ok(summary) -> Some(summary)
    Error(_) -> None
  }

  let covered = case previous {
    Some(summary) -> summary.covers_through_seq
    None -> 0
  }

  case pending(connection, session.id, covered) {
    // Ещё не накопилось — пересказывать нечего.
    pending if pending == [] -> Nil
    pending ->
      case list.length(pending) >= int.max(threshold, 1) {
        False -> Nil
        True ->
          compress(
            connection,
            config,
            session,
            previous,
            pending,
            provider_id,
            model_id,
          )
      }
  }
}

/// Сообщения, ещё не вошедшие в пересказ.
///
/// Только содержательные: пустые служебные строки и неудачные шаги
/// пересказывать нечего, а место в запросе они занимают.
fn pending(
  connection: Connection,
  session_id: String,
  covered_through: Int,
) -> List(Message) {
  case messages.list_for_session(connection, session_id) {
    Error(_) -> []
    Ok(all) ->
      list.filter(all, fn(message) {
        message.seq > covered_through
        && message.status != types.Failed
        && string.trim(message.content) != ""
      })
  }
}

fn compress(
  connection: Connection,
  config: Config,
  session: Session,
  previous: Option(Summary),
  pending: List(Message),
  provider_id: String,
  model_id: String,
) -> Nil {
  let transcript = render(pending)

  // Пересказывается пересказ, а не вся история заново: иначе каждое
  // сжатие стоило бы всё дороже, а контекст рано или поздно кончился бы.
  let source = case previous {
    None -> transcript
    Some(summary) ->
      "Ранее уже было изложено:\n"
      <> summary.text
      <> "\n\nПродолжение диалога:\n"
      <> transcript
  }

  let prepared =
    chat.prepare(
      config,
      provider_id,
      model_id,
      Some(instruction <> "\n\n" <> source),
      // Свои параметры, не агентские: сжатие — служебная операция, и
      // температура, заданная для творческих ответов, здесь вредна.
      types.RequestOptions(
        ..types.default_options(),
        temperature: Some(0.0),
        max_tokens: Some(800),
      ),
      None,
      [],
      [],
    )

  case prepared {
    Error(_) -> Nil
    Ok(prepared) ->
      case send_quietly(config, prepared) {
        Error(Nil) -> Nil
        Ok(text) -> {
          let last_seq =
            list.fold(pending, 0, fn(highest, message) {
              int.max(highest, message.seq)
            })

          let _ =
            memory_repo.save_summary(
              connection,
              session.id,
              text,
              last_seq,
              list.length(pending),
            )
          Nil
        }
      }
  }
}

/// Отправляет запрос, не записывая обмен в ленту.
///
/// Намеренно не `chat.send`: тот сохраняет пару сообщений, и служебное
/// сжатие выглядело бы шагом задания.
fn send_quietly(
  config: Config,
  prepared: chat.Prepared,
) -> Result(String, Nil) {
  use exchange <- result.try(
    client.send(prepared.entry, prepared.body, config.request_timeout_ms)
    |> result.replace_error(Nil),
  )

  use parsed <- result.try(
    response.parse_response_body(
      prepared.entry.provider,
      exchange.http_status,
      exchange.response_body,
    )
    |> result.replace_error(Nil),
  )

  case string.trim(parsed.content) {
    "" -> Error(Nil)
    text -> Ok(text)
  }
}

/// Диалог в виде текста для модели.
fn render(history: List(Message)) -> String {
  history
  |> list.map(fn(message) {
    let who = case message.role {
      types.User -> "Пользователь"
      types.Assistant -> "Агент"
      types.Tool -> "Инструмент"
      types.System -> "Система"
    }
    who <> ": " <> string.trim(message.content)
  })
  |> string.join("\n")
}
