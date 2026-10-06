/// Persistent app settings: which relay to talk to, and the device token.
///
/// The token is a live credential, so it lives in the platform keystore via
/// `flutter_secure_storage` — never in SharedPreferences, never in the repo.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RelaySettings {
  const RelaySettings({
    this.baseUrl = '',
    this.token = '',
    this.deviceName = 'my phone',
    this.lastDeviceId = '',
    this.lastAgentPreset = '',
  });

  /// e.g. `https://39.100.70.90:58443`
  final String baseUrl;

  /// Device token issued by the relay after pairing.
  final String token;

  /// Label sent when starting a pairing, and shown on the relay.
  final String deviceName;

  /// The desktop the user last opened, so the app can resume there.
  final String lastDeviceId;

  /// The agent preset (mode) the last task was created with.
  ///
  /// Empty means "the user has never chosen" — the new-task sheet then pre-selects
  /// DSH's shipped default rather than pretending a choice was made.
  final String lastAgentPreset;

  bool get hasRelay => baseUrl.isNotEmpty;
  bool get isReady => baseUrl.isNotEmpty && token.isNotEmpty;

  RelaySettings copyWith({
    String? baseUrl,
    String? token,
    String? deviceName,
    String? lastDeviceId,
    String? lastAgentPreset,
  }) {
    return RelaySettings(
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      deviceName: deviceName ?? this.deviceName,
      lastDeviceId: lastDeviceId ?? this.lastDeviceId,
      lastAgentPreset: lastAgentPreset ?? this.lastAgentPreset,
    );
  }

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'token': token,
        'deviceName': deviceName,
        'lastDeviceId': lastDeviceId,
        'lastAgentPreset': lastAgentPreset,
      };

  static RelaySettings fromJson(Map<String, dynamic> json) => RelaySettings(
        baseUrl: (json['baseUrl'] as String?) ?? '',
        token: (json['token'] as String?) ?? '',
        deviceName: (json['deviceName'] as String?) ?? 'my phone',
        lastDeviceId: (json['lastDeviceId'] as String?) ?? '',
        lastAgentPreset: (json['lastAgentPreset'] as String?) ?? '',
      );

  /// Normalises what the user typed into a base URL the client can use.
  ///
  /// Accepts `39.100.70.90:58443`, `http://…`, `ws://…`, with or without a path,
  /// and always yields `https://host[:port]` because the relay is TLS-only.
  static String normaliseBaseUrl(String input) {
    var value = input.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('wss://')) value = 'https://${value.substring(6)}';
    if (value.startsWith('ws://')) value = 'https://${value.substring(5)}';
    if (value.startsWith('http://')) value = 'https://${value.substring(7)}';
    if (!value.startsWith('https://')) value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return '';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return 'https://${uri.host}$port';
  }
}

class SettingsController extends StateNotifier<RelaySettings> {
  SettingsController(this._storage) : super(const RelaySettings()) {
    _load();
  }

  static const _key = 'dsh-relay-settings-v1';

  final FlutterSecureStorage _storage;
  bool _loaded = false;

  bool get loaded => _loaded;

  Future<void> _load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw != null && raw.isNotEmpty) {
        state = RelaySettings.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        );
      }
    } on Object {
      // A corrupt or unreadable store must not brick the app; start empty.
    } finally {
      _loaded = true;
      // Riverpod state assignment before listeners attach is fine, but the UI
      // needs to know loading finished.
      state = state.copyWith();
    }
  }

  Future<void> _persist() async {
    try {
      await _storage.write(key: _key, value: jsonEncode(state.toJson()));
    } on Object {
      // Persisting is best-effort; the in-memory value still works this session.
    }
  }

  Future<void> setRelay({required String baseUrl, required String deviceName}) async {
    state = state.copyWith(
      baseUrl: RelaySettings.normaliseBaseUrl(baseUrl),
      deviceName: deviceName.trim().isEmpty ? 'my phone' : deviceName.trim(),
    );
    await _persist();
  }

  Future<void> setToken(String token) async {
    state = state.copyWith(token: token.trim());
    await _persist();
  }

  Future<void> rememberDevice(String deviceId) async {
    state = state.copyWith(lastDeviceId: deviceId);
    await _persist();
  }

  /// Remembers the mode a task was created with, so the next sheet pre-selects it.
  Future<void> rememberPreset(String presetId) async {
    if (presetId.isEmpty || presetId == state.lastAgentPreset) return;
    state = state.copyWith(lastAgentPreset: presetId);
    await _persist();
  }

  Future<void> signOut() async {
    state = RelaySettings(baseUrl: state.baseUrl, deviceName: state.deviceName);
    await _persist();
  }
}
