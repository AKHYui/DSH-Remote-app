/// The permission mode a session runs under, as the phone shows it.
///
/// It lives in `projections.values.permissions.currentValue` — the same block the
/// usage numbers come from — so display costs nothing and needs no new op. DSH's
/// preset is a pair of knobs (a sandbox mode and an approval policy); the presets
/// that pair them up are these, plus a derived `custom` for a combination that no
/// preset produces.
///
/// Worth showing rather than hiding: `danger-full-access` also sets the approval
/// policy to `never`, so a session running under it will never ask the phone to
/// approve anything — which is exactly the sort of thing the person holding the
/// phone should be able to see.
library;

class PermissionPreset {
  const PermissionPreset({
    required this.value,
    required this.label,
    required this.description,
  });

  /// The wire value in `permissions.currentValue`.
  final String value;
  final String label;
  final String description;
}

/// The selectable presets, weakest first.
const List<PermissionPreset> kPermissionPresets = [
  PermissionPreset(
    value: 'read-only',
    label: '只读',
    description: '可以看，不能改',
  ),
  PermissionPreset(
    value: 'workspace-write',
    label: '可写工作区',
    description: '可改工作目录内的文件',
  ),
  PermissionPreset(
    value: 'danger-full-access',
    label: '完全访问',
    description: '文件系统全开，且该会话不再请求审批',
  ),
];

/// A note for the two values that are not in the list above.
const String kCustomPermissionLabel = '自定义';
const String kCustomPermissionDescription = '沙箱与审批的组合不属于任何预设';

/// Display copy for a `permissions.currentValue`.
PermissionPreset permissionByValue(String value) {
  for (final preset in kPermissionPresets) {
    if (preset.value == value) return preset;
  }
  if (value == 'custom') {
    return const PermissionPreset(
      value: 'custom',
      label: kCustomPermissionLabel,
      description: kCustomPermissionDescription,
    );
  }
  // An unknown value is still shown as itself: the phone does not get to rename a
  // mode it does not know, and a blank here would read as "no permissions set".
  return PermissionPreset(value: value, label: value, description: '由这份 DSH 报告');
}

/// Whether a session under this mode still asks the phone for approvals.
///
/// Only `danger-full-access` turns them off; anything unrecognised is assumed to
/// ask, because guessing "no approvals" the wrong way is the dangerous direction.
bool permissionAsksForApproval(String value) => value != 'danger-full-access';

String permissionLabel(String value) => value.isEmpty ? '' : permissionByValue(value).label;
