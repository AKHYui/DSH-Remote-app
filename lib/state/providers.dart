/// Provider wiring. Everything is derived from [settingsProvider] on down.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_controller.dart';
import 'settings.dart';

final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});

final settingsProvider = StateNotifierProvider<SettingsController, RelaySettings>((ref) {
  return SettingsController(ref.watch(secureStorageProvider));
});

final appControllerProvider = StateNotifierProvider<AppController, AppState>((ref) {
  return AppController();
});
