/// HTTP surface of the relay: health, devices, sessions, ops, approvals and the
/// `session.follow` SSE stream.
///
/// The client is constructed with the [HttpClient] built in `tls.dart`, so both
/// its plain requests and its streamed responses trust the relay's private CA.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'models.dart';

/// One decoded `text/event-stream` frame.
class _SseFrame {
  const _SseFrame(this.event, this.data);

  final String event;
  final Map<String, dynamic> data;
}

class RelayClient {
  RelayClient({
    required this.baseUrl,
    required HttpClient httpClient,
    this.token = '',
  })  : _io = httpClient,
        _client = IOClient(httpClient);

  /// Base URL including scheme and port, e.g. `https://39.100.70.90:58443`.
  final String baseUrl;

  /// Device token. Empty before pairing, which simply omits the auth header.
  final String token;

  final HttpClient _io;
  final IOClient _client;
  bool _closed = false;

  static const Duration _timeout = Duration(seconds: 30);

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> get _headers => {
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      };

  Map<String, String> get _jsonHeaders => {
        ..._headers,
        'Content-Type': 'application/json',
      };

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
    _io.close(force: true);
  }

  // -- pairing -------------------------------------------------------------

  /// Asks the relay for a pairing code. The operator must approve it on the
  /// server (`python -m app.cli pair-approve <code>`) before [pairClaim] works.
  Future<Map<String, dynamic>> pairStart(String deviceName) async {
    final response = await _client
        .post(
          _uri('/api/v1/auth/pair/start'),
          headers: _jsonHeaders,
          body: jsonEncode({'deviceName': deviceName}),
        )
        .timeout(_timeout);
    return _unwrap(response);
  }

  /// Exchanges an approved code for a device token.
  Future<Map<String, dynamic>> pairClaim(String code) async {
    final response = await _client
        .post(
          _uri('/api/v1/auth/pair/claim'),
          headers: _jsonHeaders,
          body: jsonEncode({'code': code}),
        )
        .timeout(_timeout);
    return _unwrap(response);
  }

  // -- reads ---------------------------------------------------------------

  Future<RelayHealth> health() async {
    final response = await _get(_uri('/healthz'));
    if (response.statusCode != 200) {
      throw RelayException('http_${response.statusCode}', 'the relay did not answer /healthz');
    }
    return RelayHealth.fromJson(_decodeObject(response.body));
  }

  Future<List<RelayDevice>> devices() async {
    final value = await _getValue('/api/v1/devices');
    return _mapList(value['items'], RelayDevice.fromJson);
  }

  /// The conversations a human can open.
  ///
  /// Two kinds of row are dropped: subagent sessions, which the harness owns
  /// through their parent and refuses to drive directly, and **blank** sessions,
  /// which have never had a prompt accepted and are therefore an empty page titled
  /// with an id. The rule itself lives in [visibleSessions] so it is unit tested
  /// without a transport.
  Future<List<SessionSummary>> sessions(String deviceId, {bool includeArchived = false}) async {
    // `includeArchived` asks the plugin to leave archived Sessions in the list; the
    // archived id set comes back either way, and is what marks them here. Without the
    // flag the plugin removes them, which is how this list has always behaved.
    final query = includeArchived ? '?includeArchived=true' : '';
    final value = await _getValue('/api/v1/devices/$deviceId/sessions$query');
    final archived = asStringList(value['archivedSessionIds']).toSet();
    // `listedSessions`, not `visibleSessions`: the archived rows are wanted here —
    // they are marked and handed on to the drawer, which is the surface that shows
    // them. Filtering them at the transport layer (which this used to do, before the
    // split) left the archived section permanently empty while the grouping looked
    // perfectly correct.
    return listedSessions(
      _mapList(
        value['items'],
        (json) => SessionSummary.fromJson(
          json,
          archived: archived.contains(asString(json['sessionId'])),
        ),
      ),
    );
  }

  /// Archives a session on the desktop.
  ///
  /// Without [stopActivity] the Host **refuses** a session whose work is still
  /// running (`workspace/session-active`, with the work named in the error details)
  /// instead of silently killing it — which is what lets the caller ask first and
  /// then retry with the flag. Returns the updated archived set.
  Future<Set<String>> archiveSession(
    String deviceId, {
    required String sessionId,
    bool stopActivity = false,
  }) async {
    final value = await op(deviceId, 'workspace.archiveSession', {
      'sessionId': sessionId,
      if (stopActivity) 'stopActivity': true,
    });
    return asStringList(value['archivedSessionIds']).toSet();
  }

  /// Puts an archived session back among the ordinary ones.
  Future<Set<String>> unarchiveSession(String deviceId, {required String sessionId}) async {
    final value = await op(deviceId, 'workspace.unarchiveSession', {'sessionId': sessionId});
    return asStringList(value['archivedSessionIds']).toSet();
  }

  /// Approvals and questions still waiting on a desktop.
  ///
  /// The event socket is fire-and-forget, so this is how a phone catches up on
  /// anything raised while it was backgrounded or disconnected.
  Future<List<ApprovalAsk>> pendingApprovals() async {
    final value = await _getValue('/api/v1/approvals');
    return _mapList(value['items'], ApprovalAsk.fromWire);
  }

  Future<ModelCatalog> modelCatalog(String deviceId) async =>
      ModelCatalog.fromJson(await op(deviceId, 'model.catalog'));

  /// Switches the model a session will use for its next turn.
  ///
  /// The request shape is taken from the live descriptor
  /// (`{sessionId, provider, model, reasoningEffort?}`, result `{selected: …}`),
  /// and the op was checked against the running gateway's descriptors before
  /// being wired up here.
  ///
  /// [ModelSelection.reasoningEffort] is passed through when it is known and
  /// omitted otherwise, so the harness picks an effort the chosen model actually
  /// supports instead of being forced into an invalid combination.
  Future<ModelSelection?> selectModel(
    String deviceId, {
    required String sessionId,
    required ModelSelection selection,
  }) async {
    final effort = selection.reasoningEffort;
    final value = await op(deviceId, 'session.selectModel', {
      'sessionId': sessionId,
      'provider': selection.provider,
      'model': selection.model,
      if (effort != null && effort.isNotEmpty) 'reasoningEffort': effort,
    });
    return ModelSelection.fromJson(value['selected']);
  }

  // -- ops -----------------------------------------------------------------

  Future<Map<String, dynamic>> op(
    String deviceId,
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    final response = await _client
        .post(
          _uri('/api/v1/devices/$deviceId/op'),
          headers: _jsonHeaders,
          body: jsonEncode({'op': op, 'args': args}),
        )
        .timeout(_timeout);
    return _unwrap(response);
  }

  /// Sends a turn with the given `content[]` blocks.
  ///
  /// Blocks are built by `contentBlocksFor` in `chat/attachments.dart`, which
  /// owns the exact shapes: `{type:'text'}`, `{type:'image', mediaType, data}`
  /// (base64, inline) and `{type:'file', receiptId}`. A text-only turn still goes
  /// through here — [promptText] is the convenience wrapper.
  Future<Map<String, dynamic>> prompt(
    String deviceId,
    String sessionId,
    List<Map<String, dynamic>> content, {
    String mode = 'queue',
    String? requestId,
  }) {
    return op(deviceId, 'session.prompt', {
      'requestId': requestId ?? 'app-${DateTime.now().microsecondsSinceEpoch}',
      'sessionId': sessionId,
      'mode': mode,
      'content': content,
    });
  }

  /// A text-only turn, for callers that have nothing else to send.
  Future<Map<String, dynamic>> promptText(
    String deviceId,
    String sessionId,
    String text, {
    String mode = 'queue',
    String? requestId,
  }) {
    return prompt(
      deviceId,
      sessionId,
      [
        {'type': 'text', 'text': text},
      ],
      mode: mode,
      requestId: requestId,
    );
  }

  /// Stages one non-image file and returns the `receiptId` a `{type:'file'}`
  /// content block needs.
  ///
  /// Two wire parameters, verified against the live descriptor: `agentId` (the
  /// session, despite the name) and `request` — `{data, name?}`, where `data` is
  /// base64 of the raw bytes, the same encoding the inline image path uses.
  /// Images must **not** come through here; they go inline in the prompt.
  Future<String> uploadFile(
    String deviceId, {
    required String sessionId,
    required Uint8List bytes,
    String? name,
  }) async {
    final value = await op(deviceId, 'fileUploads.upload', {
      'agentId': sessionId,
      'request': {
        'data': base64Encode(bytes),
        if (name != null && name.isNotEmpty) 'name': name,
      },
    });
    final receiptId = asString(value['receiptId']);
    if (receiptId.isEmpty) {
      // Without a receipt the file can never be attached, so failing loudly here
      // beats sending a prompt whose file block the harness rejects.
      throw const RelayException(
        'upload_no_receipt',
        '中继上传成功但没有返回 receiptId，文件无法附上。',
      );
    }
    return receiptId;
  }

  Future<Map<String, dynamic>> cancel(String deviceId, String sessionId) =>
      op(deviceId, 'session.cancel', {'sessionId': sessionId});

  /// Delivers the phone's answer to an `ask_user_question` call.
  ///
  /// The Remote declares three wire parameters rather than one request object —
  /// `agentId` (the session), `callId`, and `answer` — verified against the live
  /// descriptor, where the third parameter is named `answer`, not `request`.
  Future<Map<String, dynamic>> answerQuestion(
    String deviceId, {
    required String sessionId,
    required String callId,
    required List<Map<String, dynamic>> answers,
  }) {
    return op(deviceId, 'userQuestions.answer', {
      'agentId': sessionId,
      'callId': callId,
      'answer': {'answers': answers},
    });
  }

  /// Creates a session, optionally in a specific working directory.
  ///
  /// Verified against the live harness: it answers `{sessionId, agentPreset}`,
  /// and calling it with no arguments at all is valid.
  Future<Map<String, dynamic>> createSession(
    String deviceId, {
    String? cwd,
    String? agentPreset,
  }) {
    return op(deviceId, 'session.create', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      if (agentPreset != null && agentPreset.isNotEmpty) 'agentPreset': agentPreset,
    });
  }

  Future<Map<String, dynamic>> page(
    String deviceId,
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 30,
  }) {
    return op(deviceId, 'session.page', {
      'address': {'kind': 'session', 'sessionId': sessionId},
      'throughSeq': throughSeq,
      if (beforeSeq != null) 'beforeSeq': beforeSeq,
      'maxMessages': maxMessages,
    });
  }

  // -- approvals -----------------------------------------------------------

  Future<void> decideApproval(
    String askId,
    String decision, {
    List<Map<String, dynamic>>? answers,
  }) async {
    final response = await _client
        .post(
          _uri('/api/v1/approvals/$askId'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'decision': decision,
            if (answers != null) 'answers': answers,
          }),
        )
        .timeout(_timeout);
    _unwrap(response);
  }

  // -- live stream ---------------------------------------------------------

  /// Follows one session as a stream of durable frames.
  ///
  /// Every (re)subscription starts with a `snapshot`, so callers can rebuild
  /// their state from it instead of tracking cursors across reconnects.
  Stream<FollowFrame> follow(
    String deviceId,
    String sessionId, {
    int maxMessages = 40,
  }) async* {
    final request = http.Request('POST', _uri('/api/v1/devices/$deviceId/stream'))
      ..headers.addAll({..._jsonHeaders, 'Accept': 'text/event-stream'})
      ..body = jsonEncode({
        'op': 'session.follow',
        'args': {
          'address': {'kind': 'session', 'sessionId': sessionId},
          'maxMessages': maxMessages,
        },
      });

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw _errorFromBody(response.statusCode, body);
    }

    var buffer = '';
    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final boundary = buffer.indexOf('\n\n');
        if (boundary < 0) break;
        final raw = buffer.substring(0, boundary);
        buffer = buffer.substring(boundary + 2);

        final frame = _parseSse(raw);
        if (frame == null) continue;
        if (frame.event == 'error') {
          throw RelayException(
            asString(frame.data['code'], 'stream_error'),
            asString(frame.data['message'], 'the stream reported an error'),
          );
        }
        if (frame.event == 'end') return;
        if (frame.event == 'chunk') {
          yield FollowFrame(kind: asString(frame.data['type'], 'event'), raw: frame.data);
        }
      }
    }
  }

  // -- internals -----------------------------------------------------------

  Future<Map<String, dynamic>> _getValue(String path) async {
    final response = await _get(_uri(path));
    return _unwrap(response);
  }

  /// GET with one retry.
  ///
  /// A pooled connection can be closed by the relay between requests, and reusing
  /// it fails with "Connection closed before full header was received" — which
  /// says nothing about the request. Retrying a GET is safe; POSTs are never
  /// retried, because replaying a prompt would be worse than surfacing the error.
  Future<http.Response> _get(Uri uri) async {
    try {
      return await _client.get(uri, headers: _headers).timeout(_timeout);
    } on http.ClientException {
      return await _client.get(uri, headers: _headers).timeout(_timeout);
    } on SocketException {
      return await _client.get(uri, headers: _headers).timeout(_timeout);
    }
  }

  Map<String, dynamic> _unwrap(http.Response response) {
    final body = _decodeObject(response.body);
    if (response.statusCode == 200 && body['ok'] == true) {
      return asMap(body['value']);
    }
    throw _errorFromBody(response.statusCode, response.body, parsed: body);
  }

  RelayException _errorFromBody(int status, String body, {Map<String, dynamic>? parsed}) {
    final decoded = parsed ?? _decodeObject(body);
    final error = asMap(decoded['error']);
    return RelayException(
      asString(error['code'], status == 401 ? 'unauthorized' : 'http_$status'),
      asString(error['message'], 'the relay answered $status'),
    );
  }

  Map<String, dynamic> _decodeObject(String body) {
    try {
      return asMap(jsonDecode(body));
    } on FormatException {
      return const {};
    }
  }

  static List<T> _mapList<T>(Object? raw, T Function(Map<String, dynamic>) build) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => build(item.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static _SseFrame? _parseSse(String raw) {
    String? event;
    final data = StringBuffer();
    for (final line in raw.split('\n')) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        data.write(line.substring(5).trimLeft());
      }
    }
    if (event == null) return null;
    if (data.isEmpty) return _SseFrame(event, const {});
    try {
      return _SseFrame(event, asMap(jsonDecode(data.toString())));
    } on FormatException {
      return _SseFrame(event, const {});
    }
  }
}
