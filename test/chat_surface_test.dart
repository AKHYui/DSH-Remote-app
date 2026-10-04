/// What the conversation actually looks like on the phone.
///
/// Three answers the user asked for, all of which are *visual* and therefore not
/// covered by the transcript unit tests:
///
///   * the turn the user just sent shows up immediately, marked as unconfirmed;
///   * it carries a green rail, so it cannot be confused with anything the
///     harness wrote;
///   * harness-injected context (`agent-message`, `model-selection`, …) is one
///     collapsed line instead of a full grey bubble.
///
/// A fake [RelayClient] stands in for the transport, so nothing here needs a
/// relay or a device.
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/api/relay_client.dart';
import 'package:dsh_remote_app/chat/transcript.dart';
import 'package:dsh_remote_app/state/app_controller.dart';
import 'package:dsh_remote_app/state/providers.dart';
import 'package:dsh_remote_app/state/settings.dart';
import 'package:dsh_remote_app/theme.dart';
import 'package:dsh_remote_app/ui/app_drawer.dart';
import 'package:dsh_remote_app/ui/home_screen.dart';
import 'package:dsh_remote_app/ui/markdown_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers from canned data; never opens a socket.
class ChatFakeClient extends RelayClient {
  ChatFakeClient({this.snapshot = const []})
      : super(baseUrl: 'https://relay.invalid', httpClient: HttpClient());

  /// What the follow stream's opening snapshot carries.
  final List<SessionEvent> snapshot;

  /// The request ids of the prompts that reached the transport.
  final List<String> prompts = [];

  final _frames = StreamController<FollowFrame>.broadcast();

  @override
  Future<RelayHealth> health() async => const RelayHealth(
        status: 'ok',
        version: 'test',
        protocol: 1,
        devicesOnline: 1,
      );

  @override
  Future<List<RelayDevice>> devices() async => const [];

  /// How many times the task list was asked for. Opening the drawer is one of
  /// them, which `opening the drawer reloads the task list` pins down.
  int sessionCalls = 0;

  @override
  Future<List<SessionSummary>> sessions(String deviceId) async {
    sessionCalls += 1;
    return const [];
  }

  @override
  Future<ModelCatalog> modelCatalog(String deviceId) async =>
      const ModelCatalog(groups: []);

  @override
  Future<List<ApprovalAsk>> pendingApprovals() async => const [];

  @override
  Stream<FollowFrame> follow(String deviceId, String sessionId, {int maxMessages = 40}) {
    final records = [
      for (final event in snapshot)
        {
          'type': 'event',
          'event': {
            'type': event.type,
            'seq': event.seq,
            'time': 0,
            'data': event.data,
          },
        },
    ];
    scheduleMicrotask(() {
      if (_frames.isClosed) return;
      _frames.add(
        FollowFrame(
          kind: 'snapshot',
          raw: {'type': 'snapshot', 'cursor': 99, 'header': {'id': sessionId}, 'records': records},
        ),
      );
    });
    return _frames.stream;
  }

  @override
  Future<Map<String, dynamic>> prompt(
    String deviceId,
    String sessionId,
    List<Map<String, dynamic>> content, {
    String mode = 'queue',
    String? requestId,
  }) async {
    prompts.add(requestId ?? '');
    return const {'accepted': true};
  }

  @override
  void close() {
    unawaited(_frames.close());
    super.close();
  }
}

SessionEvent event(String type, int seq, Map<String, dynamic> data) =>
    SessionEvent(sessionId: 'session-1', seq: seq, type: type, time: 0, data: data);

const sessionSummary = SessionSummary(
  sessionId: 'session-1',
  running: false,
  agentAvailable: true,
  blank: false,
  updatedAt: 1791082274000,
  asOfSeq: 99,
  title: '手机上的对话',
);

