/// The status line above the composer.
///
/// The numbers come from DSH's session projections, which the opening follow
/// snapshot carries. This pins the wording the phone shows and that tapping it
/// reveals the breakdown — the line itself is deliberately terse.
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/api/relay_client.dart';
import 'package:dsh_remote_app/state/app_controller.dart';
import 'package:dsh_remote_app/state/providers.dart';
import 'package:dsh_remote_app/state/settings.dart';
import 'package:dsh_remote_app/theme.dart';
import 'package:dsh_remote_app/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// One live-shaped projection block, matching what the harness sends.
Map<String, dynamic> projectionBlock({int asOfSeq = 5152}) => {
      'kind': 'sequenced',
      'asOfSeq': asOfSeq,
      'values': {
        'title': '任务用量测试',
        'sessionStats': {
          'turns': 15,
          'steps': 847,
          'decodeTokens': 569836,
          'decodeMs': 2288904,
        },
        'tokenUsage': {
          'uncachedInputTokens': 2475515,
          'outputTokens': 569836,
          'cacheReadTokens': 319141248,
          'cacheWriteTokens': 0,
        },
        'contextPressure': {
          'pressureTokens': 338750,
          'projectedTokens': 340182,
          'contextWindow': 1000000,
        },
      },
    };

class MetricsClient extends RelayClient {
  MetricsClient({this.projections})
      : super(
          baseUrl: 'https://relay.invalid',
          // A real client always has one, and the periodic poll — which is what
          // keeps the numbers moving — stands down without it.
          token: 'test-token',
          httpClient: HttpClient(),
        );

  /// Null models a harness that sends no projection block at all.
  final Map<String, dynamic>? projections;

  /// How many times the task list was read — the status line's live path.
  int sessionCalls = 0;

  /// Whether the list row says a turn is running, which is what arms the refresh.
  bool running = false;

  /// Steps the fake list reports, advanced on every read so a refresh is visible.
  int steps = 847;

  final _frames = StreamController<FollowFrame>.broadcast();

  @override
  Future<RelayHealth> health() async =>
      const RelayHealth(status: 'ok', version: 'test', protocol: 1, devicesOnline: 1);

  @override
  Future<List<RelayDevice>> devices() async => const [];

  @override
  Future<List<SessionSummary>> sessions(String deviceId, {bool includeArchived = false}) async {
    sessionCalls += 1;
    // The desktop kept working while the phone was not looking.
    steps += 1;
    return [
      SessionSummary(
        sessionId: 'session-1',
        running: running,
        agentAvailable: true,
        blank: false,
        updatedAt: 1791082274000,
        // A watermark above the snapshot's, so it wins as the fresher reading.
        asOfSeq: 6000 + sessionCalls,
        title: '任务用量测试',
        metrics: SessionMetrics.fromProjections({
          'asOfSeq': 6000 + sessionCalls,
          'values': {
            'sessionStats': {
              'turns': 15,
              'steps': steps,
              'decodeTokens': 569836,
              'decodeMs': 2288904,
            },
            'tokenUsage': {
              'uncachedInputTokens': 2475515,
              'outputTokens': 569836,
              'cacheReadTokens': 319141248,
              'cacheWriteTokens': 0,
            },
            'contextPressure': {
              'pressureTokens': 338750,
              'projectedTokens': 340182,
              'contextWindow': 1000000,
            },
          },
        }),
      ),
    ];
  }

  @override
  Future<List<ApprovalAsk>> pendingApprovals() async => const [];

  @override
  Stream<FollowFrame> follow(String deviceId, String sessionId, {int maxMessages = 40}) {
    scheduleMicrotask(() {
      if (_frames.isClosed) return;
      _frames.add(FollowFrame(
        kind: 'snapshot',
        raw: {
          'type': 'snapshot',
          'cursor': 5152,
          'header': {'id': sessionId},
          'records': const [],
          'hasMore': false,
          if (projections != null) 'projections': projections,
        },
      ));
    });
    return _frames.stream;
  }

  /// Delivers one live session event, the way a healthy stream would.
  void pushEvent(String type, int seq, Map<String, dynamic> data) {
    if (_frames.isClosed) return;
    _frames.add(FollowFrame(
      kind: 'event',
      raw: {
        'type': 'event',
        'event': {'type': type, 'seq': seq, 'time': 0, 'data': data},
      },
    ));
  }

  @override
  void close() {
    unawaited(_frames.close());
    super.close();
  }
}

