/// Attachments: what the user picked, whether it may be sent, and the exact
/// `content[]` blocks `session.prompt` receives.
///
/// Deliberately pure Dart — no Flutter, no `dart:io` — so the wire shapes and the
/// size rule are unit-testable without a widget or a socket. The UI layer keeps
/// the picking (`image_picker` / `file_picker`); this file owns the contract.
///
/// The wire contract, verified against DSH's own descriptors:
///
///   * `session.prompt` takes `content[]` of `{text}`, `{image: mediaType, data}`
///     and `{file: receiptId}` blocks;
///   * images go **inline** as base64 — there is no image upload call at all;
///   * anything else is uploaded first (`fileUploads.upload`) to earn the
///     `receiptId` a file block needs.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The relay refuses an HTTP body above this (`DSH_RELAY_MAX_REQUEST_BYTES`).
/// Base64 inflates by 4/3, so a single 2 MiB attachment lands near 2.8 MiB of
/// JSON and stays clear of the ceiling with room for the rest of the request.
const int relayMaxRequestBytes = 4 * 1024 * 1024;

/// The largest raw byte count this app will send as one attachment.
///
/// Enforced on the phone rather than left to the relay: a body rejected for size
/// comes back as an opaque 413 that no UI can explain, and the draft would be
/// gone by then.
const int maxAttachmentBytes = 2 * 1024 * 1024;

/// The media types `session.prompt` accepts for an inline image block.
const Set<String> imageMediaTypes = {
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
};

/// Image extensions, used when the magic bytes are not conclusive.
const Set<String> imageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'gif'};

/// One attachment the user has staged but not sent yet.
class PendingAttachment {
  const PendingAttachment({
    required this.id,
    required this.kind,
    required this.name,
    required this.bytes,
    this.mediaType,
  });

  /// Local only, for list keys and receipt lookups. Never sent.
  final String id;

  /// `image` or `file`.
  final String kind;
  final String name;
  final Uint8List bytes;

  /// Only meaningful for an image, and only set once the bytes have been
  /// sniffed: an image block is invalid without one of [imageMediaTypes].
  final String? mediaType;

  bool get isImage => kind == 'image';

  String get sizeLabel => formatBytes(bytes.length);

  /// The media type to send.
  ///
  /// Never a guess: when neither the bytes nor the name identify a supported
  /// image, this returns a sentinel that [attachmentRejection] refuses. Claiming
  /// `image/png` for unrecognised bytes would pass the admission check and then
  /// fail on the desktop, where a single refused image rejects the **whole**
  /// message — the user's text would be lost with it.
  String get wireMediaType =>
      mediaType ?? mediaTypeForName(name) ?? 'application/octet-stream';

  PendingAttachment copyWith({
    String? id,
    String? kind,
    String? name,
    Uint8List? bytes,
    String? mediaType,
  }) {
    return PendingAttachment(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      name: name ?? this.name,
      bytes: bytes ?? this.bytes,
      mediaType: mediaType ?? this.mediaType,
    );
  }

  /// Where to stage this for a prompt: an image when the bytes say so (or, when
  /// they do not, when the extension does).
  ///
  /// `kind: 'image'` with an unidentifiable format stays an image with a null
  /// [mediaType], so the admission rule can refuse it with a reason the user can
  /// act on instead of sending a mislabelled block.
  factory PendingAttachment.forContent({
    required String id,
    required String name,
    required Uint8List bytes,
    required String kind,
  }) {
    final mediaType = mediaTypeForBytes(bytes) ?? mediaTypeForName(name);
    final isImage = kind == 'image' || mediaType != null;
    return PendingAttachment(
      id: id,
      kind: isImage ? 'image' : 'file',
      name: name,
      bytes: bytes,
      mediaType: mediaType,
    );
  }

  /// A display name for bytes that arrived without one (a camera capture).
  static String namedFromExtension(String extension, {DateTime? now}) {
    final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return 'photo-$stamp.$extension';
  }
}

/// The outcome of the size/format admission rule.
class AttachmentAdmission {
  const AttachmentAdmission._(this.accepted, this.reason);

  const AttachmentAdmission.accept() : this._(true, null);
  const AttachmentAdmission.reject(String reason) : this._(false, reason);

  final bool accepted;

  /// A Chinese explanation, to be shown to the user as-is. Null when accepted.
  final String? reason;

  @override
  String toString() => accepted ? 'accepted' : 'rejected: $reason';
}

