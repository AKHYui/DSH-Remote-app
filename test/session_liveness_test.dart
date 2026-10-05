/// How the app notices a follow stream that died without saying so.
///
/// `session.follow` is a long-lived HTTP response. A half-open one delivers nothing
/// and reports nothing — no error, no end — so a reader waits forever: the reported
/// symptom was "the desktop had already finished answering, but the phone was still
/// spinning, until I restarted the app or switched sessions".
///
/// The app has a *second* channel that does police itself (the event socket closes
/// after 55s of silence), and it carries `session.activity` / `session.status` for
/// every session. These tests drive that signal and the fallback watchdog, and use a
/// transport that yields its snapshot and then goes quiet forever — exactly the
/// failure mode.
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

/// A transport whose follow stream delivers one snapshot and then never speaks
/// again, while counting how many times it was asked to open a stream.
class SilentFollowClient extends RelayClient {
  SilentFollowClient({this.snapshot = const []})
      : super(baseUrl: 'https://relay.invalid', httpClient: HttpClient());

  final List<SessionEvent> snapshot;
  int followCalls = 0;
  int sessionListCalls = 0;
  final List<String> prompts = [];

  final _frames = StreamController<FollowFrame>.broadcast();

  @override
  Future<RelayHealth> health() async =>
      const RelayHealth(status: 'ok', version: 'test', protocol: 1, devicesOnline: 1);

  @override
  Future<List<RelayDevice>> devices() async => const [];

  @override
  Future<List<SessionSummary>> sessions(String deviceId) async {
    sessionListCalls += 1;
    return const [
      SessionSummary(
        sessionId: 'session-1',
        running: false,
        agentAvailable: true,
        blank: false,
        updatedAt: 1791082274000,
        asOfSeq: 99,
      ),
    ];
  }

  @override
  Future<ModelCatalog> modelCatalog(String deviceId) async =>
      const ModelCatalog(groups: []);

  @override
  Future<List<ApprovalAsk>> pendingApprovals() async => const [];

  @override
  Stream<FollowFrame> follow(String deviceId, String sessionId, {int maxMessages = 40}) {
    followCalls += 1;
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
      _frames.add(FollowFrame(
        kind: 'snapshot',
        raw: {'type': 'snapshot', 'cursor': 99, 'header': {'id': sessionId}, 'records': records},
      ));
    });
    // Broadcast and never completed: this is the half-open case.
    return _frames.stream;
  }

  /// Delivers one live event, the way a healthy stream would. Only used to prove
  /// that a confirmed message stops the recovery watchdog.
  void pushEvent(SessionEvent event) {
    if (_frames.isClosed) return;
    _frames.add(FollowFrame(
      kind: 'event',
      raw: {
        'type': 'event',
        'event': {
          'type': event.type,
          'seq': event.seq,
          'time': 0,
          'data': event.data,
        },
      },
    ));
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

Future<AppController> pumpSession(WidgetTester tester, SilentFollowClient client) async {
  final controller = AppController(clientFactory: (baseUrl, token) => client);
  await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
  controller.state = controller.state.copyWith(
    activeDeviceId: 'device-1',
    sessions: const [
      SessionSummary(
        sessionId: 'session-1',
        running: false,
        agentAvailable: true,
        blank: false,
        updatedAt: 1791082274000,
        asOfSeq: 99,
      ),
    ],
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

/// One `session.activity` frame, exactly as the relay delivers it.
RelayEvent activityFor(String sessionId) => RelayEvent(
      topic: 'session.activity',
      deviceId: 'device-1',
      payload: {'kind': 'activity', 'sessionId': sessionId, 'updatedAt': 1791082274000},
    );

void main() {
  testWidgets('a quiet session is left alone, however long it is idle', (tester) async {
    final client = SilentFollowClient();
    await pumpSession(tester, client);
    expect(client.followCalls, 1);

    // Silence alone is not evidence: no desktop activity means nothing is missing.
    await tester.pump(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 60));
    expect(client.followCalls, 1, reason: 'an idle conversation must not be re-opened on a timer');
  });

  testWidgets('activity for the open session re-opens a silent stream', (tester) async {
    final client = SilentFollowClient();
    final controller = await pumpSession(tester, client);
    expect(client.followCalls, 1);

    // The desktop moved, but the follow stream said nothing for 10s: stale.
    final listCallsBefore = client.sessionListCalls;
    await tester.pump(const Duration(seconds: 11));
    controller.handleEvent(activityFor('session-1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      client.followCalls,
      2,
      reason: 'the app must recover the stream instead of waiting for a restart',
    );
    // And the task list is re-read too: it, not the stream, carries the running
    // flag behind the composer's spinner.
    expect(client.sessionListCalls, greaterThan(listCallsBefore));
  });

  testWidgets('activity for another session is ignored', (tester) async {
    final client = SilentFollowClient();
    final controller = await pumpSession(tester, client);

    await tester.pump(const Duration(seconds: 11));
    controller.handleEvent(activityFor('session-other'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(client.followCalls, 1);
  });

  testWidgets('a nudge right after traffic is not treated as staleness', (tester) async {
    final client = SilentFollowClient();
    final controller = await pumpSession(tester, client);

    // The snapshot just arrived, so the socket speaking up proves nothing — and a
    // busy session sends these constantly.
    controller.handleEvent(activityFor('session-1'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(client.followCalls, 1);
  });

  testWidgets('an unconfirmed message re-opens the stream even with no other signal', (tester) async {
    // Both channels dead (a network change, a suspended app): nothing will nudge
    // the app, and the sender's own message is the only evidence left that the
    // desktop might have answered.
    final client = SilentFollowClient();
    await pumpSession(tester, client);

    await tester.enterText(find.byType(TextField), '在吗');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(client.prompts, hasLength(1), reason: 'the prompt must have been accepted');
    expect(find.text('已发出，等电脑确认…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 20));
    expect(
      client.followCalls,
      greaterThan(1),
      reason: 'an unconfirmed message must not sit behind a dead stream',
    );

    // Once the durable event arrives the echo is confirmed, and the watchdog has
    // nothing left to ask about.
    client.pushEvent(event('user/message', 5, {
      'content': [
        {'type': 'text', 'text': '在吗'},
      ],
      'source': {'kind': 'user', 'rpcId': client.prompts.single},
    }));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已发出，等电脑确认…'), findsNothing, reason: 'the echo was confirmed');

    final callsAfterConfirmation = client.followCalls;
    await tester.pump(const Duration(seconds: 90));
    await tester.pump(const Duration(seconds: 90));
    expect(
      client.followCalls,
      callsAfterConfirmation,
      reason: 'a confirmed conversation must stop being re-opened',
    );
  });

  test('the controller turns activity frames into signals, and keeps them distinct', () {
    final controller = AppController();
    addTearDown(controller.dispose);

    expect(controller.state.lastSignal, isNull);

    controller.handleEvent(activityFor('session-1'));
    final first = controller.state.lastSignal;
    expect(first?.sessionId, 'session-1');

    controller.handleEvent(activityFor('session-1'));
    final second = controller.state.lastSignal;
    expect(second?.sessionId, 'session-1');
    // Two nudges for the same session must not compare equal, or a consumer that
    // diffs state would drop the second one.
    expect(identical(first, second), isFalse);
    expect(second!.tick, greaterThan(first!.tick));

    // A frame with no session id says nothing about any conversation.
    controller.handleEvent(
      const RelayEvent(topic: 'session.activity', deviceId: 'device-1', payload: {}),
    );
    expect(identical(controller.state.lastSignal, second), isTrue);
  });
}
