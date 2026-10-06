/// The session modes DSH ships, as the phone presents them.
///
/// A "mode" is an **agent preset**. DSH declares four — `standard`, `ptc`,
/// `minimal`, `cordis` — and the ids travel on the wire (`session.create`'s
/// `agentPreset`). The *labels do not*: the preset declarations carry no `name`, so
/// DSH's own desktop client keeps an id → copy table and translates it. The phone
/// does the same, with the desktop's wording, rather than inventing names for
/// presets the harness never named.
///
/// A user-authored preset *does* publish a `name`, and [presetById] prefers what the
/// harness says over anything invented here.
library;

class SessionPreset {
  const SessionPreset({
    required this.id,
    required this.label,
    required this.description,
  });

  /// The wire value for `session.create`'s `agentPreset`.
  final String id;

  /// What the desktop calls this mode.
  final String label;

  /// One line, from the desktop's own description.
  final String description;
}

/// The built-in presets, in the order the desktop lists them (`order` 1…4).
const List<SessionPreset> kBuiltInPresets = [
  SessionPreset(
    id: 'standard',
    label: '标准模式',
    description: '处理代码、文件和资料，适合大多数任务。Agent 会按需使用检索、编辑和终端等工具。',
  ),
  SessionPreset(
    id: 'ptc',
    label: 'PTC 模式',
    description: '包含标准模式的所有能力，更适合批量调用工具，并对结果进行筛选、整理、去重、统计或汇总的任务。',
  ),
  SessionPreset(
    id: 'minimal',
    label: '极简模式',
    description: 'Agent 仅使用终端工具完成任务，适合测试和对比其基础表现。',
  ),
  SessionPreset(
    id: 'cordis',
    label: '创造模式',
    description: '用对话定制 DSH：让 Agent 编写插件，添加新功能或界面；也能组合工具和提示词，创建自己的模式。',
  ),
];

/// What a new task uses when the user does not choose: DSH's shipped default.
const String kDefaultPresetId = 'standard';

/// The preset an id refers to.
///
/// Known ids get the desktop's copy. Anything else — a preset the user wrote, or one
/// a future DSH adds — is shown under the name the harness published, and failing
/// that under its raw id: a mode the app cannot name is still a mode the user chose,
/// and hiding or renaming it would be worse than showing what it calls itself.
SessionPreset presetById(String id, {String name = ''}) {
  for (final preset in kBuiltInPresets) {
    if (preset.id == id) return preset;
  }
  final shown = name.trim().isNotEmpty ? name.trim() : id;
  return SessionPreset(
    id: id,
    label: shown,
    description: id.isEmpty ? '' : '由这份 DSH 提供：$id',
  );
}

/// The label for an id, for places that only need the name.
String presetLabel(String id, {String name = ''}) =>
    id.isEmpty ? '' : presetById(id, name: name).label;
