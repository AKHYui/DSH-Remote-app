/// Widget tests for the approval card.
///
/// The card is the only widget with real decision logic that does not need a
/// network, so it is the one worth testing here. It has to get one thing right:
/// the payload it sends back must match `AskUserQuestionAnswerItem`
/// (`{id, selected[], custom?}`) or the desktop's answerer will reject it.
library;

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/theme.dart';
import 'package:dsh_remote_app/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

ApprovalAsk toolAsk() => ApprovalAsk.fromEvent('approval.ask', {
      'askId': 'ask-1',
      'sessionId': 's1',
      'toolName': 'pwsh',
      'reason': 'needs a shell',
    });

ApprovalAsk questionAsk({bool multi = false}) => ApprovalAsk.fromEvent('question.ask', {
      'askId': 'ask-2',
      'sessionId': 's1',
      'questions': [
        {
          'id': 'q1',
          'question': 'Which database?',
          'multiSelect': multi,
          'options': [
            {'label': 'sqlite'},
            {'label': 'postgres'},
          ],
        },
      ],
    });

void main() {
  testWidgets('a tool approval offers allow and deny', (tester) async {
    String? decision;
    await tester.pumpWidget(wrap(ApprovalCard(
      ask: toolAsk(),
      onDecide: (value, answers) => decision = value,
    )));

    expect(find.textContaining('pwsh'), findsOneWidget);
    expect(find.text('允许一次'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);

    await tester.tap(find.text('允许一次'));
    await tester.pump();
    expect(decision, 'approved');
  });

  testWidgets('deny reports rejection', (tester) async {
    String? decision;
    await tester.pumpWidget(wrap(ApprovalCard(
      ask: toolAsk(),
      onDecide: (value, answers) => decision = value,
    )));

    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(decision, 'denied');
  });

  testWidgets('handing the ask back to the desktop reports cancellation', (tester) async {
    String? decision;
    await tester.pumpWidget(wrap(ApprovalCard(
      ask: toolAsk(),
      onDecide: (value, answers) => decision = value,
    )));

    await tester.tap(find.byTooltip('交回电脑处理'));
    await tester.pump();
    expect(decision, 'cancelled');
  });

  testWidgets('a question renders its options and sends the chosen labels', (tester) async {
    String? decision;
    List<Map<String, dynamic>>? answers;
    await tester.pumpWidget(wrap(ApprovalCard(
      ask: questionAsk(),
      onDecide: (value, payload) {
        decision = value;
        answers = payload;
      },
    )));

    expect(find.text('Which database?'), findsOneWidget);
    expect(find.text('电脑在等你回答'), findsOneWidget);

    await tester.tap(find.text('sqlite'));
    await tester.pump();
    await tester.tap(find.text('提交回答'));
    await tester.pump();

    expect(decision, 'approved');
    expect(answers, isNotNull);
    expect(answers!.single['id'], 'q1');
    expect(answers!.single['selected'], ['sqlite']);
    expect(answers!.single.containsKey('custom'), isFalse);
  });

  testWidgets('a multi-select question keeps every choice', (tester) async {
    List<Map<String, dynamic>>? answers;
    await tester.pumpWidget(wrap(ApprovalCard(
      ask: questionAsk(multi: true),
      onDecide: (value, payload) => answers = payload,
    )));

    await tester.tap(find.text('sqlite'));
    await tester.pump();
    await tester.tap(find.text('postgres'));
    await tester.pump();
    await tester.tap(find.text('提交回答'));
    await tester.pump();

    expect(answers!.single['selected'], containsAll(['sqlite', 'postgres']));
  });

  testWidgets('the card cannot be submitted twice', (tester) async {
    var calls = 0;
    await tester.pumpWidget(wrap(ApprovalCard(
      ask: toolAsk(),
      onDecide: (value, answers) => calls++,
    )));

    await tester.tap(find.text('允许一次'));
    await tester.pump();
    // The buttons are disabled after the first decision, so a second tap is a
    // no-op even if it lands.
    await tester.tap(find.text('允许一次'), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('a question cannot be submitted with nothing selected', (tester) async {
    // Found by a real device run: tapping 提交回答 without picking an option sent
    // `selected: []`, which the transcript recorded as `提问 · 0/1 已回答` — a click
    // that costs the agent a turn and tells it nothing.
    var calls = 0;
    await tester.pumpWidget(wrap(ApprovalCard(
      ask: questionAsk(),
      onDecide: (value, answers) => calls++,
    )));

    final submit = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答'));
    expect(submit.onPressed, isNull, reason: 'nothing is selected yet');
    expect(find.textContaining('先选一个选项'), findsOneWidget);

    // A stray tap on the disabled button must not submit anything.
    await tester.tap(find.text('提交回答'), warnIfMissed: false);
    await tester.pump();
    expect(calls, 0);

    await tester.tap(find.text('postgres'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答')).onPressed,
      isNotNull,
    );
    await tester.tap(find.text('提交回答'));
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('a question without options needs typed text', (tester) async {
    var calls = 0;
    await tester.pumpWidget(wrap(ApprovalCard(
      ask: ApprovalAsk.fromEvent('question.ask', {
        'askId': 'ask-3',
        'sessionId': 's1',
        'questions': [
          {'id': 'q1', 'question': '项目叫什么？'},
        ],
      }),
      onDecide: (value, answers) => calls++,
    )));

    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答')).onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField), '一个名字');
    await tester.pump();
    await tester.tap(find.text('提交回答'));
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('handing the question back to the desktop stays available', (tester) async {
    // The escape hatch must never depend on the answer being complete.
    String? decision;
    await tester.pumpWidget(wrap(ApprovalCard(
      ask: questionAsk(),
      onDecide: (value, answers) => decision = value,
    )));

    await tester.tap(find.byTooltip('交回电脑处理'));
    await tester.pump();
    expect(decision, 'cancelled');
  });
}
