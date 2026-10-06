/// Wire models for the relay API.
///
/// The contract these mirror is `docs/PROTOCOL.md`; the relay's own model lives
/// in `backend/app/protocol.py`. Everything here is deliberately tolerant of
/// missing fields — the relay may be older or newer than the app, and a null
/// field must never crash the UI.
library;

/// A provider + model pair, optionally with a reasoning effort.
///
/// This is both the shape `session.selectModel` takes and the shape the harness
/// projects back under `modelSelection`, so one class serves both directions.
class ModelSelection {
  const ModelSelection({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  final String provider;
  final String model;

  /// Left null when the caller has no opinion, so the harness picks its default
  /// for the model rather than being forced into an effort it may not support.
  final String? reasoningEffort;

  String get shortName {
    final tail = model.contains('/') ? model.split('/').last : model;
    return tail;
  }

  static ModelSelection? fromJson(Object? value) {
    final map = asMap(value);
    final provider = asString(map['provider']);
    final model = asString(map['model']);
    if (provider.isEmpty || model.isEmpty) return null;
    final effort = asString(map['reasoningEffort']);
    return ModelSelection(
      provider: provider,
      model: model,
      reasoningEffort: effort.isEmpty ? null : effort,
    );
  }
}

/// One provider's models, as returned by `model.catalog`.
class ModelGroup {
  const ModelGroup({required this.id, required this.name, required this.models});

  final String id;
  final String name;
  final List<ModelInfo> models;

  static ModelGroup fromJson(Map<String, dynamic> json) {
    final raw = json['models'];
    return ModelGroup(
      id: asString(json['id']),
      name: asString(json['name'], asString(json['id'])),
      models: raw is List
          ? raw
              .whereType<Map<dynamic, dynamic>>()
              .map((item) => ModelInfo.fromJson(item.cast<String, dynamic>()))
              .where((info) => info.id.isNotEmpty)
              .toList(growable: false)
          : const [],
    );
  }
}

class ModelInfo {
  const ModelInfo({required this.id, required this.name});

  final String id;
  final String name;

  static ModelInfo fromJson(Map<String, dynamic> json) => ModelInfo(
        id: asString(json['id']),
        name: asString(json['name'], asString(json['id'])),
      );
}

/// The whole catalog, plus the harness's own default selection.
class ModelCatalog {
  const ModelCatalog({required this.groups, this.defaultSelection});

  final List<ModelGroup> groups;
  final ModelSelection? defaultSelection;

  bool get isEmpty => groups.every((group) => group.models.isEmpty);

  /// Looks up a display name, falling back to the raw model id.
  String nameFor(ModelSelection selection) {
    for (final group in groups) {
      if (group.id != selection.provider) continue;
      for (final info in group.models) {
        if (info.id == selection.model) return info.name;
      }
    }
    return selection.shortName;
  }

  static ModelCatalog fromJson(Map<String, dynamic> json) {
    final raw = json['groups'];
    return ModelCatalog(
      groups: raw is List
          ? raw
              .whereType<Map<dynamic, dynamic>>()
              .map((item) => ModelGroup.fromJson(item.cast<String, dynamic>()))
              .where((group) => group.models.isNotEmpty)
              .toList(growable: false)
          : const [],
      defaultSelection: ModelSelection.fromJson(json['default']),
    );
  }
}

/// A failure reported by the relay, or synthesised locally for transport errors.
class RelayException implements Exception {
  const RelayException(this.code, this.message);

  final String code;
  final String message;

  /// True when the desktop simply is not connected right now.
  bool get isOffline => code == 'device_offline' || code == 'link_lost';

  /// True when the caller's own credentials are the problem.
  bool get isAuthFailure => code == 'unauthorized';

  @override
  String toString() => '$code: $message';
}

class RelayHealth {
  const RelayHealth({
    required this.status,
    required this.version,
    required this.protocol,
    required this.devicesOnline,
  });

  final String status;
  final String version;
  final int protocol;
  final int devicesOnline;

  factory RelayHealth.fromJson(Map<String, dynamic> json) {
    final devices = asMap(json['devices']);
    return RelayHealth(
      status: asString(json['status'], 'unknown'),
      version: asString(json['version']),
      protocol: asInt(json['protocol']),
      devicesOnline: asInt(devices['online']),
    );
  }
}

/// One desktop DSH host that has connected to the relay at least once.
class RelayDevice {
  const RelayDevice({
    required this.id,
    required this.name,
    required this.online,
    required this.platform,
    required this.harnessVersion,
    required this.capabilities,
    required this.pendingRequests,
    this.connectedAt,
    this.linkAgeSeconds,
  });

  final String id;
  final String name;
  final bool online;
  final String platform;
  final String harnessVersion;
  final List<String> capabilities;
  final int pendingRequests;

  /// Absolute time the current link came up, and how long ago that was.
  ///
  /// A link that keeps resetting is the signature of a keepalive problem, so the
  /// app surfaces the age rather than pretending a flapping link is healthy.
  final int? connectedAt;
  final int? linkAgeSeconds;

  bool get supportsEvents => capabilities.contains('events');
  bool get supportsApprovals => capabilities.contains('approvals');

  factory RelayDevice.fromJson(Map<String, dynamic> json) {
    return RelayDevice(
      id: asString(json['id']),
      name: asString(json['name']),
      online: json['online'] == true,
      platform: asString(json['platform']),
      harnessVersion: asString(json['harnessVersion']),
      capabilities: asStringList(json['capabilities']),
      pendingRequests: asInt(json['pendingRequests']),
      connectedAt: json['connectedAt'] as int?,
      linkAgeSeconds: json['linkAgeSeconds'] as int?,
    );
  }
}

/// The numbers DSH shows in its own composer footer.
///
/// Everything here comes from a session's `projections.values`, which both
/// `session.list` and the opening `session.follow` snapshot carry — so displaying
/// them costs no extra request. The formulas mirror the desktop's `StatsPills` and
/// `ContextMeter` exactly, and `test/metrics_test.dart` pins them against values
/// read from live sessions.
class SessionMetrics {
  const SessionMetrics({
    this.asOfSeq = 0,
    this.turns = 0,
    this.steps = 0,
    this.decodeTokens = 0,
    this.decodeMs = 0,
    this.uncachedInputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.pressureTokens = 0,
    this.projectedTokens = 0,
    this.contextWindow = 0,
  });

  /// Sequence watermark of the projection this was read from.
  ///
  /// Two readings of one session can be compared with it and the newer kept — the
  /// same "higher seq wins" rule the desktop's projection store uses.
  final int asOfSeq;

  /// Counts: one per settled step, and one per turn whose number changed.
  final int turns;
  final int steps;

  /// Cumulative token accounting for the whole session.
  final int decodeTokens;
  final int decodeMs;
  final int uncachedInputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// Context occupancy: the newest sample, and the window it is measured against.
  final int pressureTokens;
  final int projectedTokens;
  final int contextWindow;

  /// Reads whichever projection block is on hand.
  ///
  /// `session.list` items carry `{kind: 'sequenced', asOfSeq, values}` and the
  /// follow snapshot carries `{asOfSeq, values}`; the parse is the same for both.
  factory SessionMetrics.fromProjections(Object? projections) {
    final block = asMap(projections);
    final values = asMap(block['values']);
    final stats = asMap(values['sessionStats']);
    final usage = asMap(values['tokenUsage']);
    final pressure = asMap(values['contextPressure']);
    return SessionMetrics(
      asOfSeq: asInt(block['asOfSeq']),
      turns: asInt(stats['turns']),
      steps: asInt(stats['steps']),
      decodeTokens: asInt(stats['decodeTokens']),
      decodeMs: asInt(stats['decodeMs']),
      uncachedInputTokens: asInt(usage['uncachedInputTokens']),
      outputTokens: asInt(usage['outputTokens']),
      cacheReadTokens: asInt(usage['cacheReadTokens']),
      cacheWriteTokens: asInt(usage['cacheWriteTokens']),
      pressureTokens: asInt(pressure['pressureTokens']),
      projectedTokens: asInt(pressure['projectedTokens']),
      contextWindow: asInt(pressure['contextWindow']),
    );
  }

  /// The newer of two readings; `a` wins a tie, so the choice is deterministic.
  static SessionMetrics? freshest(SessionMetrics? a, SessionMetrics? b) {
    if (a == null) return b;
    if (b == null) return a;
    return b.asOfSeq > a.asOfSeq ? b : a;
  }

  /// Input tokens the provider actually billed.
  ///
  /// Cached reads and writes are billed too, just far more cheaply — and output
  /// tokens are *not* part of it, which is what makes this the cache-hit
  /// denominator rather than the total.
  int get billedInputTokens =>
      uncachedInputTokens + cacheReadTokens + cacheWriteTokens;

  /// Everything the session has processed: billed input plus output.
  int get totalTokens => billedInputTokens + outputTokens;

  /// Decode speed over the whole session, in tokens per second.
  ///
  /// Output tokens over the time spent generating them (first token to completion),
  /// so it is an average that moves once per settled step — not a rolling value.
  /// Null when no step has reported usage yet.
  double? get tokensPerSecond => decodeMs > 0 ? decodeTokens / (decodeMs / 1000) : null;

  /// Share of billed input served from the cache. Null when nothing was billed.
  double? get cacheHitRatio {
    final billed = billedInputTokens;
    return billed > 0 ? cacheReadTokens / billed : null;
  }

  /// Tokens currently occupying the context window, or null when unknown.
  ///
  /// `projectedTokens` already folds in any surface movement (a compaction) since
  /// the sample was taken, so it is preferred over the raw pressure.
  int? get contextUsedTokens {
    if (projectedTokens > 0) return projectedTokens;
    if (pressureTokens > 0) return pressureTokens;
    return null;
  }

  /// Context occupancy as a whole percentage, capped at 100, or null when unknown.
  int? get contextPercent {
    final used = contextUsedTokens;
    if (used == null || contextWindow <= 0) return null;
    final percent = (used / contextWindow * 100).round();
    return percent > 100 ? 100 : percent;
  }

  /// Whether anything has happened yet.
  ///
  /// A session that has never had a turn has no numbers worth showing — the
  /// desktop hides its stats row in that case, and so does the phone.
  bool get hasActivity => turns > 0 || steps > 0 || totalTokens > 0;

  /// Whether there is nothing at all to display.
  bool get isEmpty => !hasActivity && contextUsedTokens == null;
}

/// One session row from `session.list`.
class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.running,
    required this.agentAvailable,
    required this.blank,
    required this.updatedAt,
    this.asOfSeq = 0,
    this.title = '',
    this.model,
    this.cwd,
    this.isSubagent = false,
    this.metrics,
  });

  final String sessionId;
  final bool running;
  final bool agentAvailable;
  final bool blank;

  /// True when this session is a subagent's, not a chat a human drives.
  ///
  /// Read from `projections.values.subagent`. Such a session is owned by its parent
  /// and the harness refuses to drive it directly —
  /// `session/agent-busy: session "…" is owned by subagent routing` — so it must not
  /// be offered as an ordinary conversation on the phone.
  final bool isSubagent;

  /// Raw value from `session.list`. The harness reports this in **milliseconds**,
  /// unlike the relay's own `connectedAt` / `lastSeen`, which are seconds — see
  /// [updatedAtTime].
  final int updatedAt;

  /// Latest sequence the harness has projected (`projections.asOfSeq`).
  ///
  /// This is the natural `throughSeq` for `session.page`, and it is available
  /// without opening a stream.
  final int asOfSeq;

  /// Human title from `projections.values.title`, when the harness has one.
  ///
  /// Without this the list showed three identical rows, because every id starts
  /// with the literal prefix `session-`.
  final String title;

  /// The model this session will use on its next turn.
  ///
  /// Read from `projections.values.modelSelection` — `session.list` already
  /// carries it, so displaying and changing the model needs no extra request.
  final ModelSelection? model;
  final String? cwd;

  /// The desktop's footer numbers, read from the same projection block.
  ///
  /// Null only when the harness sent no projection at all; a session that has not
  /// run yet yields an empty (all-zero) reading instead.
  final SessionMetrics? metrics;

  /// [updatedAt] as a real time, tolerating either unit.
  ///
  /// Verified against the live harness: `session.list` returns milliseconds
  /// (1790924301943), while `/api/v1/devices` returns seconds (1790923866).
  /// Guessing wrong is silent — every session just renders as "just now" — so
  /// the unit is sniffed rather than assumed.
  DateTime? get updatedAtTime {
    if (updatedAt <= 0) return null;
    final millis = updatedAt > 100000000000 ? updatedAt : updatedAt * 1000;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    final projections = asMap(json['projections']);
    final values = asMap(projections['values']);
    final selection = asMap(values['modelSelection']);
    return SessionSummary(
      sessionId: asString(json['sessionId']),
      running: json['running'] == true,
      agentAvailable: json['agentAvailable'] == true,
      blank: json['blank'] == true,
      updatedAt: asInt(json['updatedAt']),
      asOfSeq: asInt(projections['asOfSeq']),
      title: asString(values['title']).trim(),
      // `next` is what the following turn will use; `lastUsed` is the fallback
      // for a session that has not queued anything yet.
      model: ModelSelection.fromJson(selection['next']) ??
          ModelSelection.fromJson(selection['lastUsed']),
      cwd: json['cwd'] as String?,
      isSubagent: asMap(values['subagent']).isNotEmpty,
      metrics: SessionMetrics.fromProjections(projections),
    );
  }

  /// A short human label: the harness title when there is one, otherwise the
  /// session id with its constant prefix stripped and the working directory.
  String get label {
    if (title.isNotEmpty) return title;

    final bare = sessionId.startsWith('session-') ? sessionId.substring(8) : sessionId;
    final short = bare.length > 8 ? bare.substring(0, 8) : bare;
    final dir = cwd?.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).lastOrNull;
    return dir == null ? short : '$short · $dir';
  }
}

