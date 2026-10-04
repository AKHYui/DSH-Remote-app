/// Controller tests for sending attachments.
///
/// The interesting behaviour is what happens when something fails, because that
/// is where a draft gets destroyed or a prompt goes out half-formed. A fake
/// [RelayClient] stands in for the transport, so nothing here touches a relay.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/api/relay_client.dart';
import 'package:dsh_remote_app/chat/attachments.dart';
import 'package:dsh_remote_app/state/app_controller.dart';
import 'package:dsh_remote_app/state/settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what reached the transport, and can be told to fail.
///
/// Only the two attachment paths are overridden; anything else would report a
/// programming mistake in the test rather than silently succeeding.
class FakeRelayClient extends RelayClient {
  FakeRelayClient()
      : super(
          baseUrl: 'https://relay.invalid',
          // Never used for a request: both overridden paths return before the
          // transport is touched. It exists only because `RelayClient` requires
          // one, and `close()` disposes it.
          httpClient: HttpClient(),
        );

  final List<String> uploadedNames = [];
  final List<int> uploadedSizes = [];
  List<Map<String, dynamic>>? sentContent;
  String? sentSessionId;
  String uploadError = '';
  String promptError = '';

  /// How many times `session.prompt` was called — the point of several tests is
  /// that it was called **zero** times.
  int promptCalls = 0;

  /// [AppState.uploadingAttachments] as seen from inside the transport, which is
  /// the only place the in-flight state can be observed.
  final List<bool> uploadingFlagAtCallTime = [];

  /// Set by the test so the fake can read live controller state.
  AppController? controller;

  /// When true, `session.create` answers without an id, which is what an older
  /// or misbehaving relay does.
  bool createWithoutId = false;

  @override
  Future<Map<String, dynamic>> createSession(
    String deviceId, {
    String? cwd,
    String? agentPreset,
  }) async => createWithoutId ? const {} : const {'sessionId': 'session-test-1'};

  @override
  Future<List<SessionSummary>> sessions(String deviceId) async => const [];

  @override
  Future<String> uploadFile(
    String deviceId, {
    required String sessionId,
    required Uint8List bytes,
    String? name,
  }) async {
    uploadingFlagAtCallTime.add(controller?.state.uploadingAttachments ?? false);
    if (uploadError.isNotEmpty) throw RelayException('upload_failed', uploadError);
    uploadedNames.add(name ?? '');
    uploadedSizes.add(bytes.length);
    return 'rcpt-${uploadedNames.length}';
  }

  @override
  Future<Map<String, dynamic>> prompt(
    String deviceId,
    String sessionId,
    List<Map<String, dynamic>> content, {
    String mode = 'queue',
    String? requestId,
  }) async {
    promptCalls++;
    if (promptError.isNotEmpty) throw RelayException('prompt_failed', promptError);
    sentSessionId = sessionId;
    sentContent = content;
    return const {'accepted': true};
  }
}

PendingAttachment image(String id, {String name = 'shot.png'}) {
  final bytes = Uint8List(24)..setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  return PendingAttachment.forContent(id: id, name: name, bytes: bytes, kind: 'image');
}

PendingAttachment document(String id, {String name = 'notes.txt', int length = 24}) {
  return PendingAttachment.forContent(
    id: id,
    name: name,
    bytes: Uint8List(length)..setAll(0, [0x68, 0x69]),
    kind: 'file',
  );
}

