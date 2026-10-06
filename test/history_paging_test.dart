/// Scrolling back through a conversation's history.
///
/// A follow snapshot is bounded by bytes, not just by `maxMessages` — one long turn
/// can fill the whole window, and a real page measured 52 records for a requested
/// 60 — so the oldest record the app holds is usually *not* the beginning of the
/// task. Without paging, the top of the list was simply the end of the memory the
/// app had, which is what "再往上划就看不到更以前的历史记录了" was.
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
import 'package:dsh_remote_app/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SessionEvent user(int seq, String text) => SessionEvent(
      sessionId: 'session-1',
      seq: seq,
      type: 'user/message',
      time: 0,
      data: {
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'user'},
      },
    );

SessionEvent assistant(int seq, String text) => SessionEvent(
      sessionId: 'session-1',
      seq: seq,
      type: 'assistant/message',
      time: 0,
      data: {
        'message': {
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      },
    );

Map<String, dynamic> recordOf(SessionEvent event) => {
      'type': 'event',
      'event': {
        'type': event.type,
        'seq': event.seq,
        'time': event.time,
        'data': event.data,
      },
    };

/// A transport that serves one snapshot and then pages of older records, the way
/// `session.page` does.
class PagingClient extends RelayClient {
  PagingClient({required this.snapshot, required this.hasMore, required this.older})
      : super(baseUrl: 'https://relay.invalid', httpClient: HttpClient());

  final List<SessionEvent> snapshot;
  final bool hasMore;
  final List<SessionEvent> older;

  int pageCalls = 0;
  int? lastBeforeSeq;
  int? lastThroughSeq;

  final _frames = StreamController<FollowFrame>.broadcast();

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
  Stream<FollowFrame> follow(String deviceId, String sessionId, {int maxMessages = 40}) {
    scheduleMicrotask(() {
      if (_frames.isClosed) return;
      _frames.add(FollowFrame(
        kind: 'snapshot',
        raw: {
          'type': 'snapshot',
          'cursor': snapshot.isEmpty ? 0 : snapshot.last.seq,
          'header': {'id': sessionId},
          'records': [for (final event in snapshot) recordOf(event)],
          'hasMore': hasMore,
        },
      ));
    });
    return _frames.stream;
  }

  @override
  Future<Map<String, dynamic>> page(
    String deviceId,
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 30,
  }) async {
    pageCalls += 1;
    lastBeforeSeq = beforeSeq;
    lastThroughSeq = throughSeq;
    return {
      'records': [for (final event in older) recordOf(event)],
      'hasMore': false,
    };
  }

  @override
  void close() {
    unawaited(_frames.close());
    super.close();
  }
}

