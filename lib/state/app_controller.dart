/// The app's single source of truth for relay connectivity and live state.
///
/// Deliberately one controller rather than a web of small providers: the pieces
/// are genuinely coupled (settings produce a client, the client produces the
/// event socket, the socket produces approvals), and one owner makes the
/// lifecycle — especially disposal — obvious.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/relay_events.dart';
import '../api/tls.dart';
import '../chat/attachments.dart';
import '../chat/transcript.dart';
import 'settings.dart';

/// One "this session moved" nudge from the event socket.
///
/// [tick] increments per emission so two signals for the same session are never
/// identical objects; consumers react with `identical()`, which is what they want
/// — a repeated signal is still news.
class SessionSignal {
  const SessionSignal({required this.sessionId, required this.tick});

  final String sessionId;
  final int tick;
}

class AppState {
  const AppState({
    this.loading = true,
    this.error,
    this.health,
    this.devices = const [],
    this.approvals = const [],
    this.eventsState = RelayEventsState.idle,
    this.eventsError = '',
    this.caFingerprint = '',
    this.activeDeviceId = '',
    this.sessions = const [],
    this.sessionsLoading = false,
    this.sessionsError,
    this.activeSessionId,
    this.lastSignal,
    this.workspace = '',
    this.agentPreset = '',
    this.creatingSession = false,
    this.attachments = const [],
    this.uploadingAttachments = false,
  });

  final bool loading;
  final String? error;
  final RelayHealth? health;
  final List<RelayDevice> devices;
  final List<ApprovalAsk> approvals;
  final RelayEventsState eventsState;

  /// Why the event socket is not connected, if it knows.
  final String eventsError;
  final String caFingerprint;

  /// Which desktop the drawer and the conversation are looking at.
  final String activeDeviceId;
  final List<SessionSummary> sessions;
  final bool sessionsLoading;
  final String? sessionsError;

  /// `null` means the composer is starting a new session rather than replying.
  final String? activeSessionId;

  /// A nudge from the event socket: this session moved on the desktop.
  ///
  /// The `session.follow` stream is a long-lived HTTP response, and a half-open
  /// one delivers nothing and reports nothing — no error, no end, so the reader
  /// waits forever. The event socket is the app's *other* channel and it does
  /// police itself (it closes after 55s of silence, see `RelayEvents`), so its
  /// `session.activity` / `session.status` frames are what let the open chat screen
  /// notice that the desktop produced something its follow stream never delivered.
  ///
  /// [tick] distinguishes two signals for the same session; consumers compare
  /// identity rather than contents.
  final SessionSignal? lastSignal;

  /// Working directory a new session will be created in. Empty means the
  /// harness default.
  final String workspace;

  /// Agent preset (mode) a new session will be created with.
  ///
  /// Kept here, not only in settings, because a prompt typed on the welcome screen
  /// creates the session for you — that path must honour the mode the user picked
  /// rather than silently falling back to the harness default.
  final String agentPreset;
  final bool creatingSession;

  /// Attachments staged in the composer but not yet accepted by the desktop.
  ///
  /// Shared by both compose surfaces on purpose: the welcome view and an open
  /// session are the same conversation target, and a file picked before the
  /// session existed must survive the session being created.
  final List<PendingAttachment> attachments;

  /// A non-image upload is in flight. Images never set this — they need no
  /// request of their own.
  final bool uploadingAttachments;

  bool get relayReachable => health != null;
  bool get hasDesktopOnline => devices.any((device) => device.online);
  bool get composing => activeSessionId == null;

  RelayDevice? get activeDevice {
    for (final device in devices) {
      if (device.id == activeDeviceId) return device;
    }
    return devices.isEmpty ? null : devices.first;
  }

  SessionSummary? get activeSession {
    for (final session in sessions) {
      if (session.sessionId == activeSessionId) return session;
    }
    return null;
  }