/// The one rule that decides whether a single attachment may go on the wire.
///
/// Returns `null` when it may, otherwise a message safe to show to the user.
/// The boundary is inclusive: exactly [maxAttachmentBytes] is still accepted.
String? attachmentRejection(PendingAttachment attachment) {
  if (attachment.bytes.isEmpty) return '“${attachment.name}”是空文件，发不了。';
  if (attachment.bytes.length > maxAttachmentBytes) {
    if (attachment.isImage) {
      return '图片太大（${formatBytes(attachment.bytes.length)}）'
          '，请换一张或先压缩（上限 2 MB）';
    }
    return '文件太大（${formatBytes(attachment.bytes.length)}）'
        '，请先压缩或换一个（上限 2 MB）';
  }
  if (attachment.isImage && !imageMediaTypes.contains(attachment.wireMediaType)) {
    if (looksLikeHeif(attachment.bytes)) {
      return '“${attachment.name}”是 HEIC 照片，先转成 JPEG 或 PNG 再发。';
    }
    return '“${attachment.name}”的图片格式不支持，请换 PNG / JPEG / WebP / GIF。';
  }
  return null;
}

/// `null` when the attachment may be sent, otherwise the reason it may not.
bool attachmentAllowed(PendingAttachment attachment) =>
    attachmentRejection(attachment) == null;

/// The media type for a file name, or null when the extension says nothing.
///
/// `.jpg` and `.jpeg` both mean `image/jpeg` — sending `image/jpg` would be
/// rejected by the harness, which validates the media type.
String? mediaTypeForName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  switch (extension) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    default:
      return null;
  }
}

/// True when the name looks like an image this app can send.
bool looksLikeImage(String name) => mediaTypeForName(name) != null;

/// The media type implied by the leading bytes, or null when unrecognised.
///
/// Cheaper and more trustworthy than the extension: `image_picker` returns a
/// cache path whose extension is not always the real format, and a mismatched
/// media type is a hard rejection from the harness.
String? mediaTypeForBytes(Uint8List bytes) {
  if (_startsWith(bytes, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (_startsWith(bytes, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (_startsWith(bytes, const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (bytes.length >= 12 &&
      _startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// True when the bytes are a HEIF/HEIC container (an iPhone's default photo
/// format), which none of the four accepted media types covers.
///
/// Recognised only to explain the refusal precisely: `image_picker` normally
/// re-encodes to JPEG, so this fires for a file that came in some other way.
bool looksLikeHeif(Uint8List bytes) {
  if (bytes.length < 12) return false;
  // ISO-BMFF: a 4-byte box length, then 'ftyp', then the brand.
  if (bytes[4] != 0x66 || bytes[5] != 0x74 || bytes[6] != 0x79 || bytes[7] != 0x70) {
    return false;
  }
  final brand = String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
  return brand == 'heic' || brand == 'heix' || brand == 'hevc' || brand == 'mif1' || brand == 'msf1';
}

/// Builds the exact `content[]` `session.prompt` takes.
///
/// Order is text first, then images, then files. A file block carries only its
/// `receiptId` — the bytes travel through `fileUploads.upload` instead — so this
/// throws rather than sending a block the harness would reject.
///
/// The text block is omitted when [text] is empty and something else is being
/// sent.
List<Map<String, dynamic>> contentBlocksFor({
  required String text,
  List<PendingAttachment> images = const [],
  List<PendingAttachment> files = const [],
  Map<String, String> receipts = const {},
}) {
  final blocks = <Map<String, dynamic>>[];

  final trimmed = text.trim();
  if (trimmed.isNotEmpty) {
    blocks.add({'type': 'text', 'text': text});
  }

  for (final image in images) {
    blocks.add({
      'type': 'image',
      'mediaType': image.wireMediaType,
      'data': base64Encode(image.bytes),
      if (image.name.isNotEmpty) 'name': image.name,
    });
  }

  for (final file in files) {
    final receipt = receipts[file.id];
    if (receipt == null || receipt.isEmpty) {
      throw ArgumentError('no receiptId for attachment ${file.id}');
    }
    blocks.add({'type': 'file', 'receiptId': receipt});
  }

  return blocks;
}

/// Convenience for callers holding one mixed list: splits it and builds.
List<Map<String, dynamic>> contentBlocksForAll(
  List<PendingAttachment> attachments, {
  String text = '',
  Map<String, String> receipts = const {},
}) {
  return contentBlocksFor(
    text: text,
    images: attachments.where((a) => a.isImage).toList(growable: false),
    files: attachments.where((a) => !a.isImage).toList(growable: false),
    receipts: receipts,
  );
}

/// The `request` body of `fileUploads.upload`: base64 of the raw bytes.
///
/// `data` is base64 of the bytes themselves, not a data URL — that is what
/// `dsh-client-file-upload` sends and what the Remote decodes.
Map<String, dynamic> uploadRequestFor(PendingAttachment attachment) {
  return {
    'data': base64Encode(attachment.bytes),
    if (attachment.name.isNotEmpty) 'name': attachment.name,
  };
}

/// `1.2 MB`, `340 KB`, `87 B`. One decimal place from KB up, so a size that sits
/// near the 2 MB ceiling reads honestly instead of rounding to `2 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(1)} MB';
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}
