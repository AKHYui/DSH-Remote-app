/// The footer numbers, pinned against values read from live sessions.
///
/// The formulas are copied from the desktop's own helpers, so these tests use
/// *real* readings as fixtures: if a formula drifts, the expected string here stops
/// matching. Two independent live samples are used (a big session and a small one),
/// plus the edge cases the desktop handles by rendering nothing.
library;

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/chat/metrics.dart';
import 'package:flutter_test/flutter_test.dart';

/// A projection block shaped like `session.list` / follow-snapshot output.
Map<String, dynamic> projections({
  required int asOfSeq,
  int turns = 0,
  int steps = 0,
  int decodeTokens = 0,
  int decodeMs = 0,
  int uncachedInput = 0,
  int output = 0,
  int cacheRead = 0,
  int cacheWrite = 0,
  int? pressure,
  int? projected,
  int? window,
}) {
  return {
    'kind': 'sequenced',
    'asOfSeq': asOfSeq,
    'values': {
      'sessionStats': {
        'turns': turns,
        'steps': steps,
        'decodeTokens': decodeTokens,
        'decodeMs': decodeMs,
      },
      'tokenUsage': {
        'uncachedInputTokens': uncachedInput,
        'outputTokens': output,
        'cacheReadTokens': cacheRead,
        'cacheWriteTokens': cacheWrite,
      },
      if (window != null)
        'contextPressure': {
          if (pressure != null) 'pressureTokens': pressure,
          if (projected != null) 'projectedTokens': projected,
          'contextWindow': window,
        },
    },
  };
}