  /// A short label for any session id, for the pending-request panel.
  String labelForSession(String sessionId) {
    if (sessionId.isEmpty) return '未知任务';
    for (final session in sessions) {
      if (session.sessionId == sessionId) return session.label;
    }
    final bare = sessionId.startsWith('session-') ? sessionId.substring(8) : sessionId;
    return bare.length > 8 ? bare.substring(0, 8) : bare;
  }

  /// Sessions grouped by working directory, newest group first.
  ///
  /// The harness has no project concept over this API, so a workspace *is* a
  /// `cwd` — which is what `session.create` takes anyway.
  List<WorkspaceGroup> get workspaces {
    final groups = <String, List<SessionSummary>>{};
    for (final session in sessions) {
      final key = (session.cwd == null || session.cwd!.isEmpty) ? '' : session.cwd!;
      groups.putIfAbsent(key, () => []).add(session);
    }
    final ordered = groups.entries.toList()
      ..sort((a, b) {
        final aLatest = a.value.isEmpty ? 0 : a.value.first.updatedAt;
        final bLatest = b.value.isEmpty ? 0 : b.value.first.updatedAt;
        return bLatest.compareTo(aLatest);
      });
    return [
      for (final entry in ordered) WorkspaceGroup(path: entry.key, sessions: entry.value),
    ];
  }

  AppState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    RelayHealth? health,
    List<RelayDevice>? devices,
    List<ApprovalAsk>? approvals,
    RelayEventsState? eventsState,
    String? eventsError,
    String? caFingerprint,
    String? activeDeviceId,
    List<SessionSummary>? sessions,
    bool? sessionsLoading,
    String? sessionsError,
    bool clearSessionsError = false,
    String? activeSessionId,
    bool clearActiveSession = false,
    SessionSignal? lastSignal,
    String? workspace,
    String? agentPreset,
    bool? creatingSession,
    List<PendingAttachment>? attachments,
    bool? uploadingAttachments,
  }) {
    return AppState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      health: health ?? this.health,
      devices: devices ?? this.devices,
      approvals: approvals ?? this.approvals,
      eventsState: eventsState ?? this.eventsState,
      eventsError: eventsError ?? this.eventsError,
      caFingerprint: caFingerprint ?? this.caFingerprint,
      activeDeviceId: activeDeviceId ?? this.activeDeviceId,
      sessions: sessions ?? this.sessions,
      sessionsLoading: sessionsLoading ?? this.sessionsLoading,
      sessionsError: clearSessionsError ? null : (sessionsError ?? this.sessionsError),
      activeSessionId: clearActiveSession ? null : (activeSessionId ?? this.activeSessionId),
      lastSignal: lastSignal ?? this.lastSignal,
      workspace: workspace ?? this.workspace,
      agentPreset: agentPreset ?? this.agentPreset,
      creatingSession: creatingSession ?? this.creatingSession,
      attachments: attachments ?? this.attachments,
      uploadingAttachments: uploadingAttachments ?? this.uploadingAttachments,
    );
  }
}

/// Sessions that share a working directory.
class WorkspaceGroup {
  const WorkspaceGroup({required this.path, required this.sessions});

  /// Absolute `cwd`, or empty for sessions that never reported one.
  final String path;
  final List<SessionSummary> sessions;

  /// Last path segment, for the drawer label.
  String get label {
    if (path.isEmpty) return '未指定工作区';
    final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }
}

class AppController extends StateNotifier<AppState> {
  /// [clientFactory] exists for tests: it lets a fake transport stand in for the
  /// real one without a socket, a relay or a TLS handshake, and it is handed only
  /// the connection settings — a fake needs no [SecurityContext]. Production
  /// always leaves it null and gets the real client built in [configure].
  AppController({
    RelayClient Function(String baseUrl, String token)? clientFactory,
  })  : _clientFactory = clientFactory,
        super(const AppState());

  final RelayClient Function(String baseUrl, String token)? _clientFactory;

  /// Shared trust configuration. Cheap to share; the HTTP clients built from it
  /// are not, so each owner gets its own (see [newRelayHttpClient]).
  SecurityContext? _securityContext;
  RelayClient? _client;
  RelayEvents? _events;
  StreamSubscription<RelayEvent>? _eventSubscription;
  Timer? _poll;
  Timer? _refreshTimer;
  final Map<String, ApprovalAsk> _pendingAsks = {};
  int _signalTick = 0;

