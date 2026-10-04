/// Settings and diagnostics: what the app is connected to, and what it trusts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/relay_events.dart';
import '../state/providers.dart';
import '../theme.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final state = ref.watch(appControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _Section(
            title: '中继',
            children: [
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('地址'),
                subtitle: SelectableText(settings.baseUrl.isEmpty ? '未设置' : settings.baseUrl),
              ),
              ListTile(
                leading: Icon(
                  state.relayReachable ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                  color: state.relayReachable ? AppColors.online : AppColors.offline,
                ),
                title: Text(state.relayReachable ? '可达' : '不可达'),
                subtitle: Text(
                  state.health == null
                      ? (state.error ?? '尚未探测')
                      : 'v${state.health!.version} · 协议 v${state.health!.protocol} · '
                          '${state.health!.devicesOnline} 台桌面在线',
                ),
                trailing: IconButton(
                  tooltip: '重新探测',
                  onPressed: () => ref.read(appControllerProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh),
                ),
              ),
              ListTile(
                leading: Icon(_eventsIcon(state.eventsState)),
                title: const Text('事件通道'),
                subtitle: Text(
                  state.eventsError.isEmpty
                      ? _eventsLabel(state.eventsState)
                      : '${_eventsLabel(state.eventsState)}\n${state.eventsError}',
                ),
                isThreeLine: state.eventsError.isNotEmpty,
              ),
            ],
          ),

          _Section(
            title: '信任',
            children: [
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('内置 CA 指纹（SHA-256）'),
                subtitle: SelectableText(
                  state.caFingerprint.isEmpty ? '尚未加载' : state.caFingerprint,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  '中继用的是内部 CA 签发的证书，系统信任库里没有它。这个指纹应当与 '
                  'certs/ca.crt 一致；不一致说明安装包里的 CA 被换过。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),

          _Section(
            title: '这台手机',
            children: [
              ListTile(
                leading: const Icon(Icons.phone_android),
                title: const Text('设备名称'),
                subtitle: Text(settings.deviceName),
              ),
              ListTile(
                leading: const Icon(Icons.vpn_key_outlined),
                title: const Text('设备令牌'),
                subtitle: Text(settings.token.isEmpty
                    ? '无'
                    : '已保存（${settings.token.length} 字符，只存在 Keystore 里）'),
              ),
              ListTile(
                leading: Icon(Icons.logout, color: theme.colorScheme.error),
                title: Text('退出并清除令牌', style: TextStyle(color: theme.colorScheme.error)),
                subtitle: const Text('只是本机清除；要真正作废请在服务器上 revoke-device'),
                onTap: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('清除本机令牌？'),
                      content: const Text(
                        '清除后需要重新配对。\n'
                        '注意：这只影响这台手机。令牌在中继上仍然有效，'
                        '如需作废请在服务器执行 revoke-device。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('清除'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await ref.read(settingsProvider.notifier).signOut();
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'DSH Remote 0.1.0 · 协议 v1\n'
              '会话内容不落盘在这台手机上；审批永远需要你明确作答。',
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  static IconData _eventsIcon(RelayEventsState state) => switch (state) {
        RelayEventsState.connected => Icons.bolt,
        RelayEventsState.connecting => Icons.bolt_outlined,
        RelayEventsState.idle => Icons.bolt_outlined,
        RelayEventsState.stopped => Icons.bolt_outlined,
      };

  static String _eventsLabel(RelayEventsState state) => switch (state) {
        RelayEventsState.connected => '已连接（审批与状态实时推送）',
        RelayEventsState.connecting => '连接中…',
        RelayEventsState.idle => '断开，正在退避重连',
        RelayEventsState.stopped => '已停止',
      };
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          ...children,
        ],
      ),
    );
  }
}