void main() {
  group('live fixtures', () {
    test('a long session reads back exactly what the desktop shows', () {
      // Read from session-c8f75425-… while it was running.
      final metrics = SessionMetrics.fromProjections(projections(
        asOfSeq: 5152,
        turns: 15,
        steps: 847,
        decodeTokens: 569836,
        decodeMs: 2288904,
        uncachedInput: 2475515,
        output: 569836,
        cacheRead: 319141248,
        cacheWrite: 0,
        pressure: 338750,
        projected: 340182,
        window: 1000000,
      ));

      expect(metrics.turns, 15);
      expect(metrics.steps, 847);
      expect(metrics.tokensPerSecond, closeTo(248.9, 0.1));
      expect(metrics.totalTokens, 322186599);
      expect(metrics.cacheHitRatio, closeTo(0.99230, 0.00001));
      expect(metrics.contextPercent, 34);
      expect(
        metricsSegments(metrics),
        ['15 轮 847 步', '249 tok/s', '322M tok', '缓存命中 99%', '已用上下文 34%'],
      );
    });

    test('a smaller session matches the desktop wording too', () {
      // Read from session-26607bfa-…: the desktop rendered
      // "3 轮 44 步 · 185 tok/s" / "4.8M tok · 缓存命中 96%" / "20%".
      final metrics = SessionMetrics.fromProjections(projections(
        asOfSeq: 309,
        turns: 3,
        steps: 44,
        decodeTokens: 40366,
        decodeMs: 218622,
        uncachedInput: 204010,
        output: 40366,
        cacheRead: 4547200,
        cacheWrite: 0,
        pressure: 201765,
        projected: 203401,
        window: 1000000,
      ));

      expect(
        metricsSegments(metrics),
        ['3 轮 44 步', '185 tok/s', '4.8M tok', '缓存命中 96%', '已用上下文 20%'],
      );
    });
  });

  group('shapes and edge cases', () {
    test('a session that has never run shows nothing', () {
      final metrics = SessionMetrics.fromProjections(projections(asOfSeq: 4));
      expect(metrics.hasActivity, isFalse);
      expect(metrics.isEmpty, isTrue);
      expect(metricsSegments(metrics), isEmpty);
    });

    test('a context block with no sample leaves the meter off, not at 0%', () {
      // A never-requested session reports `contextPressure: {}`.
      final metrics = SessionMetrics.fromProjections({
        'asOfSeq': 9,
        'values': {
          'sessionStats': {'turns': 1, 'steps': 2, 'decodeTokens': 10, 'decodeMs': 1000},
          'tokenUsage': {'outputTokens': 10},
          'contextPressure': <String, dynamic>{},
        },
      });

      expect(metrics.contextPercent, isNull);
      expect(metricsSegments(metrics), ['1 轮 2 步', '10 tok/s', '10 tok']);
    });

    test('no usage means no speed and no cache hit, but counts still show', () {
      final metrics = SessionMetrics.fromProjections(projections(
        asOfSeq: 12,
        turns: 2,
        steps: 5,
      ));

      expect(metrics.tokensPerSecond, isNull);
      expect(metrics.cacheHitRatio, isNull);
      expect(metricsSegments(metrics), ['2 轮 5 步', '0 tok']);
    });

    test('a partial cache hit is never rounded up to a perfect one', () {
      // 999 of 1000 billed tokens cached is 99.9%: the desktop refuses to print
      // "100%" there, and neither does this.
      final metrics = SessionMetrics.fromProjections(projections(
        asOfSeq: 3,
        turns: 1,
        steps: 1,
        decodeTokens: 5,
        decodeMs: 1000,
        uncachedInput: 1,
        cacheRead: 999,
        output: 5,
      ));

      expect(metrics.cacheHitRatio, closeTo(0.999, 0.0001));
      expect(cacheHitLabel(metrics.cacheHitRatio!), '99.9%');
      // 990/1000 rounds to a whole 99 and stays there.
      expect(cacheHitLabel(0.99), '99%');
      // 99998/100000 is 99.998% — still not a perfect hit.
      expect(cacheHitLabel(99998 / 100000), '99.9%');
      // Only an exact 100% prints as 100%.
      expect(cacheHitLabel(1.0), '100%');
    });

    test('context occupancy is capped at 100', () {
      final metrics = SessionMetrics.fromProjections(projections(
        asOfSeq: 3,
        turns: 1,
        steps: 1,
        decodeTokens: 5,
        decodeMs: 1000,
        output: 5,
        pressure: 1400000,
        window: 1000000,
      ));

      expect(metrics.contextPercent, 100);
    });

    test('the freshest reading wins by sequence, ties keep the first', () {
      final older = SessionMetrics.fromProjections(projections(asOfSeq: 10, turns: 1, steps: 1));
      final newer = SessionMetrics.fromProjections(projections(asOfSeq: 11, turns: 2, steps: 2));

      expect(SessionMetrics.freshest(older, newer)!.asOfSeq, 11);
      expect(SessionMetrics.freshest(newer, older)!.asOfSeq, 11);
      expect(SessionMetrics.freshest(older, older)!.asOfSeq, 10);
      expect(SessionMetrics.freshest(null, newer)!.asOfSeq, 11);
      expect(SessionMetrics.freshest(older, null)!.asOfSeq, 10);
      expect(SessionMetrics.freshest(null, null), isNull);
    });
  });

  group('number formatting', () {
    test('compact tokens', () {
      expect(compactTokens(0), '0');
      expect(compactTokens(999), '999');
      expect(compactTokens(1000), '1K');
      expect(compactTokens(1234), '1.2K');
      expect(compactTokens(12345), '12.3K');
      expect(compactTokens(999999), '1000K');
      expect(compactTokens(1000000), '1M');
      expect(compactTokens(4791576), '4.8M');
      expect(compactTokens(322186599), '322M');
    });

    test('tokens per second', () {
      expect(tokensPerSecondLabel(248.63), '249');
      expect(tokensPerSecondLabel(184.638), '185');
      expect(tokensPerSecondLabel(10), '10');
      expect(tokensPerSecondLabel(9.87), '9.9');
      expect(tokensPerSecondLabel(9.0), '9');
      expect(tokensPerSecondLabel(0), '0');
      expect(tokensPerSecondLabel(double.nan), '0');
    });

    test('the detail rows spell the same numbers out', () {
      final metrics = SessionMetrics.fromProjections(projections(
        asOfSeq: 309,
        turns: 3,
        steps: 44,
        decodeTokens: 40366,
        decodeMs: 218622,
        uncachedInput: 204010,
        output: 40366,
        cacheRead: 4547200,
        cacheWrite: 0,
        pressure: 201765,
        window: 1000000,
      ));

      final rows = {for (final row in metricsDetail(metrics)) row.$1: row.$2};
      expect(rows['轮次 / 步骤'], '3 / 44');
      expect(rows['生成速度'], contains('185 tok/s'));
      expect(rows['累计'], '4.8M tok');
      expect(rows['缓存命中'], '96%');
      expect(rows['上下文'], '202K / 1M（20%）');
    });
  });
}