  String _baseUrl = '';
  String _token = '';

  RelayClient? get client => _client;
  RelayEvents? get events => _events;

  /// (Re)builds the transport for the given settings and probes the relay.
  Future<void> configure(RelaySettings settings) async {
    if (settings.baseUrl == _baseUrl && settings.token == _token && _client != null) {
      return;
    }
    _baseUrl = settings.baseUrl;
    _token = settings.token;

    await _teardown();

    if (settings.baseUrl.isEmpty) {
      state = state.copyWith(loading: false, error: null, clearError: true, devices: const []);
      return;
    }

    state = state.copyWith(loading: true, clearError: true);

    try {
      state = state.copyWith(caFingerprint: await relayCaFingerprint());
    } on Object catch (error) {
      state = state.copyWith(
        loading: false,
        error: '无法加载内置 CA：$error',
      );
      return;
    }

    // The transport is built before the trust store because a test's fake client
    // needs neither, but it must exist before [refresh] runs.
    final factory = _clientFactory;
    if (factory != null) {
      _client = factory(settings.baseUrl, settings.token);
    } else {
      try {
        _securityContext ??= await buildRelaySecurityContext();
      } on Object catch (error) {
        state = state.copyWith(
          loading: false,
          error: '无法加载内置 CA：$error',
        );
        return;
      }
      _client = RelayClient(
        baseUrl: settings.baseUrl,
        token: settings.token,
        httpClient: newRelayHttpClient(_securityContext!),
      );
    }

    await refresh();
    if (settings.token.isNotEmpty) {
      await _startEvents(_securityContext!);
      // Anything raised while this phone was away is still waiting on the relay.
      await refreshApprovals();
    }
  }

  Future<void> refresh() async {
    final client = _client;
    if (client == null) return;
    try {
      final health = await client.health();
      final devices = client.token.isEmpty ? <RelayDevice>[] : await client.devices();

      // Keep the current choice while it still exists; otherwise prefer an
      // online desktop, and fall back to anything known.
      var activeId = state.activeDeviceId;
      if (activeId.isEmpty || !devices.any((device) => device.id == activeId)) {
        String? firstOnline;
        for (final device in devices) {
          if (device.online) {
            firstOnline = device.id;
            break;
          }
        }
        activeId = firstOnline ?? (devices.isEmpty ? '' : devices.first.id);
      }

      state = state.copyWith(
        loading: false,
        clearError: true,
        health: health,
        devices: devices,
        activeDeviceId: activeId,
      );
      _schedulePoll();
      ensureSubscriptions();
      if (activeId.isNotEmpty) {
        await loadSessions();
      }
    } on RelayException catch (error) {
      state = state.copyWith(loading: false, error: error.toString());
    } on Object catch (error) {
      state = state.copyWith(loading: false, error: '$error');
    }
  }

  // -- sessions ------------------------------------------------------------

  /// Switches the drawer (and the conversation) to another desktop.
  Future<void> selectDevice(String deviceId) async {
    if (deviceId == state.activeDeviceId) return;
    // The catalog is per-device; drop it so the next chip tap reloads.
    _catalog = null;
    state = state.copyWith(
      activeDeviceId: deviceId,
      sessions: const [],
      clearActiveSession: true,
      workspace: '',
      clearSessionsError: true,
    );
    await loadSessions();
  }

  Future<void> loadSessions() async {
    final client = _client;
    final deviceId = state.activeDeviceId;
    if (client == null || deviceId.isEmpty) return;

    state = state.copyWith(sessionsLoading: true, clearSessionsError: true);
    try {
      final sessions = await client.sessions(deviceId);
      if (!mounted) return;
      state = state.copyWith(
        sessions: sessions,
        sessionsLoading: false,
        clearSessionsError: true,
      );
    } on RelayException catch (error) {
      if (!mounted) return;
      state = state.copyWith(sessionsLoading: false, sessionsError: error.toString());
    } on Object catch (error) {
      if (!mounted) return;
      state = state.copyWith(sessionsLoading: false, sessionsError: '$error');
    }
  }

