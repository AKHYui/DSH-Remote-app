/// Display formatting for [SessionMetrics].
///
/// The desktop renders these numbers with its own helpers (`formatTokens`,
/// `formatTokensPerSecond`, `formatCacheHitPercent` in
/// `dsh-client-ui-chat/lib/client.js`, and `contextOccupancy` in
/// `dsh-client-ui-conversation/lib/client.js`). These mirror them, so the phone's
/// line reads the same as the one on the computer — the fixtures in
/// `test/metrics_test.dart` are values read from live sessions.
library;

import '../api/models.dart';

/// Compact token count, the way the desktop prints it: `999`, `4.8K`, `326M`.
///
/// Below a thousand: the digits as they are. Below a million: kilo with one
/// decimal, dropped once the value reaches 100. Above: mega, same rule.
String compactTokens(int value) {
  if (value < 0) return '0';
  if (value < 1000) return '$value';
  if (value < 1000000) return '${_scaled(value / 1000)}K';
  return '${_scaled(value / 1000000)}M';
}

/// One decimal below 100, none at or above it — the desktop's rule.
String _scaled(double value) {
  if (value >= 100) return value.round().toString();
  final tenths = (value * 10).round();
  return tenths % 10 == 0 ? '${tenths ~/ 10}' : '${tenths ~/ 10}.${tenths % 10}';
}

/// Decode speed: a whole number at 10 tok/s and above, one decimal below.
String tokensPerSecondLabel(double value) {
  final safe = value.isFinite && value > 0 ? value : 0.0;
  if (safe >= 10) return safe.round().toString();
  final tenths = (safe * 10).round();
  return tenths % 10 == 0 ? '${tenths ~/ 10}' : '${tenths ~/ 10}.${tenths % 10}';
}

/// Cache-hit share as a percentage.
///
/// A partial hit is never rounded up into a perfect one: 99.96% prints as `99.9%`
/// rather than claiming every token came from the cache. Only an exact 100% — a
/// session where nothing at all was billed uncached — prints as `100%`.
String cacheHitLabel(double ratio) {
  final percent = (ratio.isFinite && ratio > 0 ? ratio : 0.0) * 100;
  if (percent >= 100) return '100%';
  final rounded = percent.round();
  if (rounded < 100) return '$rounded%';
  final tenths = (percent * 10).floor();
  return '${tenths ~/ 10}.${tenths % 10}%';
}

/// The pieces of the status line, in the order the desktop shows them.
///
/// Returned as segments rather than one string so the widget owns the spacing, and
/// so a test can assert on the numbers without matching layout. An empty list
/// means "nothing worth showing" — callers hide the row instead of drawing a blank.
List<String> metricsSegments(SessionMetrics metrics) {
  final segments = <String>[];
  if (metrics.hasActivity) {
    segments.add('${metrics.turns} 轮 ${metrics.steps} 步');
    final speed = metrics.tokensPerSecond;
    if (speed != null && metrics.decodeTokens > 0) {
      segments.add('${tokensPerSecondLabel(speed)} tok/s');
    }
    segments.add('${compactTokens(metrics.totalTokens)} tok');
    final hit = metrics.cacheHitRatio;
    if (hit != null) segments.add('缓存命中 ${cacheHitLabel(hit)}');
  }
  final context = metrics.contextPercent;
  if (context != null) segments.add('已用上下文 $context%');
  return segments;
}

/// The detailed breakdown shown when the line is tapped.
///
/// Kept next to the formatters because it is the same numbers under the same rules,
/// just spelled out — the line is deliberately terse, this is what makes it
/// checkable against the desktop.
List<(String, String)> metricsDetail(SessionMetrics metrics) {
  final rows = <(String, String)>[];
  if (metrics.hasActivity) {
    rows.add(('轮次 / 步骤', '${metrics.turns} / ${metrics.steps}'));
    final speed = metrics.tokensPerSecond;
    if (speed != null && metrics.decodeTokens > 0) {
      rows.add((
        '生成速度',
        '${tokensPerSecondLabel(speed)} tok/s'
            '（${compactTokens(metrics.decodeTokens)} tok / '
            '${(metrics.decodeMs / 1000).toStringAsFixed(1)} s）',
      ));
    }
    rows.add(('未缓存输入', '${compactTokens(metrics.uncachedInputTokens)} tok'));
    rows.add(('缓存读 / 写',
        '${compactTokens(metrics.cacheReadTokens)} / ${compactTokens(metrics.cacheWriteTokens)} tok'));
    rows.add(('输出', '${compactTokens(metrics.outputTokens)} tok'));
    rows.add(('累计', '${compactTokens(metrics.totalTokens)} tok'));
    final hit = metrics.cacheHitRatio;
    if (hit != null) rows.add(('缓存命中', cacheHitLabel(hit)));
  }
  final used = metrics.contextUsedTokens;
  final percent = metrics.contextPercent;
  if (used != null && percent != null) {
    rows.add((
      '上下文',
      '${compactTokens(used)} / ${compactTokens(metrics.contextWindow)}'
          '（$percent%）',
    ));
  }
  return rows;
}
