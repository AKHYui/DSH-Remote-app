/// TLS trust for the relay.
///
/// The relay presents a certificate signed by an internal CA that no platform
/// trust store knows about. Two ways to make Dart accept it:
///
///   * add the CA to the OS store — does **not** work on Android 7+, where apps
///     ignore user-installed CAs unless they opt in via `networkSecurityConfig`;
///   * load the CA into a `SecurityContext` and hand that to the `HttpClient`
///     used for both HTTP and the WebSocket.
///
/// This does the second, which works the same on Android, iOS and desktop and
/// keeps the trust decision inside the app.
///
/// Ownership rule: a [SecurityContext] is cheap to share, but an [HttpClient] is
/// **not** — `IOClient.close()` closes the `HttpClient` it was handed, so every
/// owner (each `RelayClient`, each `RelayEvents`) must get its own. See
/// [newRelayHttpClient].
library;

import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;

/// Asset path of the bundled CA. Kept in step with `pubspec.yaml`.
const String kRelayCaAsset = 'assets/ca.crt';

/// Builds a [SecurityContext] that trusts the bundled CA *in addition to* the
/// platform roots, so ordinary public HTTPS still works.
///
/// Throws [TlsException] only if the asset is missing or not a valid PEM; a
/// certificate that is merely already trusted is tolerated.
Future<SecurityContext> buildRelaySecurityContext({
  String assetPath = kRelayCaAsset,
}) async {
  final data = await rootBundle.load(assetPath);
  final pem = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

  final context = SecurityContext(withTrustedRoots: true);
  try {
    context.setTrustedCertificatesBytes(pem);
  } on TlsException catch (error) {
    // "Certificate already in trust store" is harmless; anything else is not.
    final message = error.message.toUpperCase();
    final duplicate = message.contains('ALREADY') || message.contains('EXIST');
    if (!duplicate) rethrow;
  }
  return context;
}

/// A fresh HTTP client for one owner, backed by a shared [context].
///
/// Never hand the same instance to two owners: closing one would break the
/// other. That is not hypothetical — the app used to share a single client
/// between the client and the event socket, and re-configuring after pairing
/// tore down the new client with "Bad state: Client is closed".
///
/// [idleTimeout] is deliberately short. Dart keeps pooled connections alive for
/// 15 seconds by default while the relay (uvicorn) closes idle ones after 5, so
/// a reused connection could already be dead — surfacing as
/// "Connection closed before full header was received" on an otherwise healthy
/// link. Expiring locally first removes the race; `RelayClient` also retries
/// idempotent GETs once as a backstop.
HttpClient newRelayHttpClient(
  SecurityContext context, {
  Duration connectionTimeout = const Duration(seconds: 15),
  Duration idleTimeout = const Duration(seconds: 3),
}) {
  return HttpClient(context: context)
    ..connectionTimeout = connectionTimeout
    ..idleTimeout = idleTimeout
    ..userAgent = 'dsh-remote-app/0.1';
}

/// Convenience for one-shot callers that build and close a client immediately.
Future<HttpClient> buildRelayHttpClient({
  String assetPath = kRelayCaAsset,
  Duration connectionTimeout = const Duration(seconds: 15),
  Duration idleTimeout = const Duration(seconds: 3),
}) async {
  return newRelayHttpClient(
    await buildRelaySecurityContext(assetPath: assetPath),
    connectionTimeout: connectionTimeout,
    idleTimeout: idleTimeout,
  );
}

/// The SHA-256 fingerprint of the bundled CA, for the settings screen.
///
/// Showing this lets the user confirm the app is pinned to the CA they actually
/// created, instead of trusting a build artefact they cannot inspect.
Future<String> relayCaFingerprint({String assetPath = kRelayCaAsset}) async {
  final data = await rootBundle.load(assetPath);
  final pem = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final digest = sha256.convert(pem).bytes;
  return digest
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}