  /// Opens an existing session in the main view.
  void openSession(String sessionId) {
    SessionSummary? found;
    for (final session in state.sessions) {
      if (session.sessionId == sessionId) found = session;
    }
    state = state.copyWith(
      activeSessionId: sessionId,
      workspace: found?.cwd ?? state.workspace,
    );
  }

  /// Switches the main view back to "start something new".
  void composeNew({String? workspace}) {
    state = state.copyWith(
      clearActiveSession: true,
      workspace: workspace ?? state.workspace,
    );
  }

  void setWorkspace(String path) {
    state = state.copyWith(workspace: path.trim());
  }

  /// Chooses the mode the next new task will be created with.
  ///
  /// Held in app state as well as settings: a prompt typed on the welcome screen
  /// creates the session itself, and must not quietly use a different mode.
  void setAgentPreset(String presetId) {
    state = state.copyWith(agentPreset: presetId.trim());
  }

  /// Creates a session and opens it. Returns the new id, or null on failure.
  ///
  /// [agentPreset] is the mode the task should run in (DSH's agent preset id). An
  /// empty value leaves the choice to the harness's own default, which is what a
  /// caller that never asked should get.
  Future<String?> createSession({String agentPreset = ''}) async {
    final client = _client;
    final deviceId = state.activeDeviceId;
    if (client == null || deviceId.isEmpty) return null;

    final preset = agentPreset.trim();
    state = state.copyWith(creatingSession: true, clearSessionsError: true);
    try {
      final value = await client.createSession(
        deviceId,
        cwd: state.workspace.isEmpty ? null : state.workspace,
        agentPreset: preset.isEmpty ? null : preset,
      );
      final sessionId = asString(value['sessionId']);
      if (!mounted) return null;
      state = state.copyWith(creatingSession: false);
      if (sessionId.isEmpty) {
        // The relay answered without an id; fall back to reloading the list.
        await loadSessions();
        return null;
      }
      await loadSessions();
      openSession(sessionId);
      return sessionId;
    } on Object catch (error) {
      if (!mounted) return null;
      state = state.copyWith(creatingSession: false, sessionsError: '$error');
      return null;
    }
  }

  // -- attachments ---------------------------------------------------------

  /// Stages one attachment. Returns an error message when it may not be sent.
  ///
  /// The size rule is checked here rather than only in the UI, so a call path
  /// that forgets to check cannot put an oversized body on the wire.
  String? addAttachment(PendingAttachment attachment) {
    if (state.attachments.any((existing) => existing.id == attachment.id)) {
      return null;
    }
    final reason = attachmentRejection(attachment);
    if (reason != null) return reason;
    state = state.copyWith(attachments: [...state.attachments, attachment]);
    return null;
  }

  void removeAttachment(String id) {
    state = state.copyWith(
      attachments: state.attachments.where((item) => item.id != id).toList(growable: false),
    );
  }

  void clearAttachments() {
    if (state.attachments.isEmpty) return;
    state = state.copyWith(attachments: const []);
  }

