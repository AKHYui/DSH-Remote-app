/// Archiving, from the phone.
///
/// The archived set lives in the Host's **Workspace registry**, not on the Session, so
/// three things have to hold: archived rows stay out of the ordinary list (showing one
/// as a live conversation was a real bug), they are reachable in their own section, and
/// archiving never kills a running turn without being asked.
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/api/relay_client.dart';
import 'package:dsh_remote_app/state/app_controller.dart';
import 'package:dsh_remote_app/state/providers.dart';
import 'package:dsh_remote_app/state/settings.dart';
import 'package:dsh_remote_app/theme.dart';
import 'package:dsh_remote_app/ui/app_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary session(
  String id, {
  String title = '',
  bool archived = false,
  bool blank = false,
  bool subagent = false,
  int updated = 1,
}) =>
    SessionSummary(
      sessionId: id,
      running: false,
      agentAvailable: true,
      blank: blank,
      updatedAt: updated,
      asOfSeq: 10,
      title: title,
      archived: archived,
      isSubagent: subagent,
    );

/// Answers `session.list` with an archived set the test controls, and records the two
/// archive calls — including whether they carried `stopActivity`.
class ArchiveClient extends RelayClient {
  ArchiveClient({this.refuseWhileRunning = false})
      : super(
          baseUrl: 'https://relay.invalid',
          token: 'test-token',
          httpClient: HttpClient(),
        );

  /// When true, a plain archive call fails the way the Host refuses a busy session.
  bool refuseWhileRunning;

  /// A failure that is *not* the busy-session refusal — the two must be told apart
  /// rather than both being read as "ask about stopping work".
  bool archiveFailsHard = false;

  final List<({String sessionId, bool stopActivity})> archiveCalls = [];
  final List<String> unarchiveCalls = [];
  int listCalls = 0;
  bool archiveFails = false;

  @override
  Future<RelayHealth> health() async =>
      const RelayHealth(status: 'ok', version: 'test', protocol: 1, devicesOnline: 1);

  @override
  Future<List<RelayDevice>> devices() async => const [];

  @override
  Future<List<SessionSummary>> sessions(String deviceId, {bool includeArchived = false}) async {
    listCalls += 1;
    return [
      session('session-live', title: '在用的任务'),
      if (includeArchived) session('session-archived', title: '收起来的任务', archived: true),
    ];
  }

  @override
  Future<List<ApprovalAsk>> pendingApprovals() async => const [];

  @override
  Stream<FollowFrame> follow(String deviceId, String sessionId, {int maxMessages = 40}) =>
      const Stream<FollowFrame>.empty();

  @override
  Future<Set<String>> archiveSession(
    String deviceId, {
    required String sessionId,
    bool stopActivity = false,
  }) async {
    archiveCalls.add((sessionId: sessionId, stopActivity: stopActivity));
    if (archiveFailsHard) {
      throw const RelayException('remote_error', 'workspace/not-found: no such session');
    }
    if (archiveFails || (refuseWhileRunning && !stopActivity)) {
      throw const RelayException('remote_error', 'workspace/session-active: work in flight');
    }
    return {'session-archived', sessionId};
  }

  @override
  Future<Set<String>> unarchiveSession(String deviceId, {required String sessionId}) async {
    unarchiveCalls.add(sessionId);
    return <String>{};
  }
}

Future<(AppController, ArchiveClient)> pumpDrawer(
  WidgetTester tester, {
  bool refuseWhileRunning = false,
}) async {
  final client = ArchiveClient(refuseWhileRunning: refuseWhileRunning);
  final controller = AppController(clientFactory: (baseUrl, token) => client);
  await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
  controller.state = controller.state.copyWith(activeDeviceId: 'device-1');
  await controller.loadSessions();

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
  await tester.pump(const Duration(milliseconds: 50));
  return (controller, client);
}

