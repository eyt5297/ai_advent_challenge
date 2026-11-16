//// Доступ к каталогу провайдеров и моделей.
////
//// Сами данные лежат в сгенерированном `shared/catalog/generated`
//// (см. ./scripts/gen_catalog.sh). Этот модуль — стабильный фасад над ними:
//// если позже каталог начнёт тянуться по сети, меняется только он.

import gleam/list
import gleam/option.{type Option}
import gleam/result
import shared/catalog/generated
import shared/types.{type ModelInfo, type Provider}

/// Все провайдеры в порядке отображения.
pub fn providers() -> List(Provider) {
  generated.providers()
}

pub fn provider(id: String) -> Result(Provider, Nil) {
  types.find_provider(providers(), id)
}

/// Провайдер по умолчанию — первый в каталоге.
pub fn default_provider() -> Result(Provider, Nil) {
  case providers() {
    [first, ..] -> Ok(first)
    [] -> Error(Nil)
  }
}

pub fn model(provider_id: String, model_id: String) -> Result(ModelInfo, Nil) {
  use found <- result.try(provider(provider_id))
  types.find_model(found, model_id)
}

/// Все модели провайдера одним списком.
pub fn models(provider_id: String) -> List(ModelInfo) {
  case provider(provider_id) {
    Ok(found) -> types.provider_models(found)
    Error(Nil) -> []
  }
}

/// Модель, выбираемая при переключении на провайдера: его `default_model`,
/// а если такой в каталоге нет — первая доступная.
pub fn default_model(provider_id: String) -> Option(ModelInfo) {
  case provider(provider_id) {
    Error(Nil) -> option.None
    Ok(found) ->
      case types.find_model(found, found.default_model) {
        Ok(model) -> option.Some(model)
        Error(Nil) ->
          types.provider_models(found) |> list.first |> option.from_result
      }
  }
}