/// The sessions a phone should offer to a human.
///
/// Two categories are dropped, for different reasons:
///
///   * **Subagent sessions.** The harness lists them beside real conversations,
///     but owns them through their parent and answers every op with
///     `session/agent-busy: … is owned by subagent routing` — a row that cannot be
///     opened is worse than no row.
///   * **Blank sessions.** `blank` is the harness's own "no prompt was ever
///     accepted here" flag (`sessionInfo.blankBit` starts true and clears on the
///     first accepted prompt). On a phone such a session is an empty page titled
///     with a meaningless id — and it is almost always residue, because every probe
///     session a verification run creates looks exactly like this. A real
///     conversation reappears as soon as its first message is accepted.
List<SessionSummary> visibleSessions(Iterable<SessionSummary> sessions) => sessions
    .where((session) => !session.isSubagent && !session.blank)
    .toList(growable: false);

/// One durable session event, as carried by `session.event`.
class SessionEvent {
  const SessionEvent({
    required this.sessionId,
    required this.seq,
    required this.type,
    required this.time,
    required this.data,
  });

  final String sessionId;
  final int seq;
  final String type;
  final int time;
  final Map<String, dynamic> data;

  factory SessionEvent.fromJson(Map<String, dynamic> json) {
    return SessionEvent(
      sessionId: asString(json['sessionId']),
      seq: asInt(json['seq']),
      type: asString(json['type']),
      time: asInt(json['time']),
      data: asMap(json['data']),
    );
  }