  /// Sends [text] with any staged attachments to the active session, creating
  /// one first when composing.
  ///
  /// Returns null on success, or a message to show the user.
  ///
  /// [onAccepted] fires once the harness has taken the prompt, with the
  /// `requestId` that was sent and the line the sender should see for it. The
  /// caller uses that to echo the turn locally: the durable `user/message` can
  /// arrive late (or not at all, if the follow stream went stale), and the
  /// sender's own message must not depend on that. DSH records the `requestId` as
  /// `source.rpcId`, so the echo is reconciled exactly later.
  ///
  /// Order matters. Every non-image attachment is uploaded first — the harness
  /// only accepts a file as a `{type:'file', receiptId}` block, so a failed
  /// upload must abort **before** any prompt is sent, leaving the draft intact.
  /// Then one `session.prompt` carries everything. The attachments are dropped
  /// only once that prompt has been accepted.
  Future<String?> sendPrompt(
    String text, {
    List<PendingAttachment>? attachments,
    void Function(String requestId, String echoText)? onAccepted,
  }) async {
    final client = _client;
    if (client == null) return '尚未连接中继。';

    final staged = attachments ?? state.attachments;
    if (text.trim().isEmpty && staged.isEmpty) return '先写点什么，或加一个附件。';

    for (final attachment in staged) {
      final reason = attachmentRejection(attachment);
      if (reason != null) return reason;
    }

    var sessionId = state.activeSessionId;
    if (sessionId == null) {
      sessionId = await createSession(agentPreset: state.agentPreset);
      if (sessionId == null) {
        return state.sessionsError ?? '无法新建会话。';
      }
    }

    final images = staged.where((item) => item.isImage).toList(growable: false);
    final files = staged.where((item) => !item.isImage).toList(growable: false);
    final receipts = <String, String>{};
    final requestId = 'app-${DateTime.now().microsecondsSinceEpoch}';

    if (files.isNotEmpty) {
      // Honest, visible progress: a 2 MB upload on a phone link is not instant,
      // and a frozen composer invites a second tap.
      state = state.copyWith(uploadingAttachments: true);
    }

    try {
      for (final file in files) {
        final receipt = await client.uploadFile(
          state.activeDeviceId,
          sessionId: sessionId,
          bytes: file.bytes,
          name: file.name,
        );
        receipts[file.id] = receipt;
      }

      await client.prompt(
        state.activeDeviceId,
        sessionId,
        contentBlocksFor(
          text: text,
          images: images,
          files: files,
          receipts: receipts,
        ),
        requestId: requestId,
      );
    } on Object catch (error) {
      // Nothing was accepted, so the draft survives and the user can retry.
      if (mounted) {
        state = state.copyWith(uploadingAttachments: false);
      }
      return '$error';
    }

    if (mounted) {
      state = state.copyWith(
        uploadingAttachments: false,
        attachments: const [],
      );
      onAccepted?.call(
        requestId,
        text.trim().isNotEmpty
            ? text.trim()
            : attachmentPlaceholder(
                images: images.length,
                files: files.length,
              ),
      );
    }
    return null;
  }

  /// Delivers an answer to an `ask_user_question` call. Returns an error
  /// message, or null on success.
  ///
  /// The questions themselves arrive in the durable session log (as the tool
  /// call's arguments), so nothing has to be pushed to the phone for the card to
  /// appear — only this answer travels back.
  ///
  /// The Remote answers with a boolean: `false` means the harness did **not**
  /// take the answer (the ask is a blocking one, which is answered through the
  /// answerer waterfall, or it is no longer pending). That is a failure, not a
  /// success — reporting it as success is how a discarded answer came to look
  /// delivered.
  Future<String?> answerQuestion({
    required String sessionId,
    required String callId,
    required List<Map<String, dynamic>> answers,
  }) async {
    final client = _client;
    if (client == null) return '尚未连接中继。';
    if (callId.isEmpty) return '这次提问没有可用的 callId。';
    try {
      final result = await client.answerQuestion(
        state.activeDeviceId,
        sessionId: sessionId,
        callId: callId,
        answers: answers,
      );
      final accepted = result['value'];
      if (accepted is bool && !accepted) {
        return '电脑没有接受这个回答（这次提问只能由电脑上的窗口作答）。';
      }
      return null;
    } on Object catch (error) {
      return '$error';
    }
  }

