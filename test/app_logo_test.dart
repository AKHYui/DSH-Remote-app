/// The in-app logo is the app icon.
///
/// Both places that draw a logo — the welcome hero and the drawer header — used to
/// draw a stand-in: a rounded square with `Icons.terminal_rounded`. The launcher
/// icon is a different picture, so the icon the user tapped and the screen they
/// landed on did not match. These tests pin the replacement, and pin the asset
/// itself, because a missing asset fails silently on a device (an empty box) when
/// nothing asserts on it.
library;

import 'dart:io';

import 'package:dsh_remote_app/api/relay_client.dart';
import 'package:dsh_remote_app/state/app_controller.dart';
import 'package:dsh_remote_app/state/providers.dart';
import 'package:dsh_remote_app/state/settings.dart';
import 'package:dsh_remote_app/theme.dart';
import 'package:dsh_remote_app/ui/app_drawer.dart';
import 'package:dsh_remote_app/ui/app_logo.dart';
import 'package:dsh_remote_app/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<AppController> _controller() async {
  final controller = AppController(
    clientFactory: (baseUrl, token) => RelayClient(
      baseUrl: 'https://relay.invalid',
      httpClient: HttpClient(),
    ),
  );
  await controller.configure(const RelaySettings(baseUrl: 'https://relay.invalid'));
  controller.state = controller.state.copyWith(activeDeviceId: 'device-1');
  return controller;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  final controller = await _controller();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(theme: buildAppTheme(), home: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  test('the logo asset is bundled and is the icon artwork', () async {
    final file = File(kAppLogoAsset);
    expect(file.existsSync(), isTrue, reason: 'assets/logo.png must be in the repo');

    // 384px, generated from tool/icon/app_icon.png. A stub or a truncated file
    // would still "exist", so check the size band too.
    final bytes = await file.length();
    expect(bytes, greaterThan(20 * 1024));
    expect(bytes, lessThan(400 * 1024));

    final bytesOnDisk = await file.readAsBytes();
    // PNG magic number: it really is a PNG, not a renamed placeholder.
    expect(bytesOnDisk.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  });

  testWidgets('the welcome screen shows the app icon, not a stand-in glyph', (tester) async {
    await _pump(tester, const HomeScreen());

    expect(find.byType(AppLogo), findsOneWidget);
    expect(
      find.byIcon(Icons.terminal_rounded),
      findsNothing,
      reason: 'the hero used to draw a terminal glyph',
    );
  });

  testWidgets('the drawer header shows the app icon, not a stand-in glyph', (tester) async {
    await _pump(tester, const Scaffold(body: AppDrawer()));

    expect(find.byType(AppLogo), findsOneWidget);
    expect(
      find.byIcon(Icons.terminal_rounded),
      findsNothing,
      reason: 'the drawer badge used to draw a terminal glyph',
    );
  });
}
