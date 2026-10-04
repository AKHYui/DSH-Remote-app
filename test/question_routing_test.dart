/// Routing a question card to the path that can actually answer it.
///
/// A question the desktop is still blocking on can only be answered through the
/// ask (the `approval` frame). The `userQuestions.answer` op only accepts a
/// question the session projection has already marked `continued`, so on a live
/// ask it answers `false` — and an answer that looks delivered but was thrown
/// away is the worst outcome of all. This is the matching that prevents it, kept
/// as pure state logic so it needs no transport.
library;

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/state/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ApprovalAsk questionAsk({
  required String sessionId,
  List<String> ids = const ['q1'],
  String askId = 'ask-1',
}) {
  return ApprovalAsk.fromEvent(
    'question.ask',
    {
      'askId': askId,
      'sessionId': sessionId,
      'questions': [
        for (final id in ids) {'id': id, 'question': 'which?', 'options': const []},
      ],
    },
    deviceId: 'device-1',
  );
}

ApprovalAsk approvalAsk({String sessionId = 'session-1'}) {
  return ApprovalAsk.fromEvent(
    'approval.ask',
    {'askId': 'ask-a', 'sessionId': sessionId, 'toolName': 'pwsh'},
    deviceId: 'device-1',
  );
}

void main() {
  late AppController controller;

  setUp(() {
    controller = AppController();
  });

  tearDown(() => controller.dispose());

  void staged(List<ApprovalAsk> asks) {
    controller.state = controller.state.copyWith(approvals: asks);
  }

  test('a live question for the same session and the same ids is found', () {
    staged([questionAsk(sessionId: 'session-1')]);
    final live = controller.liveQuestionFor('session-1', ['q1']);
    expect(live, isNotNull);
    expect(live!.askId, 'ask-1');
  });

  test('id order does not matter, because the questions are a set', () {
    staged([questionAsk(sessionId: 'session-1', ids: ['b', 'a'])]);
    expect(controller.liveQuestionFor('session-1', ['a', 'b']), isNotNull);
  });

  test('a different session never matches', () {
    staged([questionAsk(sessionId: 'session-2')]);
    expect(controller.liveQuestionFor('session-1', ['q1']), isNull);
  });

  test('a different question set never matches', () {
    staged([questionAsk(sessionId: 'session-1', ids: ['q1', 'q2'])]);
    expect(controller.liveQuestionFor('session-1', ['q1']), isNull);
    expect(controller.liveQuestionFor('session-1', ['q3']), isNull);
  });

  test('an approval is not mistaken for a question', () {
    staged([approvalAsk()]);
    expect(controller.liveQuestionFor('session-1', ['q1']), isNull);
  });

  test('the match is the one whose ids line up when several are live', () {
    staged([
      questionAsk(sessionId: 'session-1', ids: ['other'], askId: 'ask-other'),
      questionAsk(sessionId: 'session-1', ids: ['q1'], askId: 'ask-wanted'),
    ]);
    expect(controller.liveQuestionFor('session-1', ['q1'])?.askId, 'ask-wanted');
  });

  test('no questions means no match, so the op keeps the fallback role', () {
    staged([questionAsk(sessionId: 'session-1', ids: [])]);
    expect(controller.liveQuestionFor('session-1', []), isNull);
    expect(controller.liveQuestionFor('session-1', ['q1']), isNull);
  });
}