/// Pumps one `SessionView` over [client] and waits for its snapshot.
Future<AppController> pumpSession(WidgetTester tester, ChatFakeClient client) async {
  final controller = AppController(clientFactory: (baseUrl, token) => client);
  // Riverpod owns the notifier handed to `overrideWith` and disposes it when the
  // scope goes away, so the test must not do it a second time.
  await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
  controller.state = controller.state.copyWith(
    activeDeviceId: 'device-1',
    sessions: const [sessionSummary],
    activeSessionId: 'session-1',
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(body: SessionView(sessionId: 'session-1')),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return controller;
}

/// Every border drawn in the tree, for asserting on the user bubble's rail.
List<Border> bordersIn(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .map((container) => container.decoration)
    .whereType<BoxDecoration>()
    .map((decoration) => decoration.border)
    .whereType<Border>()
    .toList(growable: false);

void main() {
  testWidgets('opening the drawer reloads the task list', (tester) async {
    // The list used to be loaded only on connect and after actions, so a
    // conversation archived on the desktop while the app was open stayed visible —
    // which reads as "archived conversations still show up in the app".
    final client = ChatFakeClient();
    final controller = AppController(clientFactory: (baseUrl, token) => client);
    await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
    controller.state = controller.state.copyWith(activeDeviceId: 'device-1');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final before = client.sessionCalls;

    await tester.tap(find.byTooltip('菜单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      client.sessionCalls,
      greaterThan(before),
      reason: 'the drawer must refresh the list it is about to show',
    );
  });

  testWidgets('the drawer carries no "real-time" badge any more', (tester) async {
    // The badge was a permanently-on green dot. The connection state itself is
    // still reported, as a sentence, on the settings screen — so this asserts the
    // decoration is gone without losing the information.
    final client = ChatFakeClient();
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

    expect(find.text('DSH Remote'), findsOneWidget);
    expect(find.text('实时'), findsNothing);
    expect(find.text('连接中'), findsNothing);
    expect(find.text('重连中'), findsNothing);
  });

  testWidgets('the turn just sent appears at once, with a green rail', (tester) async {
    final client = ChatFakeClient();
    await pumpSession(tester, client);

    await tester.enterText(find.byType(TextField), '这是手机上发的');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 1. Visible without waiting for the follow stream.
    expect(find.text('这是手机上发的'), findsOneWidget);
    // 2. And honest about not being confirmed yet.
    expect(find.text('已发出，等电脑确认…'), findsOneWidget);
    // 3. The rail is the app's green accent, thick enough to read at phone width.
    final rail = bordersIn(tester).where((border) => border.left.color == AppColors.accent);
    expect(rail, isNotEmpty, reason: 'the user bubble should carry a green left rail');
    expect(rail.first.left.width, greaterThanOrEqualTo(3));
    expect(client.prompts, hasLength(1));
  });

  testWidgets('the durable event replaces the echo, spinner and caption gone', (tester) async {
    final client = ChatFakeClient();
    final controller = await pumpSession(tester, client);

    await tester.enterText(find.byType(TextField), '确认一下');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已发出，等电脑确认…'), findsOneWidget);

    // The same prompt comes back from the durable log, carrying the rpcId the
    // app sent — which is exactly what DSH records as `source.rpcId`.
    final transcript = Transcript();
    expect(controller.client, same(client));
    transcript
      ..applyLocalUserMessage('确认一下', requestId: client.prompts.single)
      ..applyEvent(event('user/message', 1, {
        'content': [
          {'type': 'text', 'text': '确认一下'},
        ],
        'source': {'kind': 'user', 'rpcId': client.prompts.single},
      }));

    expect(transcript.items.whereType<PendingUserBubble>(), isEmpty);
    expect(transcript.items.whereType<UserBubble>(), hasLength(1));
    expect(find.text('确认一下'), findsOneWidget);
  });

  testWidgets('a delivery shows which artifacts exist, never their contents', (tester) async {
    final client = ChatFakeClient(snapshot: [
      event('deliverables/presented', 1, {
        'turn': 3,
        'callId': 'call-1',
        'files': [
          {
            'path': r'D:\dsh-remote-bridge\app\build\app\outputs\flutter-apk\app-release.apk',
            'description': '新的 release 包（0.1.1+2）',
          },
          {
            'path': r'D:\dsh-remote-bridge\app\test\goldens\transcript_fixes.png',
            'description': 'golden：对话流现在的样子',
          },
        ],
      }),
    ]);
    await pumpSession(tester, client);

    expect(find.text('产物 · 2 个文件'), findsOneWidget);
    // Which files, and what each one is for.
    expect(find.text('app-release.apk'), findsOneWidget);
    expect(find.text('transcript_fixes.png'), findsOneWidget);
    expect(find.text('新的 release 包（0.1.1+2）'), findsOneWidget);
    // The folder is shown too: two same-named builds are otherwise identical.
    expect(
      find.textContaining(r'app\build\app\outputs\flutter-apk'),
      findsOneWidget,
    );
  });

  testWidgets('a long delivery folds to four rows and expands on tap', (tester) async {
    final client = ChatFakeClient(snapshot: [
      event('deliverables/presented', 1, {
        'turn': 1,
        'callId': 'call-1',
        'files': [
          for (var index = 1; index <= 6; index += 1)
            {'path': 'build/out-$index.bin', 'description': '文件 $index'},
        ],
      }),
    ]);
    await pumpSession(tester, client);

    expect(find.text('产物 · 6 个文件'), findsOneWidget);
    expect(find.text('out-1.bin'), findsOneWidget);
    expect(find.text('out-4.bin'), findsOneWidget);
    expect(find.text('out-5.bin'), findsNothing, reason: 'the fifth row is folded away');
    expect(find.text('展开全部'), findsOneWidget);

    await tester.tap(find.text('产物 · 6 个文件'));
    await tester.pump();
    expect(find.text('out-6.bin'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('harness-injected context is one collapsed line', (tester) async {    final client = ChatFakeClient(snapshot: [
      event('user/message', 1, {
        'content': [
          {'type': 'text', 'text': '我发的那句'},
        ],
        'source': {'kind': 'user', 'rpcId': 'app-1'},
      }),
      event('user/message', 2, {
        'content': [
          {
            'type': 'text',
            'text': 'Agent b7e08bc2-f153-46c1-b201-e5b917fe7651 sent a message: '
                'I finished the README and left the notes in plugin/README.md.',
          },
        ],
        'source': {
          'kind': 'agent-message',
          'form': 'relay',
          'senderSessionId': 'b7e08bc2-f153-46c1-b201-e5b917fe7651',
        },
      }),
    ]);
    await pumpSession(tester, client);

    // The human's turn is a bubble with a rail; the agent message is a folded row.
    expect(find.text('我发的那句'), findsOneWidget);
    expect(find.textContaining('子代理消息'), findsOneWidget);
    // Named, so it is obvious which agent wrote it...
    expect(find.textContaining('b7e08bc2'), findsOneWidget);
    // ...but the `Agent <uuid> sent a message:` framing is gone from the preview:
    // that string is precisely what the user asked to stop reading.
    expect(find.textContaining('sent a message'), findsNothing);

    // Collapsed: no markdown body, and the preview is clamped to one line.
    expect(find.byType(MarkdownOrPlain), findsNothing);
    final preview = tester.widget<Text>(
      find.textContaining('I finished the README'),
    );
    expect(preview.maxLines, 1);
    expect(preview.overflow, TextOverflow.ellipsis);

    // Tapping opens it, framing and all.
    await tester.tap(find.textContaining('子代理消息'));
    await tester.pump();
    expect(find.byType(MarkdownOrPlain), findsOneWidget);
    expect(find.textContaining('sent a message'), findsOneWidget);
  });

  testWidgets('golden: the conversation as it now renders', (tester) async {
    final client = ChatFakeClient(snapshot: [
      event('assistant/message', 1, {
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': '收到，我先看看这个仓库。'},
          ],
        },
      }),
      event('user/message', 2, {
        'content': [
          {'type': 'text', 'text': '帮我把 app 的聊天界面整理一下'},
        ],
        'source': {'kind': 'user', 'rpcId': 'app-2'},
      }),
      event('user/message', 3, {
        'content': [
          {'type': 'text', 'text': 'model changed: deepseek-account/deepseek-flash → fastai/gpt-5.6-terra'},
        ],
        'source': {'kind': 'model-selection', 'form': 'notice'},
      }),
      event('assistant/message', 4, {
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': '好，我看一下 `transcript.dart` 和气泡的样式。'},
          ],
        },
      }),
      event('deliverables/presented', 5, {
        'turn': 1,
        'callId': 'call-1',
        'files': [
          {
            'path': r'D:\dsh-remote-bridge\app\build\app\outputs\flutter-apk\app-release.apk',
            'description': '新的 release 包（0.1.1+2）',
          },
          {
            'path': r'D:\dsh-remote-bridge\app\test\goldens\transcript_fixes.png',
            'description': 'golden：对话流现在的样子',
          },
        ],
      }),
    ]);
    await pumpSession(tester, client);
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(SessionView),
      matchesGoldenFile('goldens/transcript_fixes.png'),
    );
  });
}
