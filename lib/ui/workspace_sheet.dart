/// Picking the working directory a new task will run in.
///
/// Lifted out of the welcome screen so the new-task sheet offers the same choice
/// with the same wording — two pickers would drift, and the drawer's new-task button
/// had no way to change the directory at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme.dart';

Future<void> showWorkspaceSheet(BuildContext context, WidgetRef ref) async {
  final state = ref.read(appControllerProvider);
  final chosen = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppGap.page, 0, AppGap.page, 8),
              child: Text('新任务在哪个工作区运行？', style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined, size: 20),
              title: const Text('让 Harness 自己决定'),
              subtitle: const Text('不指定工作目录'),
              trailing: state.workspace.isEmpty
                  ? const Icon(Icons.check_rounded, color: AppColors.accent, size: 20)
                  : null,
              onTap: () => Navigator.of(context).pop(''),
            ),
            for (final group in state.workspaces)
              ListTile(
                leading: const Icon(Icons.folder_outlined, size: 20),
                title: Text(group.label),
                subtitle: Text(group.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: group.path == state.workspace
                    ? const Icon(Icons.check_rounded, color: AppColors.accent, size: 20)
                    : null,
                onTap: () => Navigator.of(context).pop(group.path),
              ),
            const SizedBox(height: AppGap.base),
          ],
        ),
      ),
    ),
  );
  if (chosen != null) {
    ref.read(appControllerProvider.notifier).setWorkspace(chosen);
  }
}
