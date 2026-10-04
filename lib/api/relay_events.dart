/// The phone event channel: one WebSocket carrying subscriptions and pushes.
///
/// The relay pushes device-level frames at any time (`device.status` has a null
/// `subId`), so consumers must dispatch by `topic` and never assume that the
/// frame after a `sub` is that subscription's acknowledgement.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

enum RelayEventsState { idle, connecting, connected, stopped }

class _Subscription {
  _Subscription({
    required this.id,
    required this.deviceId,
    required this.topics,
    required this.args,
  });

  final String id;
  final String deviceId;
  final List<String> topics;
  final Map<String, dynamic> args;
}

class RelayEvents {
  RelayEvents({
    required this.baseUrl,
    required this.token,
    required HttpClient httpClient,
  }) : _http = httpClient;

  final String baseUrl;
  final String token;
  final HttpClient _http;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _attempt = 0;
  bool _stopped = true;

  /// Why the last connection attempt failed. Empty while things are fine.
  ///
  /// Surfaced rather than swallowed: a socket that quietly retries forever looks
  /// identical to one that is working, which is how a wrong URL scheme went
  /// unnoticed.
  String get lastError => _lastError;
  String _lastError = '';

  final Map<String, _Subscription> _subscriptions = {};
  final StreamController<RelayEvent> _events = StreamController<RelayEvent>.broadcast();
  final StreamController<RelayEventsState> _state =
      StreamController<RelayEventsState>.broadcast();
  RelayEventsState _current = RelayEventsState.idle;

  Stream<RelayEvent> get events => _events.stream;
  Stream<RelayEventsState> get state => _state.stream;
  RelayEventsState get currentState => _current;
  bool get isConnected => _current == RelayEventsState.connected;

  /// Subscriptions survive a reconnect: they are re-sent automatically.
  void subscribe(
    String id,
    String deviceId,
    List<String> topics, [
    Map<String, dynamic> args = const {},
  ]) {
    _subscriptions[id] = _Subscription(id: id, deviceId: deviceId, topics: topics, args: args);
    _sendSubscription(_subscriptions[id]!);
  }

  void unsubscribe(String id) {
    if (_subscriptions.remove(id) == null) return;
    _send({'t': 'unsub', 'id': id});
  }

  void unsubscribeDevice(String deviceId) {
    for (final id in _subscriptions.entries
        .where((entry) => entry.value.deviceId == deviceId)
        .map((entry) => entry.key)
        .toList()) {
      unsubscribe(id);
    }
  }

  Future<void> start() async {
    _stopped = false;
    await _open();
  }

  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _socket?.close();
    _socket = null;
    _setState(RelayEventsState.stopped);
  }

  Future<void> dispose() async {
    await stop();
    // This instance owns its HttpClient (see `newRelayHttpClient`), so it closes
    // it; leaving it open would leak a connection pool per reconfigure.
    _http.close(force: true);
    await _events.close();
    await _state.close();
  }

  // -- internals -----------------------------------------------------------

  void _setState(RelayEventsState next) {
    if (_current == next) return;
    _current = next;
    if (!_state.isClosed) _state.add(next);
  }

  Uri get _eventsUri {
    // The relay serves the socket on the same port as HTTPS, so the scheme has
    // to be translated: `WebSocket.connect` takes ws/wss, not https. Passing the
    // https URL straight through made every attempt fail and the socket retry
    // forever, which in the UI looked like a permanent "reconnecting".
    final base = Uri.parse(baseUrl);
    final path = '${base.path.replaceAll(RegExp(r'/+$'), '')}/api/v1/events';
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: path,
      query: '',
    );
  }

  Future<void> _open() async {
    if (_stopped) return;
    _setState(RelayEventsState.connecting);

    // The token travels in a header, not the query string: `dart:io` can set
    // WebSocket headers, and a header never lands in the relay's access log.
    try {
      final socket = await WebSocket.connect(
        _eventsUri.toString(),
        headers: {'Authorization': 'Bearer $token'},
        customClient: _http,
      );
      _socket = socket;
      _attempt = 0;
      _lastError = '';
      _lastFrameAt = DateTime.now();
      _setState(RelayEventsState.connected);
      _socketSubscription = socket.listen(
        _onFrame,
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: true,
      );
      _startHeartbeat();
      for (final subscription in _subscriptions.values) {
        _sendSubscription(subscription);
      }
    } on Object catch (error) {
      _lastError = '$error';
      _setState(RelayEventsState.idle);
      _scheduleReconnect();
    }
  }

  void _onDisconnected() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _socketSubscription = null;
    _socket = null;
    if (_stopped) {
      _setState(RelayEventsState.stopped);
      return;
    }
    _setState(RelayEventsState.idle);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped || _reconnectTimer != null) return;
    _attempt += 1;
    final seconds = (1 << (_attempt - 1)).clamp(1, 30);
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      _open();
    });
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      // A silent socket is worse than a closed one: it looks connected while
      // nothing arrives. Treat a long silence as a dead link.
      if (DateTime.now().difference(_lastFrameAt) > const Duration(seconds: 55)) {
        _socket?.close();
        _onDisconnected();
        return;
      }
      _send({'t': 'ping', 'id': 'hb-${DateTime.now().millisecondsSinceEpoch}'});
    });
  }

  void _onFrame(dynamic raw) {
    _lastFrameAt = DateTime.now();
    if (raw is! String) return;
    Map<String, dynamic> frame;
    try {
      frame = asMap(jsonDecode(raw));
    } on FormatException {
      return;
    }
    switch (asString(frame['t'])) {
      case 'ready':
      case 'ack':
      case 'pong':
        return;
      case 'error':
        final error = asMap(frame['error']);
        if (!_events.isClosed) {
          // Surfaced as an event so the UI can show it next to the subscription.
          _events.add(RelayEvent(
            topic: 'subscription.error',
            deviceId: '',
            subId: frame['id'] as String?,
            payload: error,
          ));
        }
        return;
      case 'evt':
        if (!_events.isClosed) _events.add(RelayEvent.fromJson(frame));
        return;
      default:
        return;
    }
  }

  void _sendSubscription(_Subscription subscription) {
    _send({
      't': 'sub',
      'id': subscription.id,
      'deviceId': subscription.deviceId,
      'topics': subscription.topics,
      'args': subscription.args,
    });
  }

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(jsonEncode(frame));
    } on StateError {
      // Socket went away between the null check and the write.
    }
  }
}
