# Преобразует ответы /models провайдеров в shared/src/shared/catalog/generated.gleam
#
# Вход: { "veai": <ответ veai>, "kimi": <ответ kimi> }
# Выход: исходник на Gleam (строки)

def gstr: @json;

def indent($n): "  " * $n;

# ── Reasoning ────────────────────────────────────────────────────────────────

def efforts_list($xs): "[" + ([$xs[] | gstr] | join(", ")) + "]";

# veai: supports_reasoning + reasoning{mandatory, default_enabled, default_effort, supported_efforts}
def veai_reasoning:
  if (.supports_reasoning | not) then
    "NoReasoning"
  elif (.reasoning.mandatory // false) then
    "AlwaysReasoning(default_effort: " + ((.reasoning.default_effort // "") | gstr)
    + ", efforts: " + efforts_list(.reasoning.supported_efforts // []) + ")"
  else
    "OptionalReasoning(default_enabled: "
    + (if (.reasoning.default_enabled // false) then "True" else "False" end)
    + ", default_effort: " + ((.reasoning.default_effort // "") | gstr)
    + ", efforts: " + efforts_list(.reasoning.supported_efforts // []) + ")"
  end;

# kimi: supports_thinking_type == "only" => рассуждает всегда
def kimi_reasoning:
  if (.supports_reasoning | not) then
    "NoReasoning"
  elif (.supports_thinking_type == "only") then
    "AlwaysReasoning(default_effort: "
    + ((.think_efforts.default_effort // .reasoning.effort.default // "") | gstr)
    + ", efforts: "
    + efforts_list(.think_efforts.valid_efforts // .reasoning.effort.valid // [])
    + ")"
  else
    "OptionalReasoning(default_enabled: True, default_effort: "
    + ((.think_efforts.default_effort // "") | gstr)
    + ", efforts: " + efforts_list(.think_efforts.valid_efforts // []) + ")"
  end;

# ── ModelInfo ────────────────────────────────────────────────────────────────

def model_info($reasoning):
  indent(5) + "ModelInfo(\n"
  + indent(6) + "id: " + (.id | gstr) + ",\n"
  + indent(6) + "title: " + (.title | gstr) + ",\n"
  + indent(6) + "context_length: " + (.context_length | tostring) + ",\n"
  + indent(6) + "max_output_tokens: " + (.max_output_tokens | tostring) + ",\n"
  + indent(6) + "vision: " + (if .vision then "True" else "False" end) + ",\n"
  + indent(6) + "tools: " + (if .tools then "True" else "False" end) + ",\n"
  + indent(6) + "reasoning: " + $reasoning + ",\n"
  + indent(5) + ")";

def model_group($title; $models):
  indent(3) + "ModelGroup(title: " + ($title | gstr) + ", models: [\n"
  + ($models | join(",\n")) + ",\n"
  + indent(4) + "]),";

def provider($id; $title; $default; $groups):
  indent(2) + "Provider(\n"
  + indent(3) + "id: " + ($id | gstr) + ",\n"
  + indent(3) + "title: " + ($title | gstr) + ",\n"
  + indent(3) + "default_model: " + ($default | gstr) + ",\n"
  + indent(3) + "groups: [\n"
  + ($groups | join("\n")) + "\n"
  + indent(3) + "],\n"
  + indent(2) + "),";

# ── veai ─────────────────────────────────────────────────────────────────────

# Порядок групп в выпадающем списке.
def veai_group_order: ["Авто", "Anthropic", "OpenAI", "Google", "Qwen", "Z.AI", "DeepSeek", "Moonshot"];

def veai_models:
  [ .veai.data[]
    | {
        id: .id,
        # title от veai — короткое имя без префикса вендора
        title: (.title // .id),
        context_length: (.context_length // .context_window // 0),
        max_output_tokens: (.max_output_tokens // 0),
        vision: (.supports_vision // false),
        tools: (.supports_tool_calls // false),
        reasoning: veai_reasoning,
        # алиасы маршрутизации (auto/autopilot/free) не имеют префикса вендора
        group: (if (.id | contains("/")) then (.id | split("/")[0]) else "Авто" end),
      }
  ];

def veai_groups:
  veai_models as $ms
  | [ veai_group_order[] as $g
      | ($ms | map(select(.group == $g)) | sort_by(.id) | reverse) as $in_group
      | select($in_group | length > 0)
      | model_group($g; [$in_group[] | model_info(.reasoning)])
    ];

# ── kimi ─────────────────────────────────────────────────────────────────────

def kimi_models:
  [ .kimi.data[]
    | {
        id: .id,
        title: (.display_name // .id),
        context_length: (.context_length // .limit.context // 0),
        # kimi не сообщает лимит вывода
        max_output_tokens: 0,
        vision: (.supports_image_in // false),
        tools: (.supports_dynamic_tools // .tools.dynamic_load // false),
        reasoning: kimi_reasoning,
      }
  ]
  | sort_by(.id) | reverse;

def kimi_groups:
  [ model_group("Kimi"; [kimi_models[] | model_info(.reasoning)]) ];

# ── Файл ─────────────────────────────────────────────────────────────────────

def render:
"//// СГЕНЕРИРОВАННЫЙ ФАЙЛ — руками не править.
////
//// Источники: modeles.txt (veai), kimi_models.txt (kimi)
//// Обновление:  ./scripts/gen_catalog.sh
////
//// Каталог вкомпилирован в приложение: на рантайме запросов за списком
//// моделей нет. Актуализация — перегенерацией этого файла.

import shared/types.{
  type Provider, AlwaysReasoning, ModelGroup, ModelInfo, NoReasoning,
  OptionalReasoning, Provider,
}

/// Все известные провайдеры с их моделями.
pub fn providers() -> List(Provider) {
  [
" + provider("veai"; "VeAI"; "Anthropic/sonnet-5"; veai_groups) + "
" + provider("kimi"; "Kimi"; "k3.1-pro"; kimi_groups) + "
  ]
}
";

{ veai: $veai[0], kimi: $kimi[0] } | render