/// A controller whose transport is [client], pointed at one (fake) desktop.
///
/// `sendPrompt` needs an active device to create a session on, and the relay's
/// device list is only fetched with a token — which in turn starts the event
/// socket. A fake client plus one device on the state avoids both.
Future<AppController> connected(FakeRelayClient client) async {
  final controller = AppController(clientFactory: (baseUrl, token) => client);
  client.controller = controller;
  await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
  controller.state = controller.state.copyWith(activeDeviceId: 'device-1');
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRelayClient client;
  late AppController controller;

  setUp(() async {
    client = FakeRelayClient();
    controller = await connected(client);
  });

  tearDown(() => controller.dispose());

  group('the staged attachment list', () {
    test('adds, refuses an oversized pick and removes', () {
      final good = document('a');
      expect(controller.addAttachment(good), isNull);
      expect(controller.state.attachments, hasLength(1));

      // Staging is where the 2 MiB rule is enforced, so nothing oversized can
      // reach the wire even if the UI forgets to check.
      final over = document('big', length: maxAttachmentBytes + 1);
      final reason = controller.addAttachment(over);
      expect(reason, contains('上限 2 MB'));
      expect(controller.state.attachments.map((item) => item.id), ['a']);

      controller.removeAttachment('a');
      expect(controller.state.attachments, isEmpty);
    });

    test('the same attachment is never staged twice', () {
      final once = document('a');
      expect(controller.addAttachment(once), isNull);
      expect(controller.addAttachment(once), isNull);
      expect(controller.state.attachments, hasLength(1));
    });

    test('clearAttachments empties the list', () {
      controller.addAttachment(document('a'));
      controller.addAttachment(image('b'));
      controller.clearAttachments();
      expect(controller.state.attachments, isEmpty);
    });
  });

  group('sendPrompt', () {
    test('refuses an empty turn with nothing attached', () async {
      final error = await controller.sendPrompt('   ');
      expect(error, isNotNull);
      expect(client.sentContent, isNull);
    });

    test('sends one prompt carrying text and an inline image', () async {
      controller.addAttachment(image('img-1'));
      expect(await controller.sendPrompt('看这张图'), isNull);

      expect(client.uploadedNames, isEmpty, reason: 'images never upload');
      expect(client.sentContent, hasLength(2));
      expect(client.sentContent!.first, {'type': 'text', 'text': '看这张图'});
      expect(client.sentContent!.last['type'], 'image');
      expect(client.sentContent!.last['mediaType'], 'image/png');
      expect(controller.state.attachments, isEmpty, reason: 'accepted, so dropped');
    });

    test('uploads every file first, in order, then sends the receipts', () async {
      controller.addAttachment(document('f1', name: 'a.txt'));
      controller.addAttachment(document('f2', name: 'b.bin'));

      expect(await controller.sendPrompt('带着文件'), isNull);

      expect(client.uploadedNames, ['a.txt', 'b.bin']);
      expect(client.sentContent, hasLength(3));
      expect(client.sentContent![1], {'type': 'file', 'receiptId': 'rcpt-1'});
      expect(client.sentContent![2], {'type': 'file', 'receiptId': 'rcpt-2'});
    });

    test('a failed upload sends no prompt and keeps the draft', () async {
      client.uploadError = 'relay said no';
      controller.addAttachment(image('img-1'));
      controller.addAttachment(document('f1'));

      final error = await controller.sendPrompt('这条发不出去');

      expect(error, contains('relay said no'));
      expect(client.promptCalls, 0, reason: 'nothing may be sent');
      expect(client.sentContent, isNull);
      expect(
        controller.state.attachments.map((item) => item.id),
        ['img-1', 'f1'],
        reason: 'the user must be able to retry without re-picking',
      );
      expect(controller.state.uploadingAttachments, isFalse, reason: 'no stuck spinner');
    });

    test('a failed prompt keeps the draft too', () async {
      client.promptError = 'device offline';
      controller.addAttachment(image('img-1'));

      final error = await controller.sendPrompt('再来一次');

      expect(error, contains('device offline'));
      expect(client.promptCalls, 1);
      expect(controller.state.attachments, hasLength(1));
      expect(controller.state.uploadingAttachments, isFalse);
    });

    test('the composer can see that an upload is in flight', () async {
      controller.addAttachment(document('f1'));
      await controller.sendPrompt('带着文件');
      // The flag is raised before the first upload and cleared on the way out,
      // so what the composer renders during the request is not "frozen".
      expect(client.uploadingFlagAtCallTime, [true]);
      expect(controller.state.uploadingAttachments, isFalse);
    });

    test('an image-only turn is allowed — a screenshot needs no words', () async {
      controller.addAttachment(image('img-1'));
      expect(await controller.sendPrompt(''), isNull);
      expect(client.sentContent, hasLength(1));
      expect(client.sentContent!.single['type'], 'image');
    });

    test('composing sends one prompt, and only one, for the new session', () async {
      controller.addAttachment(image('img-1'));
      expect(await controller.sendPrompt('第一个任务'), isNull);
      expect(client.promptCalls, 1);
      expect(client.sentSessionId, 'session-test-1');
    });

    test('a second send reuses the session the first one created', () async {
      await controller.sendPrompt('第一个任务');
      await controller.sendPrompt('第二个任务');
      expect(client.promptCalls, 2);
      expect(client.sentContent!.single['text'], '第二个任务');
    });

    test('a file the user staged by hand is still size-checked before sending', () async {
      final over = document('over', length: maxAttachmentBytes + 1);
      final error = await controller.sendPrompt('附带文件', attachments: [over]);
      expect(error, contains('上限 2 MB'));
      expect(client.uploadedNames, isEmpty);
      expect(client.sentContent, isNull);
    });

    test('the image bytes on the wire are base64 of the picked bytes', () async {
      final picked = image('img-1');
      await controller.sendPrompt('x', attachments: [picked]);
      expect(client.sentContent!.last['data'], base64Encode(picked.bytes));
    });

    test('without a controller client it says so instead of throwing', () async {
      final fresh = AppController();
      addTearDown(fresh.dispose);
      expect(await fresh.sendPrompt('hi'), '尚未连接中继。');
    });

    test('when the relay cannot name a new session the draft is kept', () async {
      client.createWithoutId = true;
      controller.addAttachment(image('img-1'));
      // `session.create` answering without an id is a failure, not a reason to
      // prompt a session that does not exist.
      final error = await controller.sendPrompt('你好');
      expect(error, isNotNull);
      expect(client.promptCalls, 0);
      expect(controller.state.attachments, hasLength(1));
    });
  });
}
