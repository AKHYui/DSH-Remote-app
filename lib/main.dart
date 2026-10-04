/// Entry point. One `MaterialApp`, two top-level destinations: onboarding until
/// there is a usable token, then the conversation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/providers.dart';
import 'state/settings.dart';
import 'theme.dart';
import 'ui/home_screen.dart';
import 'ui/setup_screen.dart';

void main() {
  runApp(const ProviderScope(child: DshRemoteApp()));
}

class DshRemoteApp extends ConsumerWidget {
  const DshRemoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuild the transport whenever the relay or token changes. This also
    // covers the very first load, because the settings controller notifies once
    // it has read the keystore.
    ref.listen<RelaySettings>(settingsProvider, (previous, next) {
      if (previous?.baseUrl == next.baseUrl && previous?.token == next.token) return;
      ref.read(appControllerProvider.notifier).configure(next);
    });

    final settings = ref.watch(settingsProvider);

    return MaterialApp(
      title: 'DSH Remote',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: settings.isReady ? const HomeScreen() : const SetupScreen(),
    );
  }
}
