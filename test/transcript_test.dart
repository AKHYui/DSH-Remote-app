/// Unit tests for the transcript builder.
///
/// This is the piece of the app most likely to be subtly wrong — it interprets
/// the harness's event stream — and it is pure Dart, so it is tested here rather
/// than discovered on a phone.
library;

import 'dart:convert';

import 'package:dsh_remote_app/api/models.dart';
import 'package:dsh_remote_app/chat/transcript.dart';
import 'package:dsh_remote_app/state/settings.dart';
import 'package:flutter_test/flutter_test.dart';

SessionEvent event(String type, int seq, Map<String, dynamic> data) =>
    SessionEvent(sessionId: 's1', seq: seq, type: type, time: 0, data: data);

String textOf(ChatItem item) => switch (item) {
      UserBubble() => item.text,
      PendingUserBubble() => item.text,
      ContextNotice() => item.text,
      DeliverablesCard() => item.files.map((file) => file.path).join(' / '),
      AssistantBubble() => item.text,
      ReasoningNote() => item.text,
      SystemNote() => item.text,
      ToolCall() => item.result ?? item.arguments,
      QuestionCard() => item.questions.map((q) => q['question']).join(' / '),
    };

void main() {
  group('contentText', () {
    test('collects text and reasoning blocks, ignores the rest', () {
      expect(
        contentText([
          {'type': 'text', 'text': 'hello'},
          {'type': 'tool-call', 'id': 'c1'},
          {'type': 'text', 'text': 'world'},
        ]),
        'hello\n\nworld',
      );
    });

    test('tolerates a string, null and junk', () {
      expect(contentText('direct'), 'direct');
      expect(contentText(null), '');
      expect(contentText(42), '');
    });
  });

  group('Transcript', () {
    test('renders a user message', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi there'},
          ],
        }));

      expect(transcript.items, hasLength(1));
      expect(transcript.items.single, isA<UserBubble>());
      expect(textOf(transcript.items.single), 'hi there');
    });

    test('splits an assistant message into reasoning and text, in order', () {
      final transcript = Transcript()
        ..applyEvent(event('assistant/message', 2, {
          'turn': 1,
          'step': 1,
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'reasoning', 'text': 'let me think'},
              {'type': 'text', 'text': 'the answer is 42'},
            ],
          },
        }));

      expect(transcript.items.map((item) => item.runtimeType.toString()).toList(),
          ['ReasoningNote', 'AssistantBubble']);
      expect(textOf(transcript.items[0]), 'let me think');
      expect(textOf(transcript.items[1]), 'the answer is 42');
    });

    test('groups consecutive text blocks and breaks on a kind change', () {
      final transcript = Transcript()
        ..applyEvent(event('assistant/message', 1, {
          'message': {
            'content': [
              {'type': 'text', 'text': 'a'},
              {'type': 'text', 'text': 'b'},
              {'type': 'reasoning', 'text': 'r'},
              {'type': 'text', 'text': 'c'},
            ],
          },
        }));

      expect(transcript.items, hasLength(3));
      expect(textOf(transcript.items[0]), 'ab');
      expect(transcript.items[1], isA<ReasoningNote>());
      expect(textOf(transcript.items[2]), 'c');
    });

    test('attaches a tool result to its call', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {
          'callId': 'call-1',
          'name': 'pwsh',
          'arguments': '{"command":"dir"}',
        }))
        ..applyEvent(event('tool/result', 2, {
          'callId': 'call-1',
          'message': {
            'content': [
              {'type': 'text', 'text': 'file listing'},
            ],
          },
        }));

      expect(transcript.items, hasLength(1));
      final call = transcript.items.single as ToolCall;
      expect(call.hasResult, isTrue);
      expect(call.result, 'file listing');
      expect(call.isError, isFalse);
    });

    test('marks an errored tool result', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {'callId': 'c', 'name': 'pwsh'}))
        ..applyEvent(event('tool/result', 2, {
          'callId': 'c',
          'error': {'code': 'failed'},
          'message': {
            'content': [
              {'type': 'text', 'text': 'boom'},
            ],
          },
        }));

      final call = transcript.items.single as ToolCall;
      expect(call.isError, isTrue);
      expect(call.result, 'boom');
    });

    test('keeps an orphan tool result instead of dropping it', () {
      // The snapshot window can start after the call was recorded.
      final transcript = Transcript()
        ..applyEvent(event('tool/result', 9, {
          'callId': 'never-seen',
          'message': {
            'content': [
              {'type': 'text', 'text': 'late result'},
            ],
          },
        }));

      expect(transcript.items, hasLength(1));
      expect(transcript.items.single, isA<ToolCall>());
      expect(textOf(transcript.items.single), 'late result');
    });

    test('pretty-prints JSON tool arguments', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {
          'callId': 'c',
          'name': 'pwsh',
          'arguments': '{"b":1,"a":2}',
        }));

      final call = transcript.items.single as ToolCall;
      expect(call.arguments, contains('\n'));
      expect(call.arguments, contains('"a": 2'));
    });

    test('leaves unparseable arguments alone', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {'callId': 'c', 'name': 'x', 'arguments': 'not json'}));
      expect((transcript.items.single as ToolCall).arguments, 'not json');
    });

    test('records a non-completed turn end as a note', () {
      final transcript = Transcript()
        ..applyEvent(event('turn/end', 5, {
          'turn': 1,
          'reason': {'kind': 'error', 'error': {'code': 'x', 'message': 'provider exploded'}},
        }));

      expect(transcript.items.single, isA<SystemNote>());
      expect(textOf(transcript.items.single), contains('provider exploded'));
    });

    test('ignores a completed turn end', () {
      final transcript = Transcript()
        ..applyEvent(event('turn/end', 5, {
          'reason': {'kind': 'completed'},
        }));
      expect(transcript.items, isEmpty);
    });

    test('ignores replayed sequence numbers', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 7, {'content': [{'type': 'text', 'text': 'once'}]}))
        ..applyEvent(event('user/message', 7, {'content': [{'type': 'text', 'text': 'twice'}]}))
        ..applyEvent(event('user/message', 6, {'content': [{'type': 'text', 'text': 'older'}]}));

      expect(transcript.items, hasLength(1));
      expect(textOf(transcript.items.single), 'once');
    });

    test('a snapshot replaces everything before it', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {'content': [{'type': 'text', 'text': 'live'}]}));
      expect(transcript.items, hasLength(1));

      transcript.applySnapshot([
        event('user/message', 100, {'content': [{'type': 'text', 'text': 'from snapshot'}]}),
        event('assistant/message', 101, {
          'message': {
            'content': [
              {'type': 'text', 'text': 'answer'},
            ],
          },
        }),
      ]);

      expect(transcript.items, hasLength(2));
      expect(textOf(transcript.items.first), 'from snapshot');
      expect(transcript.lastSeq, 101);
    });

    test('a live event after a snapshot still appends', () {
      final transcript = Transcript()
        ..applySnapshot([
          event('user/message', 10, {'content': [{'type': 'text', 'text': 'a'}]}),
        ])
        ..applyEvent(event('user/message', 11, {'content': [{'type': 'text', 'text': 'b'}]}));

      expect(transcript.items, hasLength(2));
    });

    test('streaming text accumulates and is cleared by the committed message', () {
      final transcript = Transcript()..applyStreamDelta('Hel');
      expect(transcript.streamingText, 'Hel');
      transcript.applyStreamDelta('lo');
      expect(transcript.streamingText, 'Hello');

      transcript.applyEvent(event('assistant/message', 3, {
        'message': {
          'content': [
            {'type': 'text', 'text': 'Hello'},
          ],
        },
      }));
      expect(transcript.streamingText, isEmpty);
      expect(transcript.items, hasLength(1));
    });

    test('null and empty deltas are ignored', () {
      final transcript = Transcript()
        ..applyStreamDelta(null)
        ..applyStreamDelta('');
      expect(transcript.streamingText, isEmpty);
    });

    test('unknown event types are ignored rather than throwing', () {
      final transcript = Transcript()
        ..applyEvent(event('something/new', 1, {'anything': true}));
      expect(transcript.items, isEmpty);
      expect(transcript.lastSeq, 1);
    });

    test('blank messages are not rendered', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {'content': [{'type': 'text', 'text': '   '}]}))
        ..applyEvent(event('assistant/message', 2, {
          'message': {
            'content': [],
          },
        }));
      expect(transcript.items, isEmpty);
    });

    test('clear resets every derived field', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {'callId': 'c', 'name': 'x'}))
        ..applyStreamDelta('text')
        ..clear();

      expect(transcript.items, isEmpty);
      expect(transcript.streamingText, isEmpty);
      expect(transcript.lastSeq, 0);
    });
  });

  group('injected context is not the human turn', () {
    /// Every kind in DSH's `MessageSourceMap` other than the human's own. They
    /// all arrive as `user/message`, and before this each one rendered as a grey
    /// bubble that looked exactly like something the user had typed.
    const contextKinds = [
      'agent-message',
      'subagent-settled',
      'subagent-report',
      'model-selection',
      'runtime-context',
      'skill-catalog',
      'skill-invocation',
      'tool-registry',
      'compact-checkpoint',
      'session-reference',
      'user-approval',
      'ptc-mode',
      'schedule',
      'goal',
      'cordis-host-runner',
    ];

    test('the human kinds stay user bubbles', () {
      for (final kind in ['user', 'user-question-reply', '']) {
        final transcript = Transcript()
          ..applyEvent(event('user/message', 1, {
            'content': [
              {'type': 'text', 'text': 'mine'},
            ],
            'source': {'kind': kind, 'rpcId': 'app-1'},
          }));
        expect(transcript.items.single, isA<UserBubble>(), reason: kind);
      }
    });

    test('every other kind from MessageSourceMap is folded into a notice', () {
      for (final kind in contextKinds) {
        expect(isHumanUserSourceKind(kind), isFalse, reason: kind);
        final transcript = Transcript()
          ..applyEvent(event('user/message', 1, {
            'content': [
              {'type': 'text', 'text': 'injected'},
            ],
            'source': {'kind': kind},
          }));
        expect(transcript.items.single, isA<ContextNotice>(), reason: kind);
        expect((transcript.items.single as ContextNotice).sourceKind, kind);
      }
    });

    test('an agent message carries its own label and summary', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {
          'content': [
            {
              'type': 'text',
              'text': 'Agent b7e08bc2-f153-46c1-b201-e5b917fe7651 sent a message: done',
            },
          ],
          'source': {
            'kind': 'agent-message',
            'form': 'relay',
            'senderSessionId': 'b7e08bc2-f153-46c1-b201-e5b917fe7651',
          },
        }));

      final notice = transcript.items.single as ContextNotice;
      expect(contextNoticeLabel(notice.sourceKind), '子代理消息');
      expect(notice.senderId, 'b7e08bc2-f153-46c1-b201-e5b917fe7651');
      expect(notice.text, contains('sent a message'));
      // The framing DSH adds is dropped from the collapsed preview: it is the
      // exact string the user asked to stop seeing.
      expect(contextNoticePreview(notice), 'done');
    });

    test('a preview keeps the words when there is no agent framing', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 2, {
          'content': [
            {'type': 'text', 'text': 'line one\n\n   line two'},
          ],
          'source': {'kind': 'model-selection'},
        }));
      expect(contextNoticePreview(transcript.items.single as ContextNotice), 'line one line two');
    });

    test('a notice whose only payload is a summary is still shown', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 4, {
          'content': const [],
          'source': {
            'kind': 'subagent-settled',
            'form': 'notice',
            'summary': 'Background subagent 32ba14f9 finished.',
          },
        }));

      final notice = transcript.items.single as ContextNotice;
      expect(notice.text, 'Background subagent 32ba14f9 finished.');
      expect(notice.summary, isNotEmpty);
      expect(contextNoticeLabel(notice.sourceKind), '子代理已结束');
    });

    test('an empty, useless notice is dropped rather than rendered blank', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {
          'content': const [],
          'source': {'kind': 'model-selection'},
        }));
      expect(transcript.items, isEmpty);
    });

    test('a notice is a message row, never folded into the process timeline', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {
          'content': [
            {'type': 'text', 'text': 'notice'},
          ],
          'source': {'kind': 'agent-message'},
        }));
      final rows = buildRows(transcript.items);
      expect(rows, hasLength(1));
      expect(rows.single, isA<MessageRow>());
    });

    test('a notice never reconciles a local echo, even when the text matches', () {
      // An agent message can land between the prompt and its own durable event;
      // letting it match by text would make the sender's message disappear.
      final transcript = Transcript()
        ..applyLocalUserMessage('hello there', requestId: 'app-1')
        ..applyEvent(event('user/message', 2, {
          'content': [
            {'type': 'text', 'text': 'hello there'},
          ],
          'source': {'kind': 'agent-message'},
        }));

      expect(transcript.items.whereType<PendingUserBubble>(), hasLength(1));
      expect(transcript.items.whereType<ContextNotice>(), hasLength(1));
    });
  });

  group('visibleSessions keeps the phone to real conversations', () {
    SessionSummary summary({
      required String id,
      bool subagent = false,
      bool blank = false,
    }) =>
        SessionSummary(
          sessionId: id,
          running: false,
          agentAvailable: true,
          blank: blank,
          updatedAt: 1791082274000,
          isSubagent: subagent,
        );

    test('drops blank sessions, which are an empty page titled with an id', () {
      final visible = visibleSessions([
        summary(id: 'session-real'),
        summary(id: 'session-probe', blank: true),
      ]);
      expect(visible.map((s) => s.sessionId).toList(), ['session-real']);
    });

    test('drops subagent sessions, which no op can drive', () {
      final visible = visibleSessions([
        summary(id: 'session-real'),
        summary(id: 'b7e08bc2-subagent', subagent: true),
      ]);
      expect(visible.map((s) => s.sessionId).toList(), ['session-real']);
    });

    test('a session stops being blank once a prompt is accepted', () {
      // The same id, before and after: the first message is what makes it appear.
      expect(visibleSessions([summary(id: 'session-new', blank: true)]), isEmpty);
      expect(
        visibleSessions([summary(id: 'session-new')]).map((s) => s.sessionId).toList(),
        ['session-new'],
      );
    });

    test('reads the blank flag off the wire', () {
      expect(
        SessionSummary.fromJson({'sessionId': 's1', 'blank': true}).blank,
        isTrue,
      );
      expect(SessionSummary.fromJson({'sessionId': 's1'}).blank, isFalse);
    });
  });

  group('deliverables', () {
    /// The real payload, copied from a live session log
    /// (`deliverables/presented` at seq 1191 of the session that fixed the
    /// transcript).
    Map<String, dynamic> presented() => {
          'turn': 9,
          'callId': 'call_00_ET_uf1JPThKsoK7GV5ebYod9546',
          'files': [
            {
              'path': r'D:\dsh-remote-bridge\app\build\app\outputs\flutter-apk\app-release.apk',
              'description': '新的 release 包（0.1.1+2）',
            },
            {
              'path': 'artifacts/app-3-older.png',
              'description': '模拟器上的实机截图',
            },
            {'path': 'README.md'},
          ],
        };

    test('lists the declared files, with paths, names and directories', () {
      final transcript = Transcript()
        ..applyEvent(event('deliverables/presented', 1, presented()));

      final card = transcript.items.single as DeliverablesCard;
      expect(card.turn, 9);
      expect(card.files, hasLength(3));
      expect(card.files.first.name, 'app-release.apk');
      expect(
        card.files.first.directory,
        r'D:\dsh-remote-bridge\app\build\app\outputs\flutter-apk',
      );
      expect(card.files.last.name, 'README.md');
      expect(card.files.last.directory, isEmpty);
      expect(card.files.last.description, isEmpty);
    });

    test('a deliverables card is a message row, never folded into the process', () {
      final transcript = Transcript()
        ..applyEvent(event('deliverables/presented', 1, presented()));
      final rows = buildRows(transcript.items);
      expect(rows.single, isA<MessageRow>());
    });

    test('junk, empty paths and a missing list render nothing', () {
      expect(parseDeliverables(null), isEmpty);
      expect(parseDeliverables({'turn': 1}), isEmpty);
      expect(parseDeliverables({'files': 'not-a-list'}), isEmpty);
      expect(
        parseDeliverables({
          'files': [
            {'path': '   '},
            {'description': 'no path'},
            'junk',
            {'path': 'kept.txt'},
          ],
        }).map((file) => file.path).toList(),
        ['kept.txt'],
      );

      final transcript = Transcript()
        ..applyEvent(event('deliverables/presented', 1, {'files': const []}));
      expect(transcript.items, isEmpty);
    });

    test('fileNameOf tolerates both separators and a bare name', () {
      expect(fileNameOf(r'C:\a\b\c.txt'), 'c.txt');
      expect(fileNameOf('/opt/dsh-backend/var/relay.db'), 'relay.db');
      expect(fileNameOf('README.md'), 'README.md');
      expect(fileNameOf(''), '');
    });
  });

  group('the sender own turn is echoed locally', () {
    test('appears the moment the relay accepts it', () {
      final transcript = Transcript()..applyLocalUserMessage('hi', requestId: 'app-7');
      expect(transcript.items.single, isA<PendingUserBubble>());
      expect(textOf(transcript.items.single), 'hi');
    });

    test('an attachment-only turn is echoed as a placeholder', () {
      final transcript = Transcript()
        ..applyLocalUserMessage('', requestId: 'app-8', attachmentLabel: '[图片]');
      expect(textOf(transcript.items.single), '[图片]');
    });

    test('nothing at all is echoed for an empty turn', () {
      final transcript = Transcript()..applyLocalUserMessage('   ', requestId: 'app-9');
      expect(transcript.items, isEmpty);
    });

    test('the durable event replaces the echo, matched exactly by rpcId', () {
      final transcript = Transcript()
        ..applyLocalUserMessage('hi', requestId: 'app-7')
        // Same words, different request: this is a different turn and must not
        // swallow the echo.
        ..applyEvent(event('user/message', 1, {
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
          'source': {'kind': 'user', 'rpcId': 'app-other'},
        }));
      expect(transcript.items.whereType<PendingUserBubble>(), hasLength(1));

      transcript.applyEvent(event('user/message', 2, {
        'content': [
          {'type': 'text', 'text': 'hi'},
        ],
        'source': {'kind': 'user', 'rpcId': 'app-7'},
      }));

      expect(transcript.items.whereType<PendingUserBubble>(), isEmpty);
      expect(transcript.items.whereType<UserBubble>(), hasLength(2));
    });

    test('the text is the fallback when the harness echoes no rpcId', () {
      final transcript = Transcript()
        ..applyLocalUserMessage('hi', requestId: 'app-7')
        ..applyEvent(event('user/message', 1, {
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
          'source': {'kind': 'user'},
        }));

      expect(transcript.items.whereType<PendingUserBubble>(), isEmpty);
      expect(transcript.items.whereType<UserBubble>(), hasLength(1));
    });

    test('two identical messages reconcile one echo each', () {
      final transcript = Transcript()
        ..applyLocalUserMessage('ok', requestId: 'app-1')
        ..applyLocalUserMessage('ok', requestId: 'app-2');

      expect(transcript.items.whereType<PendingUserBubble>(), hasLength(2));

      transcript.applyEvent(event('user/message', 1, {
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'source': {'kind': 'user', 'rpcId': 'app-1'},
      }));
      expect(transcript.items.whereType<PendingUserBubble>(), hasLength(1));

      transcript.applyEvent(event('user/message', 2, {
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'source': {'kind': 'user', 'rpcId': 'app-2'},
      }));
      expect(transcript.items.whereType<PendingUserBubble>(), isEmpty);
    });

    test('an echo already confirmed by the log is not repeated', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
          'source': {'kind': 'user', 'rpcId': 'app-7'},
        }))
        ..applyLocalUserMessage('hi', requestId: 'app-7');

      expect(transcript.items, hasLength(1));
      expect(transcript.items.single, isA<UserBubble>());
    });

    test('a snapshot keeps an echo the snapshot does not cover yet', () {
      // The race that made a sent message vanish: a reconnect lands between
      // "prompt accepted" and "durable event appended".
      final transcript = Transcript()
        ..applyLocalUserMessage('just sent', requestId: 'app-7')
        ..applySnapshot([
          event('user/message', 100, {
            'content': [
              {'type': 'text', 'text': 'older'},
            ],
            'source': {'kind': 'user'},
          }),
        ]);

      expect(transcript.items.whereType<PendingUserBubble>(), hasLength(1));
      expect(textOf(transcript.items.last), 'just sent');
    });

    test('a snapshot drops an echo the snapshot proves', () {
      final transcript = Transcript()
        ..applyLocalUserMessage('just sent', requestId: 'app-7')
        ..applySnapshot([
          event('user/message', 100, {
            'content': [
              {'type': 'text', 'text': 'just sent'},
            ],
            'source': {'kind': 'user', 'rpcId': 'app-7'},
          }),
        ]);

      expect(transcript.items.whereType<PendingUserBubble>(), isEmpty);
      expect(transcript.items, hasLength(1));
    });

    test('an attachment-only durable turn leaves a placeholder behind', () {
      final transcript = Transcript()
        ..applyLocalUserMessage('', requestId: 'app-7', attachmentLabel: '[图片]')
        ..applyEvent(event('user/message', 1, {
          'content': [
            {'type': 'image', 'mediaType': 'image/png', 'data': 'AAAA'},
          ],
          'source': {'kind': 'user', 'rpcId': 'app-7'},
        }));

      expect(transcript.items.whereType<PendingUserBubble>(), isEmpty);
      expect(textOf(transcript.items.single), '[图片]');
    });

    test('attachment counting tolerates any shape', () {
      expect(countAttachments(null), (images: 0, files: 0));
      expect(countAttachments('text'), (images: 0, files: 0));
      expect(
        countAttachments([
          {'type': 'image'},
          {'type': 'image'},
          {'type': 'file'},
          {'type': 'text', 'text': 'x'},
          'junk',
        ]),
        (images: 2, files: 1),
      );
      expect(attachmentPlaceholder(images: 2, files: 1), '[2 张图片] [文件]');
      expect(attachmentPlaceholder(), '');
    });
  });

  group('FollowFrame', () {
    test('reads snapshot records', () {
      const frame = FollowFrame(kind: 'snapshot', raw: {
        'type': 'snapshot',
        'cursor': 42,
        'header': {'id': 'sess-1'},
        'records': [
          {
            'type': 'event',
            'event': {
              'type': 'user/message',
              'seq': 1,
              'time': 0,
              'data': {
                'content': [
                  {'type': 'text', 'text': 'from snapshot'},
                ],
              },
            },
          },
        ],
      });

      expect(frame.cursor, 42);
      expect(frame.snapshotEvents, hasLength(1));
      expect(frame.snapshotEvents.single.type, 'user/message');
      expect(frame.snapshotEvents.single.sessionId, 'sess-1');
    });

    test('reads an event frame', () {
      const frame = FollowFrame(kind: 'event', raw: {
        'type': 'event',
        'event': {'type': 'assistant/message', 'seq': 9, 'time': 0, 'data': {}},
      });
      expect(frame.event, isNotNull);
      expect(frame.event!.seq, 9);
    });

    test('extracts streamed text only from a text delta', () {
      expect(
        const FollowFrame(kind: 'assistant-stream', raw: {
          'type': 'assistant-stream',
          'frame': {
            'type': 'chunk',
            'chunk': {'type': 'text-delta', 'text': 'partial'},
          },
        }).streamingText,
        'partial',
      );

      expect(
        const FollowFrame(kind: 'assistant-stream', raw: {
          'type': 'assistant-stream',
          'frame': {
            'type': 'chunk',
            'chunk': {'type': 'tool-call-delta', 'id': 'c'},
          },
        }).streamingText,
        isNull,
      );
    });
  });

  group('RelaySettings.normaliseBaseUrl', () {
    test('accepts bare host:port and forces https', () {
      expect(RelaySettings.normaliseBaseUrl('39.100.70.90:58443'), 'https://39.100.70.90:58443');
    });

    test('upgrades http and ws', () {
      expect(RelaySettings.normaliseBaseUrl('http://host:1'), 'https://host:1');
      expect(RelaySettings.normaliseBaseUrl('ws://host:1'), 'https://host:1');
      expect(RelaySettings.normaliseBaseUrl('wss://host:1'), 'https://host:1');
    });

    test('drops paths and query strings', () {
      expect(
        RelaySettings.normaliseBaseUrl('https://host:58443/api/v1/attach?token=x'),
        'https://host:58443',
      );
    });

    test('rejects empty and hostless input', () {
      expect(RelaySettings.normaliseBaseUrl(''), '');
      expect(RelaySettings.normaliseBaseUrl('   '), '');
      expect(RelaySettings.normaliseBaseUrl('https://'), '');
    });
  });

  group('QuestionCard', () {
    // The questions travel in the durable session log as the tool call's
    // arguments, which the phone already receives — so discovering them needs no
    // push channel. Getting this parsing wrong would show a bare JSON blob
    // instead of an answerable card, which is exactly the defect being fixed.
    test('turns an ask_user_question call into a card, not a process step', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {
          'callId': 'call-q',
          'name': 'ask_user_question',
          'arguments': jsonEncode({
            'questions': [
              {
                'id': 'q1',
                'question': '继续吗？',
                'options': [
                  {'label': '继续'},
                  {'label': '停止'},
                ],
              },
            ],
          }),
        }));

      expect(transcript.items.single, isA<QuestionCard>());
      final card = transcript.items.single as QuestionCard;
      expect(card.callId, 'call-q');
      expect(card.questions, hasLength(1));
      expect(card.answered, isFalse);

      // A question is addressed to the human, so it must not be collapsed into
      // the process timeline.
      expect(card.isProcess, isFalse);
      final rows = buildRows(transcript.items);
      expect(rows.single, isA<MessageRow>());
    });

    test('records the answers the harness wrote back', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {
          'callId': 'call-q',
          'name': 'ask_user_question',
          'arguments': jsonEncode({
            'questions': [
              {'id': 'q1', 'question': '继续吗？'},
            ],
          }),
        }))
        ..applyEvent(event('tool/result', 2, {
          'callId': 'call-q',
          'message': {
            'content': [
              {
                'type': 'text',
                'text': jsonEncode({
                  'answers': [
                    {'id': 'q1', 'selected': ['继续'], 'custom': ''},
                  ],
                }),
              },
            ],
          },
        }));

      final card = transcript.items.single as QuestionCard;
      expect(card.answered, isTrue);
      expect(card.answers!.single['selected'], ['继续']);
      // The card survives the result rather than turning into a tool call.
      expect(transcript.items, hasLength(1));
    });

    test('a malformed question call falls back to an ordinary tool call', () {
      for (final arguments in ['not json', '{}', '{"questions":[]}']) {
        final transcript = Transcript()
          ..applyEvent(event('tool/call', 1, {
            'callId': 'c',
            'name': 'ask_user_question',
            'arguments': arguments,
          }));
        expect(transcript.items.single, isA<ToolCall>(), reason: arguments);
      }
    });

    test('another tool with questions-shaped arguments is left alone', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {
          'callId': 'c',
          'name': 'pwsh',
          'arguments': jsonEncode({
            'questions': [
              {'id': 'q1'},
            ],
          }),
        }));
      expect(transcript.items.single, isA<ToolCall>());
    });

    test('parses the tool questions defensively', () {
      expect(parseToolQuestions(null), isNull);
      expect(parseToolQuestions(''), isNull);
      expect(parseToolQuestions('[]'), isNull);
      expect(parseToolQuestions('{"questions":[{"question":"no id"}]}'), isNull);
      expect(
        parseToolQuestions('{"questions":[{"id":"a","question":"Q"}]}'),
        hasLength(1),
      );
    });
  });

  group('buildRows', () {
    // The collapsing rule is what keeps a long agent run readable: without it a
    // single turn can bury the dialogue under dozens of tool cards.
    test('collapses a run of process items into one timeline', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {
          'content': [
            {'type': 'text', 'text': 'do it'},
          ],
        }))
        ..applyEvent(event('assistant/message', 2, {
          'message': {
            'content': [
              {'type': 'reasoning', 'text': 'thinking'},
            ],
          },
        }))
        ..applyEvent(event('tool/call', 3, {'callId': 'c1', 'name': 'pwsh'}))
        ..applyEvent(event('tool/result', 4, {
          'callId': 'c1',
          'message': {
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
          },
        }))
        ..applyEvent(event('assistant/message', 5, {
          'message': {
            'content': [
              {'type': 'text', 'text': 'done'},
            ],
          },
        }));

      final rows = buildRows(transcript.items);
      expect(
        rows.map((row) => row.runtimeType.toString()).toList(),
        ['MessageRow', 'ProcessTimeline', 'MessageRow'],
      );

      final timeline = rows[1] as ProcessTimeline;
      // The result merged into its call, so the run is reasoning + one call.
      expect(timeline.count, 2);
      expect(timeline.toolNames, ['pwsh']);
      expect(timeline.failureCount, 0);
      expect(timeline.runningCount, 0);
    });

    test('keeps two runs apart when a message separates them', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {'callId': 'a', 'name': 'pwsh'}))
        ..applyEvent(event('assistant/message', 2, {
          'message': {
            'content': [
              {'type': 'text', 'text': 'in between'},
            ],
          },
        }))
        ..applyEvent(event('tool/call', 3, {'callId': 'b', 'name': 'edit'}));

      final rows = buildRows(transcript.items);
      expect(rows, hasLength(3));
      expect(rows[1], isA<MessageRow>());
      expect((rows[0] as ProcessTimeline).toolNames, ['pwsh']);
      expect((rows[2] as ProcessTimeline).toolNames, ['edit']);
    });

    test('reports distinct tool names in first-seen order', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {'callId': 'a', 'name': 'edit'}))
        ..applyEvent(event('tool/call', 2, {'callId': 'b', 'name': 'pwsh'}))
        ..applyEvent(event('tool/call', 3, {'callId': 'c', 'name': 'edit'}));

      final timeline = buildRows(transcript.items).single as ProcessTimeline;
      expect(timeline.toolNames, ['edit', 'pwsh']);
      expect(timeline.count, 3);
    });

    test('counts failures and in-flight calls', () {
      final transcript = Transcript()
        ..applyEvent(event('tool/call', 1, {'callId': 'a', 'name': 'pwsh'}))
        ..applyEvent(event('tool/result', 2, {
          'callId': 'a',
          'error': {'code': 'boom'},
          'message': {
            'content': [
              {'type': 'text', 'text': 'failed'},
            ],
          },
        }))
        ..applyEvent(event('tool/call', 3, {'callId': 'b', 'name': 'edit'}));

      final timeline = buildRows(transcript.items).single as ProcessTimeline;
      expect(timeline.failureCount, 1);
      expect(timeline.runningCount, 1);
    });

    test('a transcript of only messages produces no timeline', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
        }))
        ..applyEvent(event('assistant/message', 2, {
          'message': {
            'content': [
              {'type': 'text', 'text': 'hello'},
            ],
          },
        }));

      final rows = buildRows(transcript.items);
      expect(rows, hasLength(2));
      expect(rows.every((row) => row is MessageRow), isTrue);
    });

    test('an empty transcript produces no rows', () {
      expect(buildRows(const []), isEmpty);
    });

    test('a trailing run is still collapsed', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {
          'content': [
            {'type': 'text', 'text': 'go'},
          ],
        }))
        ..applyEvent(event('tool/call', 2, {'callId': 'a', 'name': 'pwsh'}));

      final rows = buildRows(transcript.items);
      expect(rows, hasLength(2));
      expect(rows.last, isA<ProcessTimeline>());
    });
  });

  group('reverseIndexOf', () {
    // The chat view is a `reverse: true` list so that opening a session shows
    // the newest message. Index 0 must therefore resolve to the last item.
    test('maps layout index 0 to the newest item', () {
      expect(reverseIndexOf(3, 0), 2);
      expect(reverseIndexOf(3, 1), 1);
      expect(reverseIndexOf(3, 2), 0);
    });

    test('covers every position exactly once', () {
      final seen = <int>{};
      for (var index = 0; index < 5; index++) {
        seen.add(reverseIndexOf(5, index));
      }
      expect(seen, {0, 1, 2, 3, 4});
    });

    test('shows the newest bubble first for a real transcript', () {
      final transcript = Transcript()
        ..applyEvent(event('user/message', 1, {
          'content': [
            {'type': 'text', 'text': 'oldest'},
          ],
        }))
        ..applyEvent(event('user/message', 2, {
          'content': [
            {'type': 'text', 'text': 'newest'},
          ],
        }));

      final items = transcript.items;
      expect(textOf(items[reverseIndexOf(items.length, 0)]), 'newest');
      expect(textOf(items[reverseIndexOf(items.length, 1)]), 'oldest');
    });
  });

  group('SessionSummary', () {
    // Regression: the live harness returns `updatedAt` in milliseconds while
    // the relay's own device timestamps are seconds. Reading it as seconds made
    // every session render as "just now" (year 58000), silently.
    test('reads the harness timestamp as milliseconds', () {
      final session = SessionSummary.fromJson({
        'sessionId': 'session-abc',
        'updatedAt': 1790924301943,
      });
      expect(session.updatedAtTime, isNotNull);
      expect(session.updatedAtTime!.year, 2026);
    });

    test('still tolerates a seconds value', () {
      final session = SessionSummary.fromJson({
        'sessionId': 'session-abc',
        'updatedAt': 1790923866,
      });
      expect(session.updatedAtTime!.year, 2026);
    });

    test('is null when the field is missing', () {
      expect(SessionSummary.fromJson({'sessionId': 's'}).updatedAtTime, isNull);
    });

    test('reads the projected sequence for paging', () {
      final session = SessionSummary.fromJson({
        'sessionId': 's',
        'projections': {'kind': 'sequenced', 'asOfSeq': 2722, 'values': {}},
      });
      expect(session.asOfSeq, 2722);
    });

    test('reads the projected model selection', () {
      // `session.list` carries this, so the composer needs no extra request.
      final session = SessionSummary.fromJson({
        'sessionId': 's',
        'projections': {
          'asOfSeq': 5,
          'values': {
            'modelSelection': {
              'lastUsed': {'provider': 'p', 'model': 'old'},
              'next': {'provider': 'deepseek-account', 'model': 'deepseek-flash', 'reasoningEffort': 'high'},
            },
          },
        },
      });
      expect(session.model?.provider, 'deepseek-account');
      expect(session.model?.model, 'deepseek-flash');
      expect(session.model?.reasoningEffort, 'high');
    });

    test('falls back to lastUsed when nothing is queued', () {
      final session = SessionSummary.fromJson({
        'sessionId': 's',
        'projections': {
          'values': {
            'modelSelection': {
              'lastUsed': {'provider': 'p', 'model': 'used'},
              'next': null,
            },
          },
        },
      });
      expect(session.model?.model, 'used');
    });

    test('model is null without a projection', () {
      expect(SessionSummary.fromJson({'sessionId': 's'}).model, isNull);
    });

    test('defaults asOfSeq to zero when projections are absent', () {
      expect(SessionSummary.fromJson({'sessionId': 's'}).asOfSeq, 0);
    });

    test('prefers the harness title when there is one', () {
      final session = SessionSummary.fromJson({
        'sessionId': 'session-53840290-9365-457f-a548-2d9892757fd2',
        'updatedAt': 1,
        'projections': {
          'kind': 'sequenced',
          'asOfSeq': 2722,
          'values': {'title': '手机端远程控制方案'},
        },
        'cwd': r'C:\work',
      });
      expect(session.title, '手机端远程控制方案');
      expect(session.label, '手机端远程控制方案');
    });

    test('strips the constant session- prefix when there is no title', () {
      // Regression: using the first 8 characters made every row read "session-",
      // because that is exactly the length of the fixed prefix.
      final session = SessionSummary.fromJson({
        'sessionId': 'session-53840290-9365-457f-a548-2d9892757fd2',
        'updatedAt': 1,
        'cwd': r'C:\Users\Yui\Documents\deepseek-harness\default-workspace',
      });
      expect(session.label, '53840290 · default-workspace');
    });

    test('labels a session without a cwd by its short id', () {
      final session = SessionSummary.fromJson({'sessionId': 'session-53840290'});
      expect(session.label, '53840290');
    });

    test('an empty title falls back to the id', () {
      final session = SessionSummary.fromJson({
        'sessionId': 'session-abcdef01',
        'projections': {'values': {'title': '   '}},
      });
      expect(session.label, 'abcdef01');
    });

    test('recognises a subagent session from its projection', () {
      // Found by running the live suite while a subagent happened to be the newest
      // session: every op against it was refused with
      // `session/agent-busy: … is owned by subagent routing`, and the phone was
      // listing it as if it were an ordinary chat.
      final child = SessionSummary.fromJson({
        'sessionId': '32ba14f9-700f-4c08-9eb7-dc7927a37147',
        'projections': {
          'values': {
            'title': 'Write the app README',
            'subagent': {'mode': 'background', 'label': 'app-readme', 'seq': 3},
          },
        },
      });
      expect(child.isSubagent, isTrue);

      final normal = SessionSummary.fromJson({
        'sessionId': 'session-4352c774',
        'projections': {
          'values': {'title': '继续当前任务', 'subagent': <String, dynamic>{}},
        },
      });
      expect(normal.isSubagent, isFalse);
      expect(SessionSummary.fromJson({'sessionId': 's'}).isSubagent, isFalse);
    });
  });

  group('RelayDevice', () {
    test('parses the live device shape', () {
      // Copied from a real /api/v1/devices response.
      final device = RelayDevice.fromJson({
        'id': 'home-pc',
        'name': 'home-pc',
        'online': true,
        'platform': 'win32',
        'harnessVersion': '0.1.0',
        'capabilities': ['approvals', 'events', 'ops'],
        'lastSeen': 1790923866,
        'pendingRequests': 0,
        'connectedAt': 1790923866,
        'linkAgeSeconds': 1000,
      });

      expect(device.id, 'home-pc');
      expect(device.online, isTrue);
      expect(device.supportsApprovals, isTrue);
      expect(device.supportsEvents, isTrue);
      expect(device.linkAgeSeconds, 1000);
    });

    test('tolerates a device with no capabilities', () {
      final device = RelayDevice.fromJson({'id': 'x'});
      expect(device.capabilities, isEmpty);
      expect(device.online, isFalse);
      expect(device.supportsEvents, isFalse);
    });
  });

  group('ModelSelection', () {
    test('needs both a provider and a model', () {
      expect(ModelSelection.fromJson({'provider': 'p'}), isNull);
      expect(ModelSelection.fromJson({'model': 'm'}), isNull);
      expect(ModelSelection.fromJson(null), isNull);
      expect(ModelSelection.fromJson({'provider': 'p', 'model': 'm'}), isNotNull);
    });

    test('keeps a reasoning effort when present, drops an empty one', () {
      expect(
        ModelSelection.fromJson({'provider': 'p', 'model': 'm', 'reasoningEffort': 'high'})
            ?.reasoningEffort,
        'high',
      );
      expect(
        ModelSelection.fromJson({'provider': 'p', 'model': 'm', 'reasoningEffort': ''})
            ?.reasoningEffort,
        isNull,
      );
    });

    test('shortens a namespaced model id for display', () {
      expect(
        const ModelSelection(provider: 'p', model: 'vendor/model-x').shortName,
        'model-x',
      );
    });
  });

  group('ModelCatalog', () {
    // Copied from a real model.catalog response.
    final catalog = ModelCatalog.fromJson({
      'default': {'provider': 'deepseek-account', 'model': 'deepseek-flash', 'reasoningEffort': 'high'},
      'failures': [],
      'routableProviders': ['commandcode', 'deepseek-account'],
      'groups': [
        {
          'id': 'commandcode',
          'name': 'commandcode',
          'models': [
            {'id': 'claude-sonnet-5-5', 'name': 'Claude Sonnet 5.5'},
          ],
        },
        {
          'id': 'deepseek-account',
          'name': 'DeepSeek',
          'models': [
            {'id': 'deepseek-flash', 'name': 'DeepSeek Flash'},
          ],
        },
      ],
    });

    test('reads groups, models and the default', () {
      expect(catalog.groups, hasLength(2));
      expect(catalog.groups.first.id, 'commandcode');
      expect(catalog.groups.first.models.single.name, 'Claude Sonnet 5.5');
      expect(catalog.defaultSelection?.model, 'deepseek-flash');
      expect(catalog.isEmpty, isFalse);
    });

    test('resolves a display name across providers', () {
      expect(
        catalog.nameFor(const ModelSelection(provider: 'deepseek-account', model: 'deepseek-flash')),
        'DeepSeek Flash',
      );
    });

    test('falls back to the id for a model that is not listed', () {
      expect(
        catalog.nameFor(const ModelSelection(provider: 'gone', model: 'vendor/mystery')),
        'mystery',
      );
    });

    test('drops empty groups and tolerates junk', () {
      final sparse = ModelCatalog.fromJson({
        'groups': [
          {'id': 'empty', 'models': []},
          {'id': 'ok', 'models': [
            {'id': 'm'},
          ]},
          'not a map',
        ],
      });
      expect(sparse.groups, hasLength(1));
      expect(sparse.groups.single.models.single.name, 'm');
    });

    test('an empty catalog reports itself as empty', () {
      expect(ModelCatalog.fromJson(const {}).isEmpty, isTrue);
    });
  });

  group('ApprovalAsk', () {
    test('reads a tool approval', () {
      final ask = ApprovalAsk.fromEvent('approval.ask', {
        'askId': 'ask-1',
        'sessionId': 's1',
        'toolName': 'pwsh',
        'reason': 'run a command',
        'displayReason': {'zh': '执行命令'},
      });
      expect(ask.askId, 'ask-1');
      expect(ask.isQuestion, isFalse);
      expect(ask.toolName, 'pwsh');
      expect(ask.displayReason, '执行命令');
    });

    test('carries the device from the socket frame', () {
      // The payload has no deviceId — the frame does.
      final ask = ApprovalAsk.fromEvent(
        'approval.ask',
        {'askId': 'a', 'sessionId': 's'},
        deviceId: 'home-pc',
      );
      expect(ask.deviceId, 'home-pc');
    });

    test('reads the relay pending list shape', () {
      // Regression: a question raised while the phone was disconnected only
      // exists in this list, so parsing it wrong means it can never be shown.
      final ask = ApprovalAsk.fromWire({
        'askId': 'ask-7',
        'deviceId': 'home-pc',
        'topic': 'question.ask',
        'expiresInSeconds': 240,
        'payload': {
          'askId': 'ask-7',
          'sessionId': 'session-abc',
          'questions': [
            {'id': 'q1', 'question': '继续吗？'},
          ],
        },
      });
      expect(ask.askId, 'ask-7');
      expect(ask.deviceId, 'home-pc');
      expect(ask.topic, 'question.ask');
      expect(ask.isQuestion, isTrue);
      expect(ask.sessionId, 'session-abc');
      expect(ask.expiresInSeconds, 240);
      expect(ask.questions, hasLength(1));
    });

    test('falls back to the payload for the ask id', () {
      final ask = ApprovalAsk.fromWire({
        'topic': 'approval.ask',
        'payload': {'askId': 'inner', 'sessionId': 's'},
      });
      expect(ask.askId, 'inner');
    });

    test('reads a question with its options', () {      final ask = ApprovalAsk.fromEvent('question.ask', {
        'askId': 'ask-2',
        'sessionId': 's1',
        'questions': [
          {
            'id': 'q1',
            'question': 'Which database?',
            'options': [
              {'label': 'sqlite'},
              {'label': 'postgres'},
            ],
          },
        ],
      });
      expect(ask.isQuestion, isTrue);
      expect(ask.questions, hasLength(1));
      expect(asStringList((ask.questions.single['options'] as List)
          .map((option) => (option as Map)['label'])
          .toList()), ['sqlite', 'postgres']);
    });
  });
}