  bool get isSurface =>
      type == 'user/message' ||
      type == 'assistant/message' ||
      type == 'tool/call' ||
      type == 'tool/result' ||
      type == 'developer/message' ||
      type == 'system/message';
}

/// Parses the `records[]` of a `session.page` result or of a follow snapshot.
///
/// Both carry the same shape — `{type: 'event', event: {seq, type, time, data}}` —
/// so one parser serves the opening snapshot and every older page fetched while
/// scrolling back.
List<SessionEvent> sessionEventsFromRecords(Object? records, {String sessionId = ''}) {
  if (records is! List) return const [];
  final out = <SessionEvent>[];
  for (final record in records) {
    final map = asMap(record);
    final event = asMap(map['event']);
    if (event.isEmpty) continue;
    out.add(
      SessionEvent(
        sessionId: sessionId,
        seq: asInt(event['seq']),
        type: asString(event['type']),
        time: asInt(event['time']),
        data: asMap(event['data']),
      ),
    );
  }
  return out;
}

/// A frame from the `session.follow` stream.
///
/// `session.follow` always opens with a `snapshot`, so a client that reconnects
/// can simply rebuild its state from the snapshot instead of tracking cursors.
class FollowFrame {
  const FollowFrame({required this.kind, required this.raw});

  /// `snapshot`, `event` or `assistant-stream`.
  final String kind;
  final Map<String, dynamic> raw;

