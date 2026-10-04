/// The navigation drawer: device at the top, workspaces and their sessions in
/// the middle, settings pinned to the bottom.
///
/// Everything that used to live on its own screen (device list, session list)
/// is here now, because the main screen is the conversation — the reference app
/// works the same way, and it saves a navigation level on every switch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../state/app_controller.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'settings_screen.dart';

class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);

    return Drawer(
      width: MediaQuery.of(context).size.width * 0.84,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DeviceHeader(state: state, onTap: () => _pickDevice(context, ref, state)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppGap.page),
              child: _NewTaskButton(
                busy: state.creatingSession,
                onTap: () async {
                  Navigator.of(context).pop();
                  final id = await controller.createSession();
                  if (id == null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(state.sessionsError ?? '无法新建会话')),
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: AppGap.base),
            const Divider(height: 1),
            _SectionLabel(
              label: '任务',
              trailing: state.sessionsLoading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onRefresh: controller.loadSessions,
            ),
            Expanded(child: _SessionList(state: state)),
            const Divider(height: 1),
            _DrawerFooter(state: state),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDevice(BuildContext context, WidgetRef ref, AppState state) async {
    if (state.devices.isEmpty) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetGrabber(),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppGap.page, 4, AppGap.page, 8),
              child: Text('选择设备', style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final device in state.devices)
              ListTile(
                leading: _StatusDot(online: device.online),
                title: Text(device.name.isEmpty ? device.id : device.name),
                subtitle: Text(
                  device.online
                      ? '在线 · ${device.platform}${device.harnessVersion.isEmpty ? '' : ' · harness ${device.harnessVersion}'}'
                      : '离线',
                ),
                trailing: device.id == state.activeDeviceId
                    ? const Icon(Icons.check_rounded, color: AppColors.accent, size: 20)
                    : null,
                onTap: () => Navigator.of(context).pop(device.id),
              ),
            const SizedBox(height: AppGap.base),
          ],
        ),
      ),
    );
    if (chosen != null) {
      await ref.read(appControllerProvider.notifier).selectDevice(chosen);
    }
  }
}

class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceMutedStrong,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Top of the drawer: which desktop we are driving.
class _DeviceHeader extends StatelessWidget {
  const _DeviceHeader({required this.state, required this.onTap});

  final AppState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final device = state.activeDevice;

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppGap.page, AppGap.base, AppGap.page, AppGap.base),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.primaryAction,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.terminal_rounded, size: 17, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Text('DSH Remote', style: theme.textTheme.titleSmall),
              const Spacer(),
            ],
          ),
          const SizedBox(height: AppGap.base),
          Material(
            color: AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(AppRadius.full),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.full),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(
                  children: [
                    _StatusDot(online: device?.online ?? false),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device == null
                                ? '没有可用设备'
                                : (device.name.isEmpty ? device.id : device.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            device == null
                                ? '在电脑上启动 DSH'
                                : (device.online ? '在线 · 可远程执行' : '离线'),
                            style: theme.textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.unfold_more_rounded,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NewTaskButton extends StatelessWidget {
  const _NewTaskButton({required this.onTap, required this.busy});

  final Future<void> Function() onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.timeline),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.timeline),
        onTap: busy ? null : () => onTap(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            children: [
              busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_rounded, size: 20, color: AppColors.textPrimary),
              const SizedBox(width: 10),
              Text(
                '新建任务',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.trailing, this.onRefresh});

  final String label;
  final Widget? trailing;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppGap.page, 14, 8, 4),
      child: Row(
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
          if (onRefresh != null)
            IconButton(
              tooltip: '刷新',
              onPressed: () => onRefresh!(),
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded, color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }
}

/// Workspaces, each with its sessions beneath.
class _SessionList extends ConsumerWidget {
  const _SessionList({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    if (state.sessionsError != null) {
      return Padding(
        padding: const EdgeInsets.all(AppGap.page),
        child: Text(
          state.sessionsError!,
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.danger),
        ),
      );
    }
    if (state.sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppGap.loose),
          child: Text(
            state.sessionsLoading ? '正在读取任务…' : '这个设备还没有任务',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }

    final workspaces = state.workspaces;
    return ListView(
      padding: const EdgeInsets.only(bottom: AppGap.base),
      children: [
        for (final group in workspaces) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppGap.page + 10, 12, AppGap.page, 4),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined, size: 13, color: AppColors.textTertiary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final session in group.sessions)
            _SessionTile(session: session, selected: session.sessionId == state.activeSessionId),
        ],
      ],
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session, required this.selected});

  final SessionSummary session;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: selected ? AppColors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.timeline),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.timeline),
          onTap: () {
            ref.read(appControllerProvider.notifier).openSession(session.sessionId);
            Navigator.of(context).pop();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            child: Row(
              children: [
                if (session.running)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: _StatusDot(online: true),
                  ),
                Expanded(
                  child: Text(
                    session.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: selected ? AppColors.accentText : AppColors.textPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_ago(session.updatedAtTime), style: theme.textTheme.labelSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _ago(DateTime? when) {
    if (when == null) return '';
    final delta = DateTime.now().difference(when);
    if (delta.isNegative || delta.inMinutes < 1) return '刚刚';
    if (delta.inHours < 1) return '${delta.inMinutes}m';
    if (delta.inDays < 1) return '${delta.inHours}h';
    return '${delta.inDays}d';
  }
}

class _DrawerFooter extends ConsumerWidget {
  const _DrawerFooter({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final relay = state.health;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.settings_outlined, size: 20),
          title: const Text('设置', style: TextStyle(fontSize: 15)),
          trailing: const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textTertiary),
          onTap: () {
            Navigator.of(context).pop();
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppGap.page + 16, 0, AppGap.page, 12),
          child: Text(
            relay == null
                ? (state.error ?? '中继不可达')
                : '中继 v${relay.version} · 协议 v${relay.protocol}',
            style: theme.textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}

/// Green when connected, amber while reconnecting, grey when stopped.
///
/// The drawer used to carry this as a "● 实时" badge in its top-right corner. It
/// was removed at the user's request: a permanently-on dot is decoration, and the
/// real state — including *why* it is not connected — is on the settings screen,
/// where it is phrased as a sentence (`已连接（审批与状态实时推送）` / `断开，正在退避重连`).
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: online ? AppColors.online : AppColors.offline,
        shape: BoxShape.circle,
      ),
    );
  }
}
