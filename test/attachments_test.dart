/// Unit tests for the attachment contract.
///
/// This file is where the wire shapes live, because getting one wrong is silent:
/// a mismatched media type or a missing `receiptId` is rejected by the harness,
/// not by the app. It is all pure Dart, so it runs without a device.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_remote_app/chat/attachments.dart';
import 'package:flutter_test/flutter_test.dart';

/// The leading bytes of a real file of each kind.
Uint8List pngBytes([int length = 16]) {
  final bytes = Uint8List(length);
  bytes.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  return bytes;
}

Uint8List jpegBytes([int length = 16]) {
  final bytes = Uint8List(length);
  bytes.setAll(0, [0xFF, 0xD8, 0xFF, 0xE0]);
  return bytes;
}

Uint8List gifBytes([int length = 16]) {
  final bytes = Uint8List(length);
  bytes.setAll(0, [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
  return bytes;
}

Uint8List webpBytes([int length = 16]) {
  final bytes = Uint8List(length);
  bytes.setAll(0, [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);
  return bytes;
}

Uint8List plainBytes(int length) => Uint8List(length)..setAll(0, [0x68, 0x69]);

/// A HEIF/HEIC header: an ISO-BMFF box length, `ftyp`, then the brand.
Uint8List heicBytes([String brand = 'heic']) {
  final bytes = Uint8List(24);
  bytes.setAll(4, [0x66, 0x74, 0x79, 0x70]);
  bytes.setAll(8, brand.codeUnits);
  return bytes;
}

PendingAttachment image(String id, {int length = 16, String name = 'shot.png'}) {
  return PendingAttachment.forContent(
    id: id,
    name: name,
    bytes: pngBytes(length),
    kind: 'image',
  );
}

PendingAttachment document(String id, {int length = 32, String name = 'notes.txt'}) {
  return PendingAttachment.forContent(
    id: id,
    name: name,
    bytes: plainBytes(length),
    kind: 'file',
  );
}

void main() {
  group('mediaTypeForName', () {
    test('maps every accepted extension to the exact wire media type', () {
      expect(mediaTypeForName('a.png'), 'image/png');
      expect(mediaTypeForName('a.jpg'), 'image/jpeg');
      // The harness validates the media type, so `image/jpg` would be refused.
      expect(mediaTypeForName('a.jpeg'), 'image/jpeg');
      expect(mediaTypeForName('a.webp'), 'image/webp');
      expect(mediaTypeForName('a.gif'), 'image/gif');
    });

    test('is case-insensitive and uses the last dot', () {
      expect(mediaTypeForName('REPORT.PNG'), 'image/png');
      expect(mediaTypeForName('archive.tar.gz'), isNull);
      expect(mediaTypeForName('a.JPeG'), 'image/jpeg');
    });

    test('returns null for anything else', () {
      expect(mediaTypeForName('notes.txt'), isNull);
      expect(mediaTypeForName('no-extension'), isNull);
      expect(mediaTypeForName('trailing.'), isNull);
      expect(mediaTypeForName(''), isNull);
    });
  });

  group('mediaTypeForBytes', () {
    test('recognises the four accepted formats from their magic bytes', () {
      expect(mediaTypeForBytes(pngBytes()), 'image/png');
      expect(mediaTypeForBytes(jpegBytes()), 'image/jpeg');
      expect(mediaTypeForBytes(gifBytes()), 'image/gif');
      expect(mediaTypeForBytes(webpBytes()), 'image/webp');
    });

    test('does not guess', () {
      expect(mediaTypeForBytes(plainBytes(64)), isNull);
      expect(mediaTypeForBytes(Uint8List(0)), isNull);
      // RIFF without the WEBP tag is some other container (a WAV, say).
      final wav = Uint8List(16)..setAll(0, [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45]);
      expect(mediaTypeForBytes(wav), isNull);
    });

    test('trusts the bytes over a lying extension', () {
      final attachment = PendingAttachment.forContent(
        id: 'a1',
        name: 'actually-a-photo.jpg',
        bytes: pngBytes(),
        kind: 'file',
      );
      expect(attachment.isImage, isTrue);
      expect(attachment.kind, 'image');
      expect(attachment.mediaType, 'image/png');
    });

    test('an image extension alone is enough to type an image', () {
      final attachment = PendingAttachment.forContent(
        id: 'a1',
        name: 'photo.jpeg',
        bytes: plainBytes(16),
        kind: 'image',
      );
      expect(attachment.kind, 'image');
      expect(attachment.mediaType, 'image/jpeg');
      expect(attachment.wireMediaType, 'image/jpeg');
    });

    test('an unidentifiable image is never relabelled as PNG', () {
      // The trap: guessing `image/png` passes admission and then the desktop
      // refuses the image, which rejects the WHOLE message — the user's text is
      // lost with it. Unidentifiable must mean "refused, with a reason".
      final attachment = PendingAttachment.forContent(
        id: 'a1',
        name: 'mystery.bin',
        bytes: plainBytes(32),
        kind: 'image',
      );
      expect(attachment.isImage, isTrue);
      expect(attachment.mediaType, isNull);
      expect(imageMediaTypes.contains(attachment.wireMediaType), isFalse);
      expect(attachmentRejection(attachment), contains('图片格式不支持'));
    });

    test('a HEIC photo is refused by name, because that is what it is', () {
      expect(looksLikeHeif(heicBytes()), isTrue);
      expect(looksLikeHeif(heicBytes('heix')), isTrue);
      expect(looksLikeHeif(pngBytes()), isFalse);
      expect(looksLikeHeif(plainBytes(4)), isFalse);

      final attachment = PendingAttachment.forContent(
        id: 'a1',
        name: 'IMG_0001.HEIC',
        bytes: heicBytes(),
        kind: 'image',
      );
      final reason = attachmentRejection(attachment);
      expect(reason, contains('HEIC'));
      expect(reason, contains('JPEG'));
      expect(attachment.wireMediaType, 'application/octet-stream');
    });
  });

  group('sizeLabel', () {
    test('reads in B, KB and MB', () {
      expect(document('a', length: 87).sizeLabel, '87 B');
      expect(document('a', length: 1024).sizeLabel, '1.0 KB');
      expect(document('a', length: 348160).sizeLabel, '340.0 KB');
      expect(document('a', length: 1258291).sizeLabel, '1.2 MB');
    });
  });

  group('the 2 MiB admission rule', () {
    test('accepts exactly 2 MiB — the boundary is inclusive', () {
      final exact = document('a', length: maxAttachmentBytes);
      expect(exact.bytes.length, 2097152);
      expect(attachmentRejection(exact), isNull);
      expect(attachmentAllowed(exact), isTrue);
    });

    test('rejects one byte over, with the size in the message', () {
      final over = document('a', length: maxAttachmentBytes + 1, name: 'big.zip');
      final reason = attachmentRejection(over);
      expect(reason, isNotNull);
      expect(reason, contains('2.0 MB'));
      expect(reason, contains('上限 2 MB'));
      expect(attachmentAllowed(over), isFalse);
    });

    test('an oversized image is told to be compressed or replaced', () {
      final over = image('a', length: maxAttachmentBytes + 1, name: 'huge.png');
      final reason = attachmentRejection(over);
      expect(reason, contains('图片太大'));
      expect(reason, contains('请换一张或先压缩'));
    });

    test('an oversized non-image names the file rule', () {
      final over = document('a', length: maxAttachmentBytes + 1);
      expect(attachmentRejection(over), contains('文件太大'));
    });

    test('an empty file is refused — the harness would reject it too', () {
      final empty = PendingAttachment(
        id: 'a',
        kind: 'file',
        name: 'empty.txt',
        bytes: Uint8List(0),
      );
      expect(attachmentRejection(empty), contains('空文件'));
    });

    test('an image whose media type is not one of the four is refused', () {
      final odd = PendingAttachment(
        id: 'a',
        kind: 'image',
        name: 'shot.heic',
        bytes: pngBytes(),
        mediaType: 'image/heic',
      );
      expect(attachmentRejection(odd), contains('不支持'));
    });
  });

  group('contentBlocksFor', () {
    test('puts text first, then images, then files', () {
      final blocks = contentBlocksFor(
        text: '看这张图和这个文件',
        images: [image('img-1')],
        files: [document('file-1')],
        receipts: {'file-1': 'rcpt-9'},
      );

      expect(blocks, hasLength(3));
      expect(blocks[0]['type'], 'text');
      // Text is sent verbatim, not trimmed: the harness renders what was typed.
      expect(blocks[0]['text'], '看这张图和这个文件');
      expect(blocks[1], {
        'type': 'image',
        'mediaType': 'image/png',
        'data': base64Encode(pngBytes()),
        'name': 'shot.png',
      });
      expect(blocks[2], {'type': 'file', 'receiptId': 'rcpt-9'});
    });

    test('omits the text block when there is no text', () {
      final blocks = contentBlocksFor(
        text: '   ',
        images: [image('img-1')],
      );
      expect(blocks, hasLength(1));
      expect(blocks.single['type'], 'image');
    });

    test('a file block carries the receipt and nothing else', () {
      final blocks = contentBlocksFor(
        text: '',
        files: [document('file-1', name: 'notes.txt')],
        receipts: {'file-1': 'rcpt-1'},
      );
      expect(blocks.single, {'type': 'file', 'receiptId': 'rcpt-1'});
      final encoded = jsonEncode(blocks);
      // The bytes must not ride along: they were uploaded already, and a second
      // copy would double the body size.
      expect(encoded, isNot(contains('data')));
      expect(encoded, isNot(contains('notes.txt')));
    });

    test('a file without a receipt is a programming error, not a silent drop', () {
      expect(
        () => contentBlocksFor(text: 'hi', files: [document('file-1')]),
        throwsArgumentError,
      );
    });

    test('several images keep their order and their own media types', () {
      final jpeg = PendingAttachment.forContent(
        id: 'b',
        name: 'b.jpeg',
        bytes: jpegBytes(),
        kind: 'image',
      );
      final blocks = contentBlocksFor(text: 'x', images: [image('a'), jpeg]);
      expect(blocks[1]['data'], base64Encode(pngBytes()));
      expect(blocks[1]['mediaType'], 'image/png');
      expect(blocks[2]['mediaType'], 'image/jpeg');
      expect(blocks[2]['data'], base64Encode(jpegBytes()));
    });

    test('contentBlocksForAll splits one mixed list in place', () {
      final blocks = contentBlocksForAll(
        [image('img-1'), document('file-1'), image('img-2')],
        text: 'hi',
        receipts: {'file-1': 'rcpt-7'},
      );
      expect(blocks.map((block) => block['type']).toList(), ['text', 'image', 'image', 'file']);
      expect(blocks.last['receiptId'], 'rcpt-7');
    });
  });

  group('uploadRequestFor', () {
    test('is base64 of the raw bytes and carries the name', () {
      final request = uploadRequestFor(document('a', name: 'notes.txt'));
      expect(request['data'], base64Encode(plainBytes(32)));
      expect(request['name'], 'notes.txt');
    });

    test('omits an empty name rather than sending one', () {
      final request = uploadRequestFor(PendingAttachment(
        id: 'a',
        kind: 'file',
        name: '',
        bytes: plainBytes(8),
      ));
      expect(request.containsKey('name'), isFalse);
    });
  });

  test('the relay body limit has room for a 2 MiB attachment after base64', () {
    // 2 MiB of raw bytes becomes ~2.8 MiB of base64; the request that carries it
    // must still fit under the relay's 4 MiB ceiling.
    final inflated = (maxAttachmentBytes * 4 / 3).ceil();
    expect(inflated, lessThan(relayMaxRequestBytes));
    expect(relayMaxRequestBytes - inflated, greaterThan(1024 * 1024));
  });
}