void main() {
  group('which lists a session appears in', () {
    test('an archived row is kept by the transport but hidden from ordinary lists', () {
      // The bug this pins: the *client* filtered archived rows out entirely, so the
      // controller never saw them and the archived section stayed empty — while every
      // test that stubbed `sessions()` passed, because the stubs bypassed the very
      // layer that was doing the filtering.
      final all = [
        session('a', title: '在用'),
        session('b', title: '收起来', archived: true),
        session('c', title: '空任务', blank: true),
      ];

      expect(listedSessions(all).map((s) => s.sessionId), ['a', 'b'],
          reason: 'what a list read hands on — archived rows included');
      expect(visibleSessions(all).map((s) => s.sessionId), ['a'],
          reason: 'what a group or a recent chip may show');
      expect(archivedSessions(all).map((s) => s.sessionId), ['b']);
    });

    test('a subagent or blank row is dropped even when it is archived', () {
      final all = [
        session('live'),
        session('archived', archived: true),
        session('subagent-archived', archived: true, subagent: true),
        session('blank-archived', archived: true, blank: true),
      ];

      expect(listedSessions(all).map((s) => s.sessionId), ['live', 'archived']);
      expect(archivedSessions(all).map((s) => s.sessionId), ['archived'],
          reason: 'archiving residue must not make it visible');
    });

    test('a row is marked archived from the set the list reports beside it', () {
      // The archived set is not on the row: the Workspace registry reports it beside
      // the list, and the client marks the rows it names.
      final marked = SessionSummary.fromJson(
        {
          'sessionId': 'session-x',
          'running': false,
          'agentAvailable': true,
          'blank': false,
          'updatedAt': 1,
        },
        archived: true,
      );

      expect(marked.archived, isTrue);
      expect(SessionSummary.fromJson({'sessionId': 'session-y'}).archived, isFalse);
    });

    test('archived sessions come back newest first', () {
      final archived = archivedSessions([
        session('old', archived: true, updated: 10),
        session('new', archived: true, updated: 30),
        session('mid', archived: true, updated: 20),
      ]);
      expect(archived.map((s) => s.sessionId), ['new', 'mid', 'old']);
    });
  });

  group('the archive call', () {
    testWidgets('a plain archive never asks to stop work', (tester) async {
      final (controller, client) = await pumpDrawer(tester);

      final outcome = await controller.archiveSession('session-live');

      expect(outcome.isOk, isTrue);
      expect(client.archiveCalls.single.stopActivity, isFalse);
    });

    testWidgets('a busy session is reported, not killed', (tester) async {
      final (controller, client) = await pumpDrawer(tester, refuseWhileRunning: true);

      final first = await controller.archiveSession('session-live');
      expect(first.kind, ArchiveOutcomeKind.workRunning);
      expect(client.archiveCalls.single.stopActivity, isFalse,
          reason: 'the first attempt must never stop anything on its own');

      final second = await controller.archiveSession('session-live', stopActivity: true);
      expect(second.isOk, isTrue);
      expect(client.archiveCalls.last.stopActivity, isTrue);
    });

    testWidgets('a real failure keeps its message', (tester) async {
      final (controller, client) = await pumpDrawer(tester);
      client.archiveFailsHard = true;

      final outcome = await controller.archiveSession('session-live');

      expect(outcome.kind, ArchiveOutcomeKind.failed);
      expect(outcome.message, contains('not-found'));
    });

    testWidgets('unarchiving calls the unarchive op and reloads the list', (tester) async {
      final (controller, client) = await pumpDrawer(tester);
      final before = client.listCalls;

      final outcome = await controller.unarchiveSession('session-archived');

      expect(outcome.isOk, isTrue);
      expect(client.unarchiveCalls, ['session-archived']);
      expect(client.listCalls, greaterThan(before),
          reason: 'the registry is the authority, so the list is re-read');
    });
  });

  group('the drawer', () {
    testWidgets('archived sessions live in their own collapsed section', (tester) async {
      await pumpDrawer(tester);

      expect(find.text('在用的任务'), findsOneWidget);
      expect(find.text('已归档 1'), findsOneWidget);
      expect(find.text('收起来的任务'), findsNothing, reason: 'collapsed until asked for');

      await tester.tap(find.text('已归档 1'));
      await tester.pump();
      expect(find.text('收起来的任务'), findsOneWidget);
    });

    testWidgets('a long press offers archiving, and confirming archives it', (tester) async {
      final (_, client) = await pumpDrawer(tester);

      await tester.longPress(find.text('在用的任务'));
      await tester.pumpAndSettle();
      expect(find.text('归档'), findsOneWidget);

      await tester.tap(find.text('归档'));
      await tester.pumpAndSettle();

      expect(client.archiveCalls.single.sessionId, 'session-live');
      expect(client.archiveCalls.single.stopActivity, isFalse);
    });

    testWidgets('an archived row offers to come back', (tester) async {
      final (_, client) = await pumpDrawer(tester);

      await tester.tap(find.text('已归档 1'));
      await tester.pump();
      await tester.longPress(find.text('收起来的任务'));
      await tester.pumpAndSettle();

      expect(find.text('取消归档'), findsOneWidget);
      await tester.tap(find.text('取消归档'));
      await tester.pumpAndSettle();

      expect(client.unarchiveCalls, ['session-archived']);
    });

    testWidgets('a busy session is confirmed before anything is stopped', (tester) async {
      final (_, client) = await pumpDrawer(tester, refuseWhileRunning: true);

      await tester.longPress(find.text('在用的任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('归档'));
      await tester.pumpAndSettle();

      // The first call was refused, which is what raises the question.
      expect(find.text('这个任务还在运行'), findsOneWidget);
      expect(client.archiveCalls.single.stopActivity, isFalse);

      await tester.tap(find.text('停掉并归档'));
      await tester.pumpAndSettle();

      expect(client.archiveCalls.last.stopActivity, isTrue);
    });

    testWidgets('declining the question stops there', (tester) async {
      final (_, client) = await pumpDrawer(tester, refuseWhileRunning: true);

      await tester.longPress(find.text('在用的任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('归档'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(client.archiveCalls.length, 1, reason: 'nothing was stopped');
      expect(client.archiveCalls.single.stopActivity, isFalse);
    });
  });
}
