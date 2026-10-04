/// Widget tests for the Markdown renderer, focused on tables.
///
/// The parser tests prove the blocks are read; these prove they can actually be
/// drawn on a phone. A four-column table is wider than any phone, so the thing
/// worth asserting is that it **lays out without an overflow and scrolls**, rather
/// than being squeezed into unreadable slivers.
library;

import 'package:dsh_remote_app/theme.dart';
import 'package:dsh_remote_app/ui/markdown_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every string the renderer produced, in tree order.
///
/// `SelectableText.rich` goes through `EditableText`, which builds no `RichText`,
/// so reading the widget's own span is the reliable way to see the output.
List<String> rendered(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((widget) => widget.textSpan?.toPlainText() ?? widget.data ?? '')
    .toList();

Future<void> pumpMarkdown(
  WidgetTester tester,
  String source, {
  double width = 360,
  double height = 640,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.symmetric(horizontal: AppGap.page),
          children: [MarkdownOrPlain(text: source)],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const table = '| 项目 | 状态 | 说明 | 备注 |\n'
      '| :--- | :---: | --- | ---: |\n'
      '| **桥接** | 完成 | 手机能收到审批 | 1 |\n'
      '| 附件 | 完成 | `fileUploads.upload` | 2 |\n';

  testWidgets('a table draws its header and every cell', (tester) async {
    await pumpMarkdown(tester, table);

    final strings = rendered(tester);
    expect(strings, contains('项目'));
    expect(strings, contains('状态'));
    // Inline formatting inside a cell is parsed like anywhere else.
    expect(strings, contains('桥接'));
    expect(strings, contains('fileUploads.upload'));
    // The markers themselves must not survive into the output.
    expect(strings.any((text) => text.contains('|')), isFalse);
    expect(strings.any((text) => text.contains('**')), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bold inside a cell is really bold', (tester) async {
    await pumpMarkdown(tester, table);

    final bold = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere((widget) => (widget.textSpan?.toPlainText() ?? '') == '桥接');
    final span = bold.textSpan!.children!.first as TextSpan;
    expect(span.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('a table too wide for the phone scrolls instead of overflowing', (tester) async {
    await pumpMarkdown(tester, table, width: 360, height: 320);

    expect(find.byType(Table), findsOneWidget);
    // Wider than the viewport, and still no layout error: that is the scroll view
    // doing its job rather than the columns being crushed.
    expect(tester.getSize(find.byType(Table)).width, greaterThan(360 - 2 * AppGap.page));
    expect(tester.takeException(), isNull);

    final horizontal = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((widget) => widget.scrollDirection == Axis.horizontal);
    expect(horizontal, isNotEmpty, reason: 'the table needs a sideways scroller');
  });

  testWidgets('a narrow table is padded out to the available width', (tester) async {
    await pumpMarkdown(tester, '| a | b |\n| - | - |\n| 1 | 2 |', width: 360);

    final width = tester.getSize(find.byType(Table)).width;
    expect(width, greaterThanOrEqualTo(360 - 2 * AppGap.page - 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an escaped pipe renders as a pipe', (tester) async {
    await pumpMarkdown(tester, r'| a | b |' '\n' r'| - | - |' '\n' r'| x \| y | 2 |');

    expect(rendered(tester), contains('x | y'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rules, quotes and task items draw', (tester) async {
    await pumpMarkdown(
      tester,
      '> 引用一行\n> 引用两行\n\n- [ ] 未完成\n- [x] 已完成\n- 普通条目\n\n---\n\n1. 有序',
    );

    final strings = rendered(tester);
    expect(strings, contains('引用一行\n引用两行'));
    expect(strings, contains('未完成'));
    expect(strings, contains('已完成'));
    expect(strings, contains('普通条目'));
    expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsOneWidget);
    // The markers are plain `Text`, not selectable text: an ordered item keeps its
    // number, a plain bullet shows the usual dot, and the quote's own `>` is gone.
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
    expect(strings.any((text) => text.contains('>')), isFalse);
    expect(tester.takeException(), isNull);
  });
}
