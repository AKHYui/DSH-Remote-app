/// Tests for the exception → message mapping.
///
/// Practically every one of these strings is what a user reads at the exact
/// moment something is broken, so the mapping is worth pinning down: a raw
/// `ClientException with SocketException: ...` is technically accurate and
/// useless, while "连接被拒绝 / 超时 / 证书不受信任" tells them what to do.
library;

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/ui/error_text.dart';
import 'package:flutter_test/flutter_test.dart';

const _base = 'https://39.100.70.90:58443';

String explain(Object error) => explainRelayError(error, baseUrl: _base);

void main() {
  group('relay error codes', () {
    test('an unapproved pairing code explains itself', () {
      expect(explain(const RelayException('pair_not_ready', 'nope')), contains('还没被管理员批准'));
    });

    test('a revoked token says so', () {
      expect(explain(const RelayException('unauthorized', '401')), contains('已被撤销'));
    });

    test('rate limiting is named', () {
      expect(explain(const RelayException('rate_limited', '429')), contains('太频繁'));
    });

    test('an offline desktop is distinguished from a network failure', () {
      final message = explain(const RelayException('device_offline', 'gone'));
      expect(message, contains('不在线'));
      expect(message, isNot(contains('网络')));
    });

    test('an unknown code falls back to the error itself', () {
      expect(explain(const RelayException('weird', 'something odd')), 'weird: something odd');
    });
  });

  group('transport failures', () {
    test('a certificate problem points at the bundled CA', () {
      final message = explain(Exception('HandshakeException: CERTIFICATE_VERIFY_FAILED'));
      expect(message, contains('TLS'));
      expect(message, contains('ca.crt'));
    });

    test('a DNS failure names the host', () {
      final message = explain(Exception('SocketException: Failed host lookup: nonexistent'));
      expect(message, contains('域名解析失败'));
    });

    test('a refused connection names the address', () {
      final message = explain(Exception('SocketException: Connection refused (OS Error)'));
      expect(message, contains('连接被拒绝'));
      expect(message, contains(_base));
    });

    test('a timeout suggests the firewall, not the address', () {
      final message = explain(Exception(
        'ClientException with SocketException: HTTP connection timed out after 0:00:15.000000, '
        'host: 39.100.70.90, port: 58443',
      ));
      expect(message, contains('连接超时'));
      expect(message, contains('安全组'));
    });

    test('a bare socket error is shown but prefixed', () {
      final message = explain(Exception('SocketException: Broken pipe'));
      expect(message, contains('网络不可达'));
    });

    test('anything unrecognised is passed through unchanged', () {
      expect(explain(Exception('totally unexpected')), contains('totally unexpected'));
    });
  });
}
