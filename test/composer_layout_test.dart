/// The composer's bottom row, measured at phone width.
///
/// The user's report: "the select-model button at the bottom of the input box can
/// be made wider — on the tablet everything shows, on the phone the model name is
/// cut off". The cause was structural, not cosmetic: the row had the model chip as
/// a `Flexible` **and** a `Spacer` next to it, and two flexible children split the
/// free space evenly, so the chip could never use more than half of it however
/// much room was left over.
///
/// Everything below is measured at run time — the label lengths are derived from
/// the space the buttons actually leave — so the assertions do not depend on the
/// test font's metrics or on the button sizes.
library;

import 'dart:io';

import 'package:dsh_remote_app/theme.dart';
import 'package:dsh_remote_app/ui/composer.dart';
import 'package:dsh_remote_app/ui/model_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const String veryLongName = 'A name far longer than any phone row can hold, on purpose';

/// A real proportional font, when the host has one.
///
/// `flutter test` lays text out with a symbol font whose glyphs are all the same
/// width (~14dp per character at body size) — nothing like a phone. That makes the
/// default assertions conservative, but it cannot answer "does *this* model name
/// fit on a real screen". Loading a system font does, and the case is skipped
/// where none exists rather than pretending.
///
/// The bytes are read synchronously and the engine call is wrapped in
/// [WidgetTester.runAsync]: `testWidgets` runs in a fake-async zone, where a real
/// `await` on I/O simply never completes (the first version of this test hung for
/// the full ten-minute timeout because of exactly that).
Future<String?> loadProbeFont(WidgetTester tester) async {
  for (final candidate in [
    r'C:\Windows\Fonts\segoeui.ttf',
    r'C:\Windows\Fonts\arial.ttf',
    '/System/Library/Fonts/Supplemental/Arial.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  ]) {
    final file = File(candidate);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    await tester.runAsync(() async {
      final loader = FontLoader('Probe')
        ..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
      await loader.load();
    });
    return 'Probe';
  }
  return null;
}

/// The width a string needs when nothing constrains it.
double intrinsicWidth(String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.width;
}

Future<void> pumpComposer(
  WidgetTester tester, {
  required Size size,
  Widget? leading,
  String? fontFamily,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final controller = TextEditingController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme().copyWith(
        textTheme: buildAppTheme().textTheme.apply(fontFamily: fontFamily),
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Composer(
            controller: controller,
            busy: false,
            hintText: '发消息…',
            onSend: () async {},
            onAttach: () {},
            leading: leading,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

ModelChip chip(String label) => ModelChip(label: label, onTap: () {});

/// How much of its natural size the label is actually painted at.
///
/// The label sits in a `FittedBox(scaleDown)`, so a too-long name shrinks instead
/// of being ellipsized: 1.0 means "drawn at full size", 0.9 means "shrunk 10%".
/// Measuring the `FittedBox` (which sizes to the *scaled* child) against the text's
/// natural width is what makes that number visible to a test.
double labelScale(WidgetTester tester, String label) {
  final style = tester.widget<Text>(find.text(label)).style;
  final natural = intrinsicWidth(label, style);
  final painted = tester.getSize(find.byType(FittedBox).first).width;
  return painted / natural;
}

void main() {
  testWidgets('the pill and the send button share one row', (tester) async {
    await pumpComposer(
      tester,
      size: const Size(360, 640),
      leading: chip('DeepSeek V4.1 Flash'),
    );

    final pill = tester.getRect(find.byType(ModelChip));
    final attach = tester.getRect(find.byIcon(Icons.attach_file_rounded));
    final send = tester.getRect(find.byIcon(Icons.arrow_upward_rounded));

    // Same line: the pill's vertical centre lines up with the buttons'.
    expect((pill.center.dy - send.center.dy).abs(), lessThan(2));
    expect((pill.center.dy - attach.center.dy).abs(), lessThan(2));
    // And the pill is to the left of them, not above.
    expect(pill.right, lessThanOrEqualTo(attach.left + 1));
  });

  testWidgets('the pill may use everything the buttons do not need', (tester) async {
    await pumpComposer(
      tester,
      size: const Size(360, 640),
      leading: chip(veryLongName),
    );

    final composer = tester.getRect(find.byType(Composer));
    final pill = tester.getRect(find.byType(ModelChip));
    final attach = tester.getRect(find.byIcon(Icons.attach_file_rounded));

    // The old layout put a `Spacer` next to the pill and the two split the free
    // width evenly, so the pill stopped at half of it with a gap in between.
    expect(
      attach.left - pill.right,
      lessThanOrEqualTo(2),
      reason: 'the pill stopped ${(attach.left - pill.right).toStringAsFixed(1)}dp short',
    );
    expect(pill.width, greaterThan(composer.width * 0.5));
  });

  testWidgets('buttons stay inside the row, with and without a leading widget', (tester) async {
    for (final leading in <Widget?>[null, chip('V4')]) {
      await pumpComposer(tester, size: const Size(360, 640), leading: leading);

      final composer = tester.getRect(find.byType(Composer));
      final send = tester.getRect(find.byIcon(Icons.arrow_upward_rounded));
      final attach = tester.getRect(find.byIcon(Icons.attach_file_rounded));

      expect(
        composer.contains(send.center),
        isTrue,
        reason: 'the send button overflowed the composer (leading=${leading != null})',
      );
      expect(composer.contains(attach.center), isTrue);
      expect(
        composer.right - send.right,
        lessThan(24),
        reason: 'the send button is not at the right edge (leading=${leading != null})',
      );
    }
  });

  testWidgets('a short label stays a pill instead of stretching across a tablet', (tester) async {
    // `Flexible` (loose), not `Expanded`: the chip only grows when it needs to.
    await pumpComposer(tester, size: const Size(900, 640), leading: chip('V4'));
    expect(tester.getSize(find.byType(ModelChip)).width, lessThan(200));
  });

  testWidgets('every real model name stays legible on a 360dp phone', (tester) async {
    final fontFamily = await loadProbeFont(tester);
    if (fontFamily == null) {
      markTestSkipped('no system font available to measure with');
      return;
    }

    // The longest names `model.catalog` actually offers.
    const names = [
      'DeepSeek V4.1 Flash',
      'DeepSeek V4 Flash Vision (exp)',
      'Kimi K2.7 Code HighSpeed',
      'Claude Sonnet 5.5',
    ];
    final scales = <String, double>{};
    for (final name in names) {
      await pumpComposer(
        tester,
        size: const Size(360, 640),
        leading: chip(name),
        fontFamily: fontFamily,
      );
      scales[name] = labelScale(tester, name);
    }
    stdout.writeln('        label scale at 360dp (1.0 = full size): '
        '${scales.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(3)}').join(', ')}');

    // A name is never ellipsized now (`FittedBox` shrinks instead), so the thing
    // worth guarding is how much it has to shrink. The old half-row layout put
    // "DeepSeek V4 Flash Vision (exp)" at ~0.91 — legible but visibly smaller than
    // the model it names; the shared row with no leading glyph keeps the longest
    // catalog name at full size.
    for (final entry in scales.entries) {
      expect(
        entry.value,
        greaterThan(0.95),
        reason: '"${entry.key}" is shrunk to '
            '${(entry.value * 100).toStringAsFixed(0)}% — too small on a phone',
      );
    }
  });
}