Future<void> pumpView(WidgetTester tester, PagingClient client) async {
  final controller = AppController(clientFactory: (baseUrl, token) => client);
  await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
  controller.state = controller.state.copyWith(
    activeDeviceId: 'device-1',
    activeSessionId: 'session-1',
    sessions: const [
      SessionSummary(
        sessionId: 'session-1',
        running: false,
        agentAvailable: true,
        blank: false,
        updatedAt: 1791082274000,
        asOfSeq: 79,
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
}

/// Scrolls to the conversation's older end — the top of the screen in a reversed
/// list — and lets any fetch settle.
Future<void> scrollToOlder(WidgetTester tester) async {
  final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

void main() {
  group('Transcript.prependOlder', () {
    test('older records land in front, and the window tracks its own edge', () {
      final transcript = Transcript();
      transcript.applySnapshot([user(50, '五零'), assistant(51, '五一')], hasMore: true);
      expect(transcript.oldestSeq, 50);
      expect(transcript.hasOlder, isTrue);
      expect(transcript.loadedCount, 2);

      final added = transcript.prependOlder([user(48, '四八'), assistant(49, '四九')],
          hasMore: false);

      expect(added, 2);
      expect(transcript.oldestSeq, 48);
      expect(transcript.hasOlder, isFalse);
      expect(transcript.loadedCount, 4);
      // Oldest first: the list is built in this order.
      final texts = transcript.items.map((item) => switch (item) {
            UserBubble(:final text) => text,
            AssistantBubble(:final text) => text,
            _ => '?',
          });
      expect(texts, ['四八', '四九', '五零', '五一']);
    });

    test('a record already loaded is not added twice', () {
      final transcript = Transcript();
      transcript.applySnapshot([user(50, '五零'), assistant(51, '五一')], hasMore: true);

      // A page whose cursor overlapped what is already on screen.
      final added = transcript.prependOlder([assistant(51, '五一')], hasMore: true);

      expect(added, 0);
      expect(transcript.loadedCount, 2);
      expect(transcript.hasOlder, isTrue);
    });

    test('records newer than the window are ignored — the live stream owns them', () {
      final transcript = Transcript();
      transcript.applySnapshot([user(50, '五零')], hasMore: true);

      final added = transcript.prependOlder([assistant(51, '五一'), user(49, '四九')],
          hasMore: false);

      expect(added, 1);
      expect(transcript.oldestSeq, 49);
      expect(transcript.loadedCount, 2);
    });

    test('an unconfirmed echo survives a rebuild triggered by an older page', () {
      final transcript = Transcript();
      transcript.applySnapshot([user(50, '五零')], hasMore: true);
      transcript.applyLocalUserMessage('刚发出的', requestId: 'app-1');

      transcript.prependOlder([user(49, '四九')], hasMore: false);

      expect(
        transcript.items.whereType<PendingUserBubble>().map((item) => item.text),
        ['刚发出的'],
      );
      expect(transcript.oldestSeq, 49);
    });

    test('clear() forgets the window so a new session starts empty', () {
      final transcript = Transcript();
      transcript.applySnapshot([user(50, '五零')], hasMore: true);
      transcript.clear();

      expect(transcript.loadedCount, 0);
      expect(transcript.oldestSeq, 0);
      expect(transcript.hasOlder, isFalse);
      expect(transcript.items, isEmpty);
    });
  });

  testWidgets('scrolling back fetches the previous page and shows it', (tester) async {
    // A window that starts mid-conversation, which is what a byte-bounded snapshot
    // looks like from the app's side.
    final client = PagingClient(
      snapshot: [
        for (var seq = 50; seq <= 79; seq++)
          seq.isEven ? user(seq, '历史消息 $seq') : assistant(seq, '回复 $seq'),
      ],
      hasMore: true,
      older: [user(48, '更早的用户消息'), assistant(49, '更早的回复')],
    );
    await pumpView(tester, client);
    expect(client.pageCalls, 0, reason: 'nothing is fetched until the user scrolls back');

    await scrollToOlder(tester);

    expect(client.pageCalls, 1);
    expect(client.lastBeforeSeq, 50, reason: 'the page must start before the oldest record held');
    expect(client.lastThroughSeq, 49);

    // The fetched page is inserted above the viewport; scroll on to reach it.
    await scrollToOlder(tester);
    expect(find.text('更早的回复'), findsOneWidget);
    expect(find.text('已经到开头了'), findsOneWidget);

    // Fetch again: with `hasMore: false` the app must stop asking, however hard the
    // user pulls.
    await scrollToOlder(tester);
    await scrollToOlder(tester);
    expect(client.pageCalls, 1);
  });

  testWidgets('a complete snapshot never pages', (tester) async {
    final client = PagingClient(
      snapshot: [
        for (var seq = 50; seq <= 79; seq++)
          seq.isEven ? user(seq, '历史消息 $seq') : assistant(seq, '回复 $seq'),
      ],
      hasMore: false,
      older: const [],
    );
    await pumpView(tester, client);

    await scrollToOlder(tester);
    await scrollToOlder(tester);

    expect(client.pageCalls, 0, reason: 'hasMore: false means the desktop has nothing older');
    expect(find.text('已经到开头了'), findsOneWidget);
  });
}