  Map<String, dynamic> get snapshot => asMap(raw);

  List<SessionEvent> get snapshotEvents => sessionEventsFromRecords(
        raw['records'],
        sessionId: asString(asMap(raw['header'])['id']),
      );

  /// Whether the desktop holds records older than this snapshot.
  ///
  /// The snapshot is bounded by bytes, not just by `maxMessages` — a long turn can
  /// fill it on its own — so this is what tells the view there is history to fetch
  /// when the user scrolls back.
  bool get hasMore => raw['hasMore'] == true;

  /// The metrics the opening snapshot carries, or null on later frames.
  ///
  /// The desktop gets its footer numbers from a live projection stream; the phone
  /// has them for free at every (re)subscribe, which is close enough for a line
  /// that is correct on open and refreshed while a turn runs.
  SessionMetrics? get metrics {
    final block = raw['projections'];
    if (block is! Map) return null;
    return SessionMetrics.fromProjections(block);
  }

  int get cursor => asInt(raw['cursor']);

  SessionEvent? get event {
    final nested = asMap(raw['event']);
    if (nested.isEmpty) return null;
    return SessionEvent(
      sessionId: asString(nested['sessionId']),
      seq: asInt(nested['seq']),
      type: asString(nested['type']),
      time: asInt(nested['time']),
      data: asMap(nested['data']),
    );
  }

