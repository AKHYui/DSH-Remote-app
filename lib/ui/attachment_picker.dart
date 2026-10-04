/// Picking an attachment: the bottom sheet behind the composer's paperclip.
///
/// Kept out of `composer.dart` so the widget stays presentational and the tests
/// never have to fake a platform channel. The two plugins split the work by what
/// the wire contract needs:
///
///   * `image_picker` for images — it downsamples and re-encodes **natively**
///     (`maxWidth`/`maxHeight`/`imageQuality`), which is what keeps a modern
///     phone photo under the relay's 4 MiB body limit. A Dart image library
///     doing the same job would need the whole bitmap in the heap first;
///   * `file_picker` for everything else — it goes through the Storage Access
///     Framework, so no storage permission is needed on any API level.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../chat/attachments.dart';
import '../theme.dart';

/// The long edge an image is compressed to before it is encoded.
///
/// 2000 px at JPEG quality 85 is roughly 0.4–0.8 MB for a typical photo: well
/// inside the 2 MB per-attachment ceiling, and still more detail than a phone
/// screen will show.
const int imageMaxEdge = 2000;
const int imageQuality = 85;

/// One picking round's outcome.
class AttachmentPickResult {
  const AttachmentPickResult({this.attachments = const [], this.error});

  final List<PendingAttachment> attachments;

  /// A message to show the user. Set when something was picked but refused
  /// (too large, unreadable), which must never look like a silent cancel.
  final String? error;

  bool get isEmpty => attachments.isEmpty;
}

/// Asks the user what to attach, then returns one picking round's outcome.
///
/// A null return means the sheet itself was dismissed. Everything that comes
/// back has already passed [attachmentRejection], so the caller only has to
/// surface [AttachmentPickResult.error].
Future<AttachmentPickResult?> pickAttachment(BuildContext context) async {
  final source = await _askSource(context);
  if (source == null || !context.mounted) return null;

  return switch (source) {
    _PickSource.camera => _pickImages(context, ImageSource.camera),
    _PickSource.gallery => _pickImages(context, ImageSource.gallery),
    _PickSource.file => _pickFiles(context),
  };
}

enum _PickSource { camera, gallery, file }

Future<_PickSource?> _askSource(BuildContext context) {
  return showModalBottomSheet<_PickSource>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceMutedStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppGap.page, 0, AppGap.page, 8),
            child: Text('添加附件', style: Theme.of(sheetContext).textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined, size: 20),
            title: const Text('拍照'),
            subtitle: const Text('自动缩到长边 2000 像素'),
            onTap: () => Navigator.of(sheetContext).pop(_PickSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, size: 20),
            title: const Text('从相册选择'),
            subtitle: const Text('可多选，图片直接内嵌发送'),
            onTap: () => Navigator.of(sheetContext).pop(_PickSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined, size: 20),
            title: const Text('选择文件'),
            subtitle: const Text('先上传到中继，再随消息发出'),
            onTap: () => Navigator.of(sheetContext).pop(_PickSource.file),
          ),
          const SizedBox(height: AppGap.base),
        ],
      ),
    ),
  );
}

/// Camera captures and gallery picks both go through here: the only difference
/// is the `ImageSource`, and both must come back downscaled.
Future<AttachmentPickResult> _pickImages(BuildContext context, ImageSource source) async {
  final picker = ImagePicker();
  final List<XFile> picked;
  try {
    if (source == ImageSource.camera) {
      final shot = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: imageMaxEdge.toDouble(),
        maxHeight: imageMaxEdge.toDouble(),
        imageQuality: imageQuality,
      );
      picked = shot == null ? const [] : [shot];
    } else {
      picked = await picker.pickMultiImage(
        maxWidth: imageMaxEdge.toDouble(),
        maxHeight: imageMaxEdge.toDouble(),
        imageQuality: imageQuality,
      );
    }
  } on Object catch (error) {
    return AttachmentPickResult(error: _readable('打不开图片选择器', error));
  }

  final attachments = <PendingAttachment>[];
  final errors = <String>[];

  for (final file in picked) {
    try {
      final bytes = await file.readAsBytes();
      final attachment = PendingAttachment.forContent(
        id: localAttachmentId(),
        name: _imageName(file),
        bytes: bytes,
        kind: 'image',
      );
      final reason = attachmentRejection(attachment);
      if (reason != null) {
        errors.add(reason);
        continue;
      }
      attachments.add(attachment);
    } on Object catch (error) {
      errors.add('读不到“${file.name}”：${_readable('', error)}');
    }
  }

  return AttachmentPickResult(
    attachments: attachments,
    error: errors.isEmpty ? null : errors.join('\n'),
  );
}

Future<AttachmentPickResult> _pickFiles(BuildContext context) async {
  final FilePickerResult? picked;
  try {
    picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      // Ask for the bytes directly. On Android the alternative is a content://
      // URI with a path this app cannot open.
      withData: true,
    );
  } on Object catch (error) {
    return AttachmentPickResult(error: _readable('打不开文件选择器', error));
  }

  if (picked == null || picked.files.isEmpty) {
    return const AttachmentPickResult();
  }

  final attachments = <PendingAttachment>[];
  final errors = <String>[];

  for (final file in picked.files) {
    final bytes = await _bytesOf(file);
    if (bytes == null || bytes.isEmpty) {
      errors.add('读不到“${file.name}”的内容。');
      continue;
    }
    final attachment = PendingAttachment.forContent(
      id: localAttachmentId(),
      name: file.name,
      bytes: bytes,
      // A "file" that is really an image goes inline; the bytes decide, so a
      // PNG chosen through 选择文件 still skips the upload round trip.
      kind: 'file',
    );
    final reason = attachmentRejection(attachment);
    if (reason != null) {
      errors.add(reason);
      continue;
    }
    attachments.add(attachment);
  }

  return AttachmentPickResult(
    attachments: attachments,
    error: errors.isEmpty ? null : errors.join('\n'),
  );
}

/// A picked file's bytes, from the platform's own copy or from disk.
Future<Uint8List?> _bytesOf(PlatformFile file) async {
  final inMemory = file.bytes;
  if (inMemory != null && inMemory.isNotEmpty) return inMemory;
  final path = file.path;
  if (path == null || path.isEmpty) return null;
  try {
    return await File(path).readAsBytes();
  } on Object {
    return null;
  }
}

String _imageName(XFile file) {
  if (file.name.isNotEmpty) return file.name;
  return PendingAttachment.namedFromExtension('jpg');
}

/// Non-empty prose for a thrown object: some platform errors stringify to ''.
String _readable(String prefix, Object error) {
  final text = '$error';
  final detail = text.isEmpty ? error.runtimeType.toString() : text;
  return prefix.isEmpty ? detail : '$prefix：$detail';
}

/// Unique per staged attachment. It is both the list key and the receipt
/// lookup, so two picks of the same file must not collide.
int _idCounter = 0;
String localAttachmentId() => 'att-${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';