Future<AppController> pumpSession(
  WidgetTester tester,
  MetricsClient client, {
  bool running = false,
  bool withSummaryMetrics = false,
  String preset = '',
  String permission = '',
}) async {
  final controller = AppController(clientFactory: (baseUrl, token) => client);
  await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
  client.running = running;
  controller.state = controller.state.copyWith(
    activeDeviceId: 'device-1',
    activeSessionId: 'session-1',
    sessions: [
      SessionSummary(
        sessionId: 'session-1',
        running: running,
        agentAvailable: true,
        blank: false,
        updatedAt: 1791082274000,
        asOfSeq: 5152,
        title: '任务用量测试',
        agentPreset: preset,
        permission: permission,
        metrics: withSummaryMetrics
            ? SessionMetrics.fromProjections(projectionBlock())
            : null,
      ),
    ],
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

void main() {
  testWidgets('the line shows the desktop numbers the snapshot carried', (tester) async {
    await pumpSession(tester, MetricsClient(projections: projectionBlock()));

    expect(
      find.text('15 轮 847 步 · 249 tok/s · 322M tok · 缓存命中 99% · 已用上下文 34%'),
      findsOneWidget,
    );
  });

  testWidgets('tapping the line opens the breakdown', (tester) async {
    await pumpSession(tester, MetricsClient(projections: projectionBlock()));

    await tester.tap(find.textContaining('tok/s'));
    await tester.pumpAndSettle();

    expect(find.text('任务用量'), findsOneWidget);
    expect(find.text('轮次 / 步骤'), findsOneWidget);
    expect(find.text('15 / 847'), findsOneWidget);
    expect(find.textContaining('缓存读 / 写'), findsOneWidget);
    expect(find.text('缓存命中'), findsOneWidget);
    expect(find.textContaining('340K / 1M'), findsOneWidget);
  });

  testWidgets('a session with no numbers shows no line at all', (tester) async {
    // Neither the snapshot nor the list row carries a projection: better to draw
    // nothing than a row of zeros.
    await pumpSession(tester, MetricsClient());

    expect(find.textContaining('tok/s'), findsNothing);
    expect(find.textContaining('轮 '), findsNothing);
  });

  testWidgets('the numbers keep arriving while a turn runs', (tester) async {
    // The desktop reads these from a live projection stream. The phone has them at
    // every (re)subscribe, and re-reads the list while a turn is running — without
    // that, a finished turn looks like it never counted.
    final client = MetricsClient(projections: projectionBlock());
    await pumpSession(tester, client, running: true);
    expect(find.textContaining('847 步'), findsOneWidget);

    final callsBefore = client.sessionCalls;
    await tester.pump(const Duration(seconds: 16)); // one poll tick
    await tester.pump(const Duration(milliseconds: 50));

    expect(client.sessionCalls, greaterThan(callsBefore));
    expect(
      find.textContaining('848 步'),
      findsOneWidget,
      reason: 'the newer reading must reach the line, not just the network',
    );
  });

  testWidgets('an idle session is not re-read on every tick', (tester) async {
    final client = MetricsClient(projections: projectionBlock());
    await pumpSession(tester, client);

    final callsBefore = client.sessionCalls;
    await tester.pump(const Duration(seconds: 31));
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      client.sessionCalls,
      callsBefore,
      reason: 'nothing is moving, so there is nothing to re-read',
    );
  });

  testWidgets('the breakdown also says the mode and who can be asked for approval',
      (tester) async {
    final client = MetricsClient(projections: projectionBlock());
    await pumpSession(tester, client, preset: 'cordis', permission: 'danger-full-access');

    await tester.tap(find.textContaining('tok/s'));
    await tester.pumpAndSettle();

    expect(find.text('模式'), findsOneWidget);
    expect(find.text('创造模式'), findsOneWidget);
    expect(find.text('权限'), findsOneWidget);
    // The dangerous combination is spelled out rather than hidden behind a code.
    expect(find.text('完全访问'), findsOneWidget);
  });

  testWidgets('a settled step refreshes the numbers without waiting for the poll',
      (tester) async {
    // The projections do not ride the stream, so the view has to ask. It asks when a
    // step settles, which is exactly when the desktop's counters move.
    final client = MetricsClient(projections: projectionBlock());
    await pumpSession(tester, client, running: true);
    expect(find.textContaining('847 步'), findsOneWidget);

    final callsBefore = client.sessionCalls;
    client.pushEvent('step/end', 9001, {'turn': 15, 'step': 848});
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 50));

    expect(client.sessionCalls, greaterThan(callsBefore));
    expect(find.textContaining('848 步'), findsOneWidget);
  });

  testWidgets('the list row alone still shows the numbers', (tester) async {
    // A session opened with no stream (a reload, or a harness that sends no
    // projection block) still has its numbers in the list row.
    await pumpSession(tester, MetricsClient(), withSummaryMetrics: true);

    expect(
      find.text('15 轮 847 步 · 249 tok/s · 322M tok · 缓存命中 99% · 已用上下文 34%'),
      findsOneWidget,
    );
  });
}