  /// The live pushed question ask that asks exactly [questionIds], if any.
  ///
  /// A question the desktop is still waiting on is answered through the **ask**
  /// (the `approval` frame), not through [answerQuestion]: the op only accepts a
  /// question the session projection has already marked `continued`, so on a
  /// blocking ask it answers `false` and the answer is thrown away. Matching is
  /// by session plus the exact set of question ids, so a card can never be routed
  /// to a different question.
  ApprovalAsk? liveQuestionFor(String sessionId, List<String> questionIds) {
    final wanted = [...questionIds]..sort();
    if (wanted.isEmpty) return null;

    for (final ask in state.approvals) {
      if (!ask.isQuestion || ask.sessionId != sessionId) continue;
      final ids = ask.questions.map((item) => asString(item['id'])).toList()..sort();
      if (ids.length != wanted.length) continue;
      var same = true;
      for (var index = 0; index < ids.length; index += 1) {
        if (ids[index] != wanted[index]) {
          same = false;
          break;
        }
      }
      if (same) return ask;
    }
    return null;
  }

  Future<String?> cancelActiveTurn() async {
    final client = _client;
    final sessionId = state.activeSessionId;
    if (client == null || sessionId == null) return null;
    try {
      await client.cancel(state.activeDeviceId, sessionId);
      return null;
    } on Object catch (error) {
      return '$error';
    }
  }

  /// The model catalog for the active device, loaded once and cached.
  ModelCatalog? get catalog => _catalog;

  ModelCatalog? _catalog;

  Future<ModelCatalog?> loadModelCatalog() async {
    final client = _client;
    final deviceId = state.activeDeviceId;
    if (client == null || deviceId.isEmpty) return null;
    if (_catalog != null) return _catalog;
    try {
      final loaded = await client.modelCatalog(deviceId);
      if (!mounted) return null;
      _catalog = loaded;
      state = state.copyWith();
      return loaded;
    } on Object catch (error) {
      if (mounted) state = state.copyWith(sessionsError: '$error');
      return null;
    }
  }

  /// Switches the active session's model. Returns an error message, or null.
  Future<String?> selectModel(ModelSelection selection) async {
    final client = _client;
    final sessionId = state.activeSessionId;
    if (client == null || sessionId == null) return '还没有打开任务。';
    try {
      await client.selectModel(
        state.activeDeviceId,
        sessionId: sessionId,
        selection: selection,
      );
      // The projection is the source of truth for what is displayed, so reload
      // rather than trusting the local guess.
      await loadSessions();
      return null;
    } on Object catch (error) {
      return '$error';
    }
  }

