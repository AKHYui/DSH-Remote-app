/// Turns a transport exception into something a user can act on.
///
/// This is the layer that decides what a failed tap actually says. It exists as
/// a standalone function because it is the difference between "no response" and
/// "连不上 39.100.70.90:58443 的端口" — the first is what the user saw when this
/// text was buried below the fold, and the wording is worth unit testing.
library;

import '../api/models.dart';

String explainRelayError(Object error, {required String baseUrl}) {
  if (error is RelayException) {
    switch (error.code) {
      case 'pair_not_ready':
        return '配对码还不能用：未知、已过期、已使用，或还没被管理员批准。';
      case 'unauthorized':
        return '令牌无效或已被撤销。';
      case 'rate_limited':
        return '操作太频繁，请稍后再试。';
      case 'device_offline':
      case 'link_lost':
        return '那台电脑现在不在线。确认 DSH 正在运行，且插件已连上中继。';
      case 'op_not_supported':
        return '中继不允许这个操作。';
      default:
        return error.toString();
    }
  }

  final text = error.toString();

  if (text.contains('HandshakeException') ||
      text.contains('CERTIFICATE') ||
      text.contains('certificate verify failed')) {
    return 'TLS 校验失败：这台手机不信任中继的证书。\n'
        '确认 App 内置的 assets/ca.crt 与签发中继证书的 CA 是同一个。';
  }
  if (text.contains('Failed host lookup') || text.contains('nodename nor servname')) {
    return '域名解析失败：这台手机找不到 $baseUrl 的主机。\n检查地址是否写对、手机是否能上网。';
  }
  if (text.contains('Connection refused')) {
    return '连接被拒绝：$baseUrl 没有在监听。\n检查中继是否在运行、端口是否写对。';
  }
  if (text.contains('timed out') || text.contains('TimeoutException')) {
    return '连接超时：$baseUrl 没有响应。\n'
        '常见原因：中继未运行、云安全组没放行该端口、或手机网络到不了这台服务器。';
  }
  if (text.contains('SocketException')) {
    return '网络不可达：$baseUrl\n$text';
  }
  return text;
}
