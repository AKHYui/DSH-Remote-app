/// Creating a task: which mode, in which directory.
///
/// The drawer's new-task button used to create a session immediately, with no say in
/// how it would run. DSH has four agent presets — 标准 / PTC / 极简 / 创造 — and the
/// phone could not pick one, even though `session.create` has always accepted
/// `agentPreset`. This is that choice, plus the working directory, in one sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/presets.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'workspace_sheet.dart';

/// Opens the new-task sheet. Returns the created session id, or null if cancelled.
///
/// [onCreated] is called after a successful create so the caller can persist the
/// choice. The sheet itself deliberately does not touch the settings store: that
/// makes it testable without a keystore, and keeps "remember this" the caller's
/// business.
Future<String?> showNewSessionSheet(
  BuildContext context, {
  required String initialPreset,
  void Function(String presetId)? onCreated,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    // Four modes with descriptions plus the directory row is taller than the
    // default sheet height on a phone.
    isScrollControlled: true,
    builder: (_) => NewSessionSheet(initialPreset: initialPreset, onCreated: onCreated),
  );
}

class NewSessionSheet extends ConsumerStatefulWidget {
  const NewSessionSheet({super.key, required this.initialPreset, this.onCreated});

  /// Last mode used (or empty for the shipped default), pre-selected.
  final String initialPreset;

  /// Called with the chosen mode once a task has been created.
  final void Function(String presetId)? onCreated;

  @override
  ConsumerState<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends ConsumerState<NewSessionSheet> {
  late String _preset = widget.initialPreset.isEmpty
      ? kDefaultPresetId
      : widget.initialPreset;
  bool _creating = false;

  Future<void> _create() async {
    if (_creating) return;
    setState(() => _creating = true);
    final controller = ref.read(appControllerProvider.notifier);
    final sessionId = await controller.createSession(agentPreset: _preset);
    if (!mounted) return;
    if (sessionId == null) {
      setState(() => _creating = false);
      // The controller keeps the reason on its own state; show it here so the sheet
      // does not just sit there.
      final reason = ref.read(appControllerProvider).sessionsError ?? '无法新建任务。';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reason)));
      return;
    }
    // App state carries the mode for prompts typed on the welcome screen, which
    // create the session themselves; the caller persists it for next time.
    controller.setAgentPreset(_preset);
    widget.onCreated?.call(_preset);
    Navigator.of(context).pop(sessionId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workspace = ref.watch(appControllerProvider).workspace;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppGap.page, 0, AppGap.page, AppGap.base),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('新建任务', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              Text('模式', style: theme.textTheme.labelSmall),
              const SizedBox(height: 4),
              for (final preset in kBuiltInPresets)
                _PresetTile(
                  preset: preset,
                  selected: preset.id == _preset,
                  onTap: _creating ? null : () => setState(() => _preset = preset.id),
                ),
              const SizedBox(height: 12),
              Text('工作目录', style: theme.textTheme.labelSmall),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  workspace.isEmpty ? Icons.auto_awesome_outlined : Icons.folder_outlined,
                  size: 20,
                ),
                title: Text(
                  workspace.isEmpty ? '让 Harness 自己决定' : workspace,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  workspace.isEmpty ? '不指定工作目录' : '新任务将在这个目录下运行',
                  style: theme.textTheme.labelSmall,
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                onTap: _creating ? null : () => showWorkspaceSheet(context, ref),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _creating ? null : _create,
                child: _creating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('创建任务'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({required this.preset, required this.selected, required this.onTap});

  final SessionPreset preset;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        preset.label,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: Text(preset.description, style: theme.textTheme.labelSmall),
      trailing: selected
          ? const Icon(Icons.check_rounded, color: AppColors.accent, size: 20)
          : null,
      onTap: onTap,
    );
  }
}