  /// Polls while the app is in the foreground. The event socket carries live
  /// session data; this only refreshes the cheap device/health summary.
  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _pollDevices());
  }

  /// Re-reads the task list soon, coalescing bursts.
  ///
  /// The follow stream tells the view *what* was appended; the projections that
  /// carry the footer numbers only come with a list read. Reading on every event
  /// would be a request per step, so the view asks for one read and gets it shortly
  /// after the burst stops. Without this the numbers were correct only at open,
  /// every 15s poll, or after a reconnect.
  void scheduleSessionRefresh() {
    if (_refreshTimer != null) return;
    _refreshTimer = Timer(const Duration(milliseconds: 800), () {
      _refreshTimer = null;
      if (mounted) unawaited(loadSessions());
    });
  }

  Future<void> _pollDevices() async {
    final client = _client;
    if (client == null || client.token.isEmpty) return;
    try {
      final devices = await client.devices();
      state = state.copyWith(devices: devices, clearError: true);
    } on Object {
      // Transient failures are expected; the UI shows the last known state.
    }
    // The chat's footer numbers come from the session projections, which arrive
    // with a list read or a follow snapshot. While a turn is running, re-read the
    // list so they move — otherwise the line freezes at whatever it said when the
    // stream opened, and a finished turn looks like it never counted.
    if (state.activeSession?.running ?? false) {
      await loadSessions();
    }
  }

  Future<void> _startEvents(SecurityContext context) async {
    final client = _client;
    if (client == null || client.token.isEmpty) return;

    // Its own HttpClient, so that disposing the event socket never disturbs the
    // request client.
    _events = RelayEvents(
      baseUrl: client.baseUrl,
      token: client.token,
      httpClient: newRelayHttpClient(context),
    );
    _eventSubscription = _events!.events.listen(handleEvent);
    _events!.state.listen((next) {
      if (!mounted) return;
      state = state.copyWith(
        eventsState: next,
        eventsError: _events?.lastError ?? '',
      );
      // Catch up on anything raised while the socket was down. Without this a
      // question asked during a disconnect is simply lost — the desktop times
      // out and the phone never knew.
      if (next == RelayEventsState.connected) {
        unawaited(refreshApprovals());
      }
    });

    // One subscription per desktop: approvals and session status are device
    // scoped, and the relay fans them out per subscription.
    for (final device in state.devices) {
      _subscribeDevice(device.id);
    }

    await _events!.start();
  }

  void _subscribeDevice(String deviceId) {
    _events?.subscribe('asks:$deviceId', deviceId, ['approval.ask', 'question.ask']);
    _events?.subscribe('status:$deviceId', deviceId, ['session.status', 'session.activity']);
  }

  /// Ensures live subscriptions exist for every known desktop.
  void ensureSubscriptions() {
    for (final device in state.devices) {
      _subscribeDevice(device.id);
    }
  }

  /// Handles one frame from the event socket.
  ///
  /// Public so tests can drive it directly: exercising this through a real socket
  /// would mean standing up a WebSocket server for a five-line dispatch table.
  void handleEvent(RelayEvent event) {
    if (!mounted) return;
    switch (event.topic) {
      case 'approval.ask':
      case 'question.ask':
        final ask = ApprovalAsk.fromEvent(
          event.topic,
          event.payload,
          deviceId: event.deviceId,
        );
        if (ask.askId.isEmpty) return;
        _pendingAsks[ask.askId] = ask;
        state = state.copyWith(approvals: _pendingAsks.values.toList());
      case 'approval.settled':
        final askId = asString(event.payload['askId']);
        if (_pendingAsks.remove(askId) != null) {
          state = state.copyWith(approvals: _pendingAsks.values.toList());
        }
      case 'session.status':
      case 'session.activity':
        // "The desktop moved." The open chat screen compares this against what its
        // own (silence-prone) follow stream has delivered — see [AppState.lastSignal].
        final sessionId = asString(event.payload['sessionId']);
        if (sessionId.isEmpty) return;
        _signalTick += 1;
        state = state.copyWith(
          lastSignal: SessionSignal(sessionId: sessionId, tick: _signalTick),
        );
      default:
        break;
    }
  }

  /// Answers an approval or question. Removes it optimistically so the card
  /// cannot be double-submitted.
  Future<void> decide(
    ApprovalAsk ask,
    String decision, {
    List<Map<String, dynamic>>? answers,
  }) async {
    final client = _client;
    if (client == null) return;
    _pendingAsks.remove(ask.askId);
    state = state.copyWith(approvals: _pendingAsks.values.toList());
    try {
      await client.decideApproval(ask.askId, decision, answers: answers);
    } on RelayException catch (error) {
      // 404 means the ask already expired or was answered on the desktop.
      if (!error.toString().contains('unknown_ask')) {
        state = state.copyWith(error: error.toString());
      }
    }
  }

  /// Pulls the relay's pending list and merges it into the local one.
  ///
  /// Merging rather than replacing: the socket may have delivered an ask that
  /// this response predates.
  Future<void> refreshApprovals() async {
    final client = _client;
    if (client == null || client.token.isEmpty) return;
    try {
      final asks = await client.pendingApprovals();
      if (!mounted) return;
      for (final ask in asks) {
        if (ask.askId.isEmpty) continue;
        _pendingAsks.putIfAbsent(ask.askId, () => ask);
      }
      // Drop anything the relay no longer knows about: it expired or was
      // answered elsewhere.
      final live = {for (final ask in asks) ask.askId};
      _pendingAsks.removeWhere((askId, _) => !live.contains(askId));
      state = state.copyWith(approvals: _pendingAsks.values.toList());
    } on Object {
      // Best effort; the socket remains the primary path.
    }
  }

  Future<void> _teardown() async {
    _poll?.cancel();
    _poll = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _events?.dispose();
    _events = null;
    _client?.close();
    _client = null;
    _pendingAsks.clear();
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
