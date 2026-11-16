//// Конфигурация из переменных окружения.
////
//// Читается один раз при старте и передаётся дальше явным значением —
//// глобального состояния нет.

import envoy
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import shared/catalog
import shared/types.{type Provider}

pub type Config {
  Config(
    port: Int,
    db_path: String,
    static_dir: String,
    request_timeout_ms: Int,
    /// Настройки провайдеров в порядке каталога.
    providers: List(ProviderConfig),
    /// Ограничения для опасных инструментов агента.
    sandbox: Sandbox,
  )
}

/// Границы, за которые инструменты не выходят.
///
/// Всё выключено по умолчанию: доступ к файлам и сети — осознанное
/// решение администратора, а не следствие невнимательности.
pub type Sandbox {
  Sandbox(
    /// Корень для `read_file`. None — инструмент недоступен.
    files_root: Option(String),
    /// Предел размера читаемого файла: иначе один вызов съест контекст.
    max_file_bytes: Int,
    /// Хосты, разрешённые `http_request`. Пустой список — запрет.
    http_allowlist: List(String),
    max_http_bytes: Int,
    /// Предел вложенности `call_agent` — защита от рекурсии.
    max_depth: Int,
  )
}

/// Провайдер вместе с тем, что нужно для обращения к нему.
pub type ProviderConfig {
  ProviderConfig(
    provider: Provider,
    base_url: String,
    /// None — ключ не задан, провайдер недоступен.
    api_key: Option(String),
  )
}

pub fn load() -> Config {
  Config(
    port: env_int("PORT", 8080),
    db_path: env_string("DB_PATH", "data/chat.db"),
    static_dir: env_string("STATIC_DIR", "priv/static"),
    request_timeout_ms: env_int("REQUEST_TIMEOUT_MS", 120_000),
    providers: load_providers(),
    sandbox: load_sandbox(),
  )
}

fn load_sandbox() -> Sandbox {
  Sandbox(
    files_root: env_non_empty("AGENT_FILES_ROOT"),
    max_file_bytes: env_int("AGENT_MAX_FILE_BYTES", 64_000),
    http_allowlist: load_allowlist(),
    max_http_bytes: env_int("AGENT_MAX_HTTP_BYTES", 64_000),
    max_depth: env_int("AGENT_MAX_DEPTH", 3),
  )
}

/// Хосты через запятую: `AGENT_HTTP_ALLOWLIST=api.github.com,example.com`.
fn load_allowlist() -> List(String) {
  case env_non_empty("AGENT_HTTP_ALLOWLIST") {
    None -> []
    Some(raw) ->
      raw
      |> string.split(",")
      |> list.map(string.trim)
      |> list.map(string.lowercase)
      |> list.filter(fn(host) { host != "" })
  }
}

fn load_providers() -> List(ProviderConfig) {
  list.map(catalog.providers(), fn(provider) {
    let #(base_url_var, base_url_default, key_var) = case provider.id {
      "veai" -> #(
        "VEAI_BASE_URL",
        "https://api.veai.ru/openai/api/v1",
        "OPENAI_API_KEY",
      )
      "kimi" -> #(
        "KIMI_BASE_URL",
        "https://api.kimi.ai/coding/v1",
        "KIMI_API_KEY",
      )
      // Новый провайдер в каталоге без записи здесь: пусть сконфигурируется
      // переменными <ID>_BASE_URL / <ID>_API_KEY.
      other -> {
        let prefix = string.uppercase(other)
        #(prefix <> "_BASE_URL", "", prefix <> "_API_KEY")
      }
    }
    ProviderConfig(
      provider: provider,
      base_url: env_string(base_url_var, base_url_default)
        |> strip_trailing_slash,
      api_key: env_non_empty(key_var),
    )
  })
}

pub fn provider_config(
  config: Config,
  provider_id: String,
) -> Result(ProviderConfig, Nil) {
  list.find(config.providers, fn(entry) { entry.provider.id == provider_id })
}

/// Модель из каталога — для подсчёта бюджета памяти.
pub fn find_model(
  config: Config,
  provider_id: String,
  model_id: String,
) -> Result(types.ModelInfo, Nil) {
  use entry <- result.try(provider_config(config, provider_id))
  types.find_model(entry.provider, model_id)
}

/// Провайдер доступен, если у него есть и ключ, и адрес.
pub fn is_available(entry: ProviderConfig) -> Bool {
  option.is_some(entry.api_key) && entry.base_url != ""
}

/// Полный URL эндпоинта чата.
pub fn chat_url(entry: ProviderConfig) -> String {
  entry.base_url <> "/chat/completions"
}

// ─── Чтение окружения ────────────────────────────────────────────────────────

fn env_string(name: String, fallback: String) -> String {
  case env_non_empty(name) {
    Some(value) -> value
    None -> fallback
  }
}

fn env_int(name: String, fallback: Int) -> Int {
  env_non_empty(name)
  |> option.to_result(Nil)
  |> result.try(int.parse)
  |> result.unwrap(fallback)
}

/// Пустая переменная равнозначна незаданной — иначе `export KIMI_API_KEY=`
/// дал бы запрос с пустым Bearer и непонятный 401.
fn env_non_empty(name: String) -> Option(String) {
  case envoy.get(name) {
    Ok(value) ->
      case string.trim(value) {
        "" -> None
        trimmed -> Some(trimmed)
      }
    Error(Nil) -> None
  }
}

fn strip_trailing_slash(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> string.drop_end(url, 1) |> strip_trailing_slash
    False -> url
  }
}
