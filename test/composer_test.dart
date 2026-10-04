/// Widget tests for the composer's attachment affordances.
///
/// The composer is stateless — the draft lives in [AppState] — so these tests
/// drive it directly with a list and assert on what a user sees: the paperclip,
/// the strip, the remove buttons, and a send button that is still reachable on a
/// short, narrow viewport.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_remote_app/chat/attachments.dart';
import 'package:dsh_remote_app/theme.dart';
import 'package:dsh_remote_app/ui/composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real 1x1 PNG, so the thumbnail path decodes rather than falling back.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AL+2wAAAABJRU5ErkJggg==',
);

PendingAttachment image(String id, {String name = 'shot.png'}) {
  return PendingAttachment.forContent(id: id, name: name, bytes: tinyPng, kind: 'image');
}

PendingAttachment document(String id, {String name = 'notes.txt', int length = 2048}) {
  return PendingAttachment.forContent(
    id: id,
    name: name,
    bytes: Uint8List(length)..setAll(0, [0x68, 0x69]),
    kind: 'file',
  );
}

Widget host({
  required TextEditingController controller,
  List<PendingAttachment> attachments = const [],
  bool busy = false,
  bool uploading = false,
  bool withAttach = true,
  void Function(PendingAttachment attachment)? onRemove,
  Future<void> Function()? onSend,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Composer(
          controller: controller,
          busy: busy,
          uploading: uploading,
          attachments: attachments,
          onAttach: withAttach ? () {} : null,
          onRemoveAttachment: onRemove,
          onSend: onSend ?? () async {},
        ),
      ),
    ),
  );
}

void main() {
  late TextEditingController input;

  setUp(() => input = TextEditingController());
  tearDown(() => input.dispose());

  testWidgets('the paperclip is offered only when a surface can attach', (tester) async {
    await tester.pumpWidget(host(controller: input));
    expect(find.byTooltip('添加图片或文件'), findsOneWidget);

    await tester.pumpWidget(host(controller: input, withAttach: false));
    expect(find.byTooltip('添加图片或文件'), findsNothing);
  });

  testWidgets('the strip shows a file name and its size', (tester) async {
    await tester.pumpWidget(host(
      controller: input,
      attachments: [document('f1', name: '报告.pdf', length: 348160)],
    ));

    expect(find.text('报告.pdf'), findsOneWidget);
    expect(find.text('340.0 KB'), findsOneWidget);
    // The file count is what needs uploading, and a bare chip would not say so.
    expect(find.text('1 个文件待上传'), findsOneWidget);
  });

  testWidgets('an attachments-only turn can be sent', (tester) async {
    var sent = 0;
    await tester.pumpWidget(host(
      controller: input,
      attachments: [image('i1')],
      onSend: () async => sent++,
    ));
    expect(input.text, isEmpty);

    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(sent, 1);
  });

  testWidgets('images alone raise no upload chatter, a busy send does', (tester) async {
    await tester.pumpWidget(host(controller: input, attachments: [image('i1')]));
    expect(find.textContaining('待上传'), findsNothing);

    await tester.pumpWidget(host(
      controller: input,
      attachments: [document('f1')],
      uploading: true,
    ));
    expect(find.text('上传中…'), findsOneWidget);
    expect(find.byTooltip('正在上传附件…'), findsOneWidget);
  });

  testWidgets('the strip cannot be edited while a send is in flight', (tester) async {
    var removed = 0;
    await tester.pumpWidget(host(
      controller: input,
      attachments: [document('f1')],
      busy: true,
      onRemove: (_) => removed++,
    ));

    // The × is still painted (the layout must not jump), just inert.
    final remove = find.byTooltip('移除');
    expect(remove, findsOneWidget);
    await tester.tap(remove, warnIfMissed: false);
    await tester.pump();
    expect(removed, 0);
  });

  testWidgets('each tile can be removed', (tester) async {
    PendingAttachment? removed;
    await tester.pumpWidget(host(
      controller: input,
      attachments: [image('i1', name: 'one.png'), document('f1', name: 'two.txt')],
      onRemove: (attachment) => removed = attachment,
    ));

    // Two tiles, so each has its own remove button and they cannot be confused.
    expect(find.byTooltip('移除'), findsNWidgets(2));
    expect(find.text('one.png'), findsNothing, reason: 'an image tile is a thumbnail');
    expect(find.text('two.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('移除').first);
    await tester.pump();
    expect(removed?.id, 'i1');

    await tester.tap(find.byTooltip('移除').last);
    await tester.pump();
    expect(removed?.id, 'f1', reason: 'the second button removes the second tile');
  });

  testWidgets('a narrow viewport keeps the send button on screen', (tester) async {
    // The emulator's logical window, and narrower: the strip scrolls, the action
    // row does not wrap, and the send button stays exactly where it was.
    tester.view.physicalSize = const Size(320, 320);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(
      controller: input,
      attachments: [
        for (var i = 0; i < 6; i++) document('f$i', name: '很长的文件名-$i.txt'),
      ],
    ));

    expect(tester.takeException(), isNull);
    final send = tester.getRect(find.byTooltip('发送'));
    expect(send.right, lessThanOrEqualTo(320));
    expect(send.left, greaterThanOrEqualTo(0));

    // The strip is one scrollable row, not a wrap that grows the composer.
    final strip = tester.widget<SizedBox>(
      find.ancestor(
        of: find.byType(ListView),
        matching: find.byType(SizedBox),
      ).first,
    );
    expect(strip.height, AttachmentStrip.height);
  });

  testWidgets('one long attachment name does not overflow the row', (tester) async {
    tester.view.physicalSize = const Size(320, 320);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(
      controller: input,
      attachments: [
        document('f1', name: '一个非常非常长的中文文件名用来测试省略号.txt'),
        image('i1'),
      ],
    ));

    expect(tester.takeException(), isNull);
  });

  testWidgets('a long chip, several files and the buttons still share one row', (tester) async {
    // The worst case the layout has to survive: a long workspace chip on the
    // left, an upload status in the middle, and both circular buttons on the
    // right — on a viewport narrower than the emulator's.
    tester.view.physicalSize = const Size(320, 320);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Composer(
          controller: input,
          uploading: true,
          attachments: [for (var i = 0; i < 4; i++) document('f$i', name: '文件-$i.txt')],
          onAttach: () {},
          onRemoveAttachment: (_) {},
          onSend: () async {},
          leading: const WorkspaceChip(label: '一个很长很长的工作区目录名'),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    final send = tester.getRect(find.byTooltip('正在上传附件…'));
    expect(send.right, lessThanOrEqualTo(320));
    expect(send.left, greaterThanOrEqualTo(0));
  });
}
