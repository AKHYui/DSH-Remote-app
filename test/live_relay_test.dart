/// Exercises the app's real client layer against a live relay.
///
/// This is not a mock test. It drives the same `RelayClient` the UI uses against
/// the deployed relay, so the HTTP paths, SSE framing, error mapping and model
/// parsing are verified before the app ever runs on a device. The equivalent
/// check on the plugin side is what caught the `_request` argument bug.
///
/// It is skipped unless the environment says where to point it, because it needs
/// a live relay and a real token:
///
///   $env:DSH_LIVE_RELAY='https://relay.example.com:58443'
///   $env:DSH_LIVE_TOKEN='<device-token>'
///   $env:DSH_LIVE_CA='assets\ca.crt'          # optional; this is the default
///   flutter test test/live_relay_test.dart
///
/// `DSH_LIVE_CA` defaults to the bundled `assets/ca.crt`, so a self-hosted relay
/// with an internal CA works without setting it; point it elsewhere (or leave it
/// empty) for a relay whose certificate chains to a public CA.
///
/// Why a test rather than `dart run tool/live_check.dart`: a bare `dart run`
/// inside a Flutter package hangs resolving the Flutter SDK, while `flutter test`
/// already has a working environment. The cost is that `flutter_test` installs a
/// mock `HttpOverrides` to stop widget tests from touching the network, so this
/// file clears it first.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/api/relay_client.dart';
import 'package:dsh_remote_app/api/relay_events.dart';
import 'package:dsh_remote_app/api/tls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final baseUrl = Platform.environment['DSH_LIVE_RELAY'] ?? '';
  final token = Platform.environment['DSH_LIVE_TOKEN'] ?? '';
  // Defaults to the certificate this repository already ships for the app itself,
  // so the live checks work out of the box against a self-hosted relay. Set it to
  // an empty string for a relay with a publicly trusted certificate.
  final caPath = Platform.environment['DSH_LIVE_CA'] ?? 'assets/ca.crt';

  if (baseUrl.isEmpty || token.isEmpty) {
    test('live relay check', () {}, skip: 'set DSH_LIVE_RELAY and DSH_LIVE_TOKEN to run');
    return;
  }

  setUpAll(() {
    // Without this every request from a `flutter test` process is answered by a
    // mock client that returns 400.
    HttpOverrides.global = null;
  });

  late HttpClient http;
  late RelayClient client;

  setUp(() {
    final context = SecurityContext(withTrustedRoots: true);
    if (caPath.isNotEmpty && File(caPath).existsSync()) {
      context.setTrustedCertificatesBytes(File(caPath).readAsBytesSync());
    }
    http = HttpClient(context: context)..connectionTimeout = const Duration(seconds: 15);
    client = RelayClient(baseUrl: baseUrl, token: token, httpClient: http);
  });

  tearDown(() => client.close());

  test('healthz answers', () async {
    final health = await client.health();
    expect(health.status, 'ok');
    expect(health.protocol, 1);
  });

  test('a bogus token is refused as unauthorized', () async {
    final bogus = RelayClient(baseUrl: baseUrl, token: 'not-a-real-token', httpClient: http);
    await expectLater(
      bogus.devices(),
      throwsA(isA<RelayException>().having((e) => e.isAuthFailure, 'isAuthFailure', true)),
    );
  });

  test('the desktop list parses', () async {
    final devices = await client.devices();
    expect(devices, isNotEmpty, reason: 'the relay should know at least one desktop');
    for (final device in devices) {
      expect(device.id, isNotEmpty);
    }
  });

  test('a client rebuilt after the old one is closed still works', () async {
    // Regression: `IOClient.close()` closes the `HttpClient` it was handed, so
    // sharing one client between two RelayClients meant the second one was born
    // dead. Re-pairing in the app hit exactly this and showed
    // "Bad state: Client is closed" on a screen that had just claimed a token.
    final context = SecurityContext(withTrustedRoots: true);
    if (caPath.isNotEmpty && File(caPath).existsSync()) {
      context.setTrustedCertificatesBytes(File(caPath).readAsBytesSync());
    }

    final first = RelayClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: newRelayHttpClient(context),
    );
    expect(await first.devices(), isNotEmpty);
    first.close(); // what AppController._teardown() does to the previous client

    final second = RelayClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: newRelayHttpClient(context),
    );
    addTearDown(second.close);
    await expectLater(
      second.devices(),
      completes,
      reason: 'the replacement client must not inherit a closed HttpClient',
    );
  });

  test('the event socket connects and acknowledges a subscription', () async {
    // The HTTP/SSE paths were covered from the start, but the WebSocket path was
    // not — and it was silently broken in the app (the badge sat on
    // "reconnecting" forever) because the URL kept its https scheme.
    final context = SecurityContext(withTrustedRoots: true);
    if (caPath.isNotEmpty && File(caPath).existsSync()) {
      context.setTrustedCertificatesBytes(File(caPath).readAsBytesSync());
    }

    final events = RelayEvents(
      baseUrl: baseUrl,
      token: token,
      httpClient: newRelayHttpClient(context),
    );
    addTearDown(events.dispose);

    final reached = events.state
        .firstWhere((next) => next == RelayEventsState.connected)
        .timeout(const Duration(seconds: 20));
    await events.start();
    await expectLater(
      reached,
      completes,
      reason: 'the event socket should reach the connected state',
    );
    expect(events.currentState, RelayEventsState.connected);

    // Subscribing must not knock the socket over, and it should still be up a
    // few seconds later.
    events.subscribe('probe', 'home-pc', ['session.status', 'approval.ask']);
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(
      events.currentState,
      RelayEventsState.connected,
      reason: 'the socket should survive a subscribe',
    );
    expect(events.lastError, isEmpty, reason: 'no error should have been recorded');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the current model is readable and re-selectable', () async {
    final devices = await client.devices();
    final online = devices.where((device) => device.online).toList();
    if (online.isEmpty) {
      markTestSkipped('no desktop is online right now');
      return;
    }
    final desktop = online.first;

    final catalog = await client.modelCatalog(desktop.id);
    expect(catalog.groups, isNotEmpty, reason: 'the catalog should list providers');
    expect(
      catalog.groups.expand((group) => group.models),
      isNotEmpty,
      reason: 'providers should have models',
    );
    stdout.writeln(
      '        catalog: ${catalog.groups.length} provider(s), '
      '${catalog.groups.expand((g) => g.models).length} model(s)',
    );

    final sessions = await client.sessions(desktop.id);
    if (sessions.isEmpty) {
      markTestSkipped('the desktop has no sessions yet');
      return;
    }
    final session = sessions.first;
    final current = session.model;
    expect(
      current,
      isNotNull,
      reason: 'session.list projects modelSelection, so the UI needs no extra call',
    );
    stdout.writeln('        current model: ${current!.provider}/${current.model}');

    // Re-select the model the session is already on. This exercises the whole
    // path — relay allowlist, plugin op table, gateway descriptor validation —
    // without changing anything the user cares about.
    try {
      final selected = await client.selectModel(
        desktop.id,
        sessionId: session.sessionId,
        selection: current,
      );
      expect(selected, isNotNull);
      expect(selected!.provider, current.provider);
      expect(selected.model, current.model);
    } on RelayException catch (error) {
      if (error.code == 'op_not_supported') {
        // The plugin gained session.selectModel after the running instance was
        // started, and DSH only picks up plugin source on restart.
        markTestSkipped('restart DSH so the updated plugin loads session.selectModel');
        return;
      }
      rethrow;
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('ops, the allowlist and the stream work end to end', () async {
    final devices = await client.devices();
    final online = devices.where((device) => device.online).toList();
    if (online.isEmpty) {
      markTestSkipped('no desktop is online right now');
      return;
    }
    final desktop = online.first;

    final info = await client.op(desktop.id, 'harness.info');
    expect(info['deviceId'], desktop.id);

    final catalog = await client.modelCatalog(desktop.id);
    expect(catalog.groups, isNotEmpty);
    expect(catalog.defaultSelection, isNotNull);

    // The relay refuses anything outside its allowlist.
    await expectLater(
      client.op(desktop.id, 'terminal.create'),
      throwsA(isA<RelayException>().having((e) => e.code, 'code', 'op_not_supported')),
    );

    final sessions = await client.sessions(desktop.id);
    if (sessions.isEmpty) {
      markTestSkipped('the desktop has no sessions yet');
      return;
    }
    final session = sessions.first;
    final cursorPrecheck = session.asOfSeq;

    // History first: it is a plain request, and doing it before opening a stream
    // keeps a busy live session from delaying this assertion.
    if (cursorPrecheck > 0) {
      final page = await client
          .page(desktop.id, session.sessionId, throughSeq: cursorPrecheck, maxMessages: 3)
          .timeout(const Duration(seconds: 25));
      expect(page['records'], isA<List<dynamic>>());
      stdout.writeln('        session.page returned ${(page['records'] as List).length} record(s)');
    }

    // Then the stream. It is read with a hard deadline rather than by waiting for
    // the relay to go quiet: this session is live, so "quiet" may never happen.
    // Cancelling the subscription is deliberately not awaited — unwinding an SSE
    // socket mid-flight can take arbitrarily long and must not fail the test.
    final frames = <FollowFrame>[];
    var cursor = -1;
    final done = Completer<void>();
    late StreamSubscription<FollowFrame> subscription;
    final deadline = Timer(const Duration(seconds: 12), () {
      if (!done.isCompleted) done.complete();
    });

    subscription = client.follow(desktop.id, session.sessionId, maxMessages: 20).listen(
      (frame) {
        frames.add(frame);
        if (frame.kind == 'snapshot') cursor = frame.cursor;
        if (frames.length >= 40 && !done.isCompleted) done.complete();
      },
      onError: (Object error) {
        // An error after we already have what we need is not a failure.
        if (!done.isCompleted) done.completeError(error);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    try {
      await done.future;
    } finally {
      deadline.cancel();
    }

    // Unwind the stream *before* tearDown closes the client. Closing an
    // HttpClient that still has a response subscription makes that stream error
    // with "Connection closed while receiving data", and with nothing left
    // listening it escapes as an unhandled async error that fails the test.
    // Bounded, because cancelling a stream on a busy session can take a while.
    try {
      await subscription.cancel().timeout(const Duration(seconds: 10));
    } on Object {
      // A mid-flight cancel surfacing a socket error is expected here.
    }

    expect(frames, isNotEmpty, reason: 'the follow stream should open with a snapshot');
    expect(frames.first.kind, 'snapshot');
    expect(cursor, greaterThanOrEqualTo(0));
    stdout.writeln('        ${frames.length} frame(s), snapshot cursor=$cursor');

    final events = frames.first.snapshotEvents;
    stdout.writeln('        snapshot carried ${events.length} record(s)');
    for (final event in events) {
      expect(event.seq, greaterThanOrEqualTo(0));
      expect(event.type, isNotEmpty);
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('the desktop can send and receive on a live stream', () async {
    // The app's own prompt, seen from the app's own client.
    //
    // This is the transport half of the "I can't see the message I sent until I
    // restart the App" report. It proves two things the UI fix now *relies* on:
    // `session.follow` really does deliver the prompt's durable `user/message`
    // live, and the prompt's `requestId` comes back as `source.rpcId` (which is
    // what lets the local echo be reconciled exactly rather than by guessing from
    // the text). It also idles for longer than [newRelayHttpClient]'s 3-second
    // idleTimeout first: if that timeout applied to a streaming response, the
    // stream would be dead by the time the prompt is sent.
    final devices = await client.devices();
    final online = devices.where((device) => device.online).toList();
    if (online.isEmpty) {
      markTestSkipped('no desktop is online right now');
      return;
    }
    final desktop = online.first;

    // Reuse a previous run's probe session when it is idle.
    //
    // These checks run against the user's real desktop, and `session.create`
    // leaves a task behind in the phone's list — a session the harness titles
    // after the probe prompt. Creating a fresh one per run therefore accumulates
    // junk in someone's task list. An idle probe is a fine place to send another
    // probe; a *running* one is not, because the prompt would queue and the
    // assertion below would then be waiting on the previous turn.
    final probes = (await client.sessions(desktop.id))
        .where((session) => !session.running && session.title.toLowerCase().contains('live-follow probe'))
        .toList();
    final sessionId = probes.isNotEmpty
        ? probes.first.sessionId
        : asString((await client.createSession(desktop.id))['sessionId']);
    expect(sessionId, isNotEmpty);
    stdout.writeln(
      probes.isNotEmpty ? '        reusing probe session' : '        created a probe session',
    );

    final frames = <FollowFrame>[];
    final subscription = client.follow(desktop.id, sessionId, maxMessages: 6).listen(
          frames.add,
          onError: (Object error) => stdout.writeln('        stream error: $error'),
        );
    addTearDown(subscription.cancel);

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline) && frames.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(frames, isNotEmpty, reason: 'the follow stream should open with a snapshot');

    await Future<void>.delayed(const Duration(seconds: 8));

    const requestId = 'app-live-follow-probe';
    await client.prompt(
      desktop.id,
      sessionId,
      [
        {'type': 'text', 'text': 'live-follow probe'},
      ],
      requestId: requestId,
    );

    final ownMessage = DateTime.now().add(const Duration(seconds: 25));
    SessionEvent? seen;
    while (DateTime.now().isBefore(ownMessage) && seen == null) {
      for (final frame in frames) {
        final event = frame.kind == 'event' ? frame.event : null;
        if (event == null || event.type != 'user/message') continue;
        if (contentText(event.data['content']).contains('live-follow probe')) {
          seen = event;
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    expect(
      seen,
      isNotNull,
      reason: 'the live stream should deliver the phone\'s own prompt as user/message',
    );
    expect(asMap(seen!.data['source'])['rpcId'], requestId);
    stdout.writeln('        own prompt seen live at seq=${seen.seq}');
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('an attachment uploads and comes back as a receipt', () async {    // The one op the attachment feature adds, exercised from the app's own client
    // against the deployed relay and the real plugin. It stages bytes and gets a
    // receipt — nothing is written to any session, so this is safe to run against
    // your live desktop.
    final devices = await client.devices();
    final online = devices.where((device) => device.online).toList();
    if (online.isEmpty) {
      markTestSkipped('no desktop is online right now');
      return;
    }
    final desktop = online.first;

    final sessions = await client.sessions(desktop.id);
    if (sessions.isEmpty) {
      markTestSkipped('the desktop has no sessions yet');
      return;
    }

    final payload = Uint8List.fromList(List<int>.generate(64 * 1024, (i) => i % 251));
    final receipt = await client.uploadFile(
      desktop.id,
      sessionId: sessions.first.sessionId,
      bytes: payload,
      name: 'live-relay-probe.bin',
    );
    expect(receipt, isNotEmpty);
    stdout.writeln('        upload returned receipt=$receipt for ${payload.length} byte(s)');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