  /// Assistant text being streamed before the message is committed.
  String? get streamingText {
    if (kind != 'assistant-stream') return null;
    final frame = asMap(raw['frame']);
    if (asString(frame['type']) != 'chunk') return null;
    final chunk = asMap(frame['chunk']);
    if (asString(chunk['type']) != 'text-delta') return null;
    return chunk['text'] as String?;
  }
}

/// An approval or question the desktop is waiting on.
class ApprovalAsk {
  const ApprovalAsk({
    required this.askId,
    required this.topic,
    required this.sessionId,
    required this.payload,
    this.deviceId = '',
    this.expiresInSeconds,
  });

  final String askId;

  /// `approval.ask` or `question.ask`.
  final String topic;
  final String sessionId;
  final Map<String, dynamic> payload;

  /// Which desktop is waiting. Empty for asks that arrived over the socket,
  /// where the device is carried by the frame rather than the payload.
  final String deviceId;

  /// Only known for asks fetched from the relay's pending list.
  final int? expiresInSeconds;

  bool get isQuestion => topic == 'question.ask';

  String get toolName => asString(payload['toolName']);
  String? get reason => payload['reason'] as String?;

  /// Localised reason text, when the desktop supplied one.
  String? get displayReason {
    final display = asMap(payload['displayReason']);
    if (display.isEmpty) return null;
    return (display['zh'] ?? display['en']) as String?;
  }

  List<Map<String, dynamic>> get questions {
    final raw = payload['questions'];
    if (raw is! List) return const [];
    return raw.whereType<Map<dynamic, dynamic>>().map((e) => e.cast<String, dynamic>()).toList();
  }

  factory ApprovalAsk.fromEvent(String topic, Map<String, dynamic> payload, {String deviceId = ''}) {
    return ApprovalAsk(
      askId: asString(payload['askId']),
      topic: topic,
      sessionId: asString(payload['sessionId']),
      payload: payload,
      deviceId: deviceId,
    );
  }

  /// One item from `GET /api/v1/approvals`.
  ///
  /// This is how a phone learns about a request that was raised while it was
  /// disconnected: the socket event is gone, but the relay still holds it.
  factory ApprovalAsk.fromWire(Map<String, dynamic> json) {
    final payload = asMap(json['payload']);
    return ApprovalAsk(
      askId: asString(json['askId'], asString(payload['askId'])),
      topic: asString(json['topic']),
      sessionId: asString(payload['sessionId']),
      payload: payload,
      deviceId: asString(json['deviceId']),
      expiresInSeconds: json['expiresInSeconds'] as int?,
    );
  }
}

/// An event pushed over the phone WebSocket.
class RelayEvent {
  const RelayEvent({
    required this.topic,
    required this.deviceId,
    required this.payload,
    this.subId,
  });

  final String topic;
  final String deviceId;
  final Map<String, dynamic> payload;

  /// `null` for device-level broadcasts, which are not tied to a subscription.
  final String? subId;

  factory RelayEvent.fromJson(Map<String, dynamic> json) {
    return RelayEvent(
      topic: asString(json['topic']),
      deviceId: asString(json['deviceId']),
      subId: json['subId'] as String?,
      payload: asMap(json['payload']),
    );
  }
}

// --------------------------------------------------------------------------- //
// tolerant JSON helpers
// --------------------------------------------------------------------------- //

String asString(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

int asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return const {};
}

List<String> asStringList(Object? value) {
  if (value is List) {
    return value.whereType<String>().toList(growable: false);
  }
  return const [];
}

/// Flattens a DSH `ContentBlock[]` into its visible text.
///
/// Reasoning blocks are included because that is what the harness shows while a
/// model thinks; tool calls and images are represented by their own widgets.
String contentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final block in content) {
    final map = asMap(block);
    final type = asString(map['type']);
    if (type == 'text' || type == 'reasoning') {
      final text = map['text'];
      if (text is String && text.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(text);
      }
    }
  }
  return buffer.toString();
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
