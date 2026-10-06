/// The session modes the phone offers, and the sheet that picks one.
///
/// A "mode" is DSH's agent preset. The ids travel on the wire; the labels do not, so
/// the phone carries the desktop's own copy — these tests pin the roster (ids,
/// order, wording) and the create path that sends the chosen id.
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/api/relay_client.dart';
import 'package:dsh_remote_app/chat/presets.dart';
import 'package:dsh_remote_app/state/app_controller.dart';
import 'package:dsh_remote_app/state/providers.dart';
import 'package:dsh_remote_app/state/settings.dart';
import 'package:dsh_remote_app/theme.dart';
import 'package:dsh_remote_app/ui/app_drawer.dart';
import 'package:dsh_remote_app/ui/new_session_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what a create call carried, and answers with a session id.
class CreateClient extends RelayClient {
  CreateClient()
      : super(
          baseUrl: 'https://relay.invalid',
          token: 'test-token',
          httpClient: HttpClient(),
        );

  final List<String?> presets = [];
  final List<String?> workspaces = [];
  bool failNext = false;

  @override
  Future<RelayHealth> health() async =>
      const RelayHealth(status: 'ok', version: 'test', protocol: 1, devicesOnline: 1);

  @override
  Future<List<RelayDevice>> devices() async => const [];

  @override
  Future<List<SessionSummary>> sessions(String deviceId, {bool includeArchived = false}) async => const [];

  @override
  Future<List<ApprovalAsk>> pendingApprovals() async => const [];

  @override
  Stream<FollowFrame> follow(String deviceId, String sessionId, {int maxMessages = 40}) =>
      const Stream<FollowFrame>.empty();

  @override
  Future<Map<String, dynamic>> createSession(
    String deviceId, {
    String? cwd,
    String? agentPreset,
  }) async {
    presets.add(agentPreset);
    workspaces.add(cwd);
    if (failNext) {
      throw const RelayException('remote_error', 'agent-preset/not-found: Unknown agent preset: x');
    }
    return {'sessionId': 'session-new', 'agentPreset': agentPreset ?? ''};
  }
}

Future<(AppController, CreateClient)> pumpSheet(
  WidgetTester tester, {
  String initialPreset = '',
}) async {
  final client = CreateClient();
  final controller = AppController(clientFactory: (baseUrl, token) => client);
  await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
  controller.state = controller.state.copyWith(activeDeviceId: 'device-1');

  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => NewSessionSheet(initialPreset: initialPreset)
                    .showSheetForTest(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (controller, client);
}

void main() {
  group('the preset roster', () {
    test('is the four DSH ships, in the desktop\'s order', () {
      expect(kBuiltInPresets.map((preset) => preset.id).toList(),
          ['standard', 'ptc', 'minimal', 'cordis']);
      expect(kBuiltInPresets.map((preset) => preset.label).toList(),
          ['标准模式', 'PTC 模式', '极简模式', '创造模式']);
      // The mode the user called "RTC" is PTC — DSH has never shipped an `rtc`.
      expect(kBuiltInPresets.any((preset) => preset.id == 'rtc'), isFalse);
    });

    test('every mode explains itself', () {
      for (final preset in kBuiltInPresets) {
        expect(preset.description.trim(), isNotEmpty, reason: preset.id);
      }
    });

    test('a known id resolves to the desktop copy', () {
      expect(presetById('minimal').label, '极简模式');
      expect(presetLabel('cordis'), '创造模式');
      expect(presetLabel(''), '');
    });

    test('an unknown id keeps whatever the harness calls it', () {
      // A user-authored preset publishes a `name`; one that does not still gets its
      // id shown rather than a made-up label.
      expect(presetById('my-preset', name: '我的模式').label, '我的模式');
      expect(presetById('my-preset').label, 'my-preset');
      expect(presetById('my-preset').description, contains('my-preset'));
    });
  });

  group('the new-task sheet', () {
    testWidgets('offers all four modes, pre-selecting the last one used', (tester) async {
      await pumpSheet(tester, initialPreset: 'minimal');

      for (final preset in kBuiltInPresets) {
        expect(find.text(preset.label), findsOneWidget, reason: preset.id);
      }
      expect(find.text('模式'), findsOneWidget);
      expect(find.text('工作目录'), findsOneWidget);
      expect(find.text('创建任务'), findsOneWidget);

      // Pre-selected: creating straight away must use the remembered mode.
      await tester.tap(find.text('创建任务'));
      await tester.pumpAndSettle();
    });

    testWidgets('creating sends the chosen preset', (tester) async {
      final (_, client) = await pumpSheet(tester);

      await tester.tap(find.text('极简模式'));
      await tester.pump();
      await tester.tap(find.text('创建任务'));
      await tester.pumpAndSettle();

      expect(client.presets, ['minimal']);
      expect(client.workspaces.length, 1);
    });

    testWidgets('an untouched sheet creates with the shipped default', (tester) async {
      final (_, client) = await pumpSheet(tester);

      await tester.tap(find.text('创建任务'));
      await tester.pumpAndSettle();

      expect(client.presets, [kDefaultPresetId]);
    });

    testWidgets('the mode reached the controller state, for prompts typed elsewhere',
        (tester) async {
      final (controller, _) = await pumpSheet(tester);

      await tester.tap(find.text('PTC 模式'));
      await tester.pump();
      await tester.tap(find.text('创建任务'));
      await tester.pumpAndSettle();

      // A prompt typed on the welcome screen creates the session itself; it must not
      // quietly fall back to the harness default.
      expect(controller.state.agentPreset, 'ptc');
    });

    testWidgets('a failure keeps the sheet open and says why', (tester) async {
      final (_, client) = await pumpSheet(tester);
      client.failNext = true;

      await tester.tap(find.text('创建任务'));
      await tester.pumpAndSettle();

      expect(find.text('创建任务'), findsOneWidget, reason: 'the sheet must stay usable');
      expect(find.textContaining('agent-preset/not-found'), findsOneWidget);
    });
  });

  group('the drawer', () {
    testWidgets('new task opens the sheet instead of creating at once', (tester) async {
      final client = CreateClient();
      final controller = AppController(clientFactory: (baseUrl, token) => client);
      await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
      controller.state = controller.state.copyWith(activeDeviceId: 'device-1');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => controller)],
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const Scaffold(body: AppDrawer()),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('新建任务'));
      await tester.pumpAndSettle();

      expect(client.presets, isEmpty, reason: 'nothing is created until the user says so');
      expect(find.text('创建任务'), findsOneWidget);
      expect(find.text('创造模式'), findsOneWidget);
    });
  });
}

/// Opens the sheet the way the drawer does, from a plain test button.
extension on NewSessionSheet {
  Future<void> showSheetForTest(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => this,
    );
  }
}
