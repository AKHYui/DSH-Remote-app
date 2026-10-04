/// The message composer: a white card holding a borderless field and a row of
/// actions, with a black circular send button as the strongest element.
///
/// Mirrors the reference app's composer, with one deliberate difference: the
/// chip on the left shows the **workspace**, not a model. `session.prompt` has no
/// model argument, so a model picker here would be a control that does nothing;
/// the workspace genuinely decides where a new session runs.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../chat/attachments.dart';
import '../theme.dart';

class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.onSend,
    this.onCancel,
    this.leading,
    this.hintText = '发消息…',
    this.busy = false,
    this.running = false,
    this.enabled = true,
    this.attachments = const [],
    this.uploading = false,
    this.onAttach,
    this.onRemoveAttachment,
  });

  final TextEditingController controller;

  /// Sends the current text. Returning a future keeps the busy state honest.
  final Future<void> Function() onSend;

  /// Aborts the running turn. Shown only while [running].
  final Future<void> Function()? onCancel;

  /// Optional chip above the actions row, e.g. the workspace.
  final Widget? leading;

  final String hintText;

  /// A send is in flight.
  final bool busy;

  /// The session has a turn in progress, so offer stop instead of send.
  final bool running;

  final bool enabled;

  /// Staged attachments, shown as a strip above the field.
  final List<PendingAttachment> attachments;

  /// A non-image upload is in flight, so the strip says so instead of freezing.
  final bool uploading;

  /// Tapping the paperclip. Null hides it — a surface that cannot attach
  /// anything should not offer the affordance.
  final VoidCallback? onAttach;

  final void Function(PendingAttachment attachment)? onRemoveAttachment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasAttachments = attachments.isNotEmpty;

    return Container(
      decoration: cardDecoration(),
      padding: const EdgeInsets.fromLTRB(AppGap.page, 14, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasAttachments) ...[
            AttachmentStrip(
              attachments: attachments,
              onRemove: onRemoveAttachment,
              enabled: enabled && !busy,
            ),
            const SizedBox(height: AppGap.base),
          ],
          TextField(
            controller: controller,
            enabled: enabled,
            minLines: 1,
            maxLines: 6,
            textInputAction: TextInputAction.newline,
            keyboardType: TextInputType.multiline,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: hintText,
              filled: false,
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(height: AppGap.base),
          // The leading pill shares this row with the controls, and `spaceBetween`
          // (with the buttons grouped into one child) is what makes that work: a
          // `Spacer` here is a *flexible* child too, so it and the pill used to
          // split the free width evenly and the pill could never use more than half
          // of it — which cut long model names mid-word on a phone.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // The placeholder is not decoration: `spaceBetween` with a single
              // child would place that child at the *start*, so a composer with no
              // leading widget would drop its buttons on the left.
              if (leading == null)
                const SizedBox.shrink()
              else
                Flexible(child: leading!),
              // The strip scrolls and the row never wraps, so the send button
              // cannot be pushed off a 853x480 emulator viewport.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Images alone need no explanation: they go inline and cost no
                  // extra request, so only a real upload is reported.
                  if (uploading || attachments.any((item) => !item.isImage)) ...[
                    _AttachmentStatus(
                      attachments: attachments,
                      uploading: uploading,
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (running && onCancel != null)
                    _CircleAction(
                      icon: Icons.stop_rounded,
                      tooltip: '中止当前回合',
                      background: AppColors.surfaceMutedStrong,
                      foreground: AppColors.textPrimary,
                      onTap: onCancel!,
                    ),
                  if (running && onCancel != null) const SizedBox(width: 8),
                  if (onAttach != null) ...[
                    _CircleAction(
                      icon: Icons.attach_file_rounded,
                      tooltip: '添加图片或文件',
                      background: AppColors.surfaceMuted,
                      foreground: AppColors.textPrimary,
                      onTap: enabled ? () async => onAttach!() : null,
                    ),
                    const SizedBox(width: 8),
                  ],
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      // Attachments alone are enough to send: a screenshot with no
                      // words is a legitimate turn.
                      final ready = enabled &&
                          !busy &&
                          (value.text.trim().isNotEmpty || hasAttachments);
                      return _CircleAction(
                        icon: Icons.arrow_upward_rounded,
                        tooltip: uploading ? '正在上传附件…' : '发送',
                        background: ready ? AppColors.primaryAction : AppColors.surfaceMutedStrong,
                        foreground: ready ? Colors.white : AppColors.textTertiary,
                        busy: busy,
                        onTap: ready ? onSend : null,
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The staged attachments, as a single horizontally scrolling strip.
///
/// One row that scrolls rather than a wrap: a wrapping strip grows upward and
/// squeezes the conversation away on a short viewport, and it moves the send
/// button as it does.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({
    super.key,
    required this.attachments,
    this.onRemove,
    this.enabled = true,
  });

  final List<PendingAttachment> attachments;
  final void Function(PendingAttachment attachment)? onRemove;
  final bool enabled;

  static const double height = 74;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: attachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final attachment = attachments[index];
          // A disabled × is still drawn: the tile must not reflow when a send
          // starts, and a control that vanishes mid-tap is worse than one that
          // is visibly inert.
          final removable = onRemove != null && enabled;
          return _AttachmentTile(
            attachment: attachment,
            showRemove: onRemove != null,
            onRemove: removable ? () => onRemove!(attachment) : null,
          );
        },
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
    required this.attachment,
    this.showRemove = false,
    this.onRemove,
  });

  final PendingAttachment attachment;

  /// Painted even when [onRemove] is null, so the strip keeps its shape.
  final bool showRemove;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final dimmed = showRemove && onRemove == null;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        attachment.isImage
            ? _Thumbnail(attachment: attachment)
            : _FileChip(attachment: attachment),
        if (showRemove)
          Positioned(
            top: -6,
            right: -6,
            // An explicit label, not just the tooltip: the tooltip's own message
            // would otherwise be the only thing a screen reader announced, with
            // no way to tell two attachments apart.
            child: Semantics(
              label: '移除${attachment.name}',
              button: true,
              child: Tooltip(
                message: '移除',
                child: Material(
                  color: dimmed ? AppColors.textTertiary : AppColors.textPrimary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onRemove,
                    child: const SizedBox(
                      width: 22,
                      height: 22,
                      child: Icon(Icons.close_rounded, size: 14, color: AppColors.surface),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.attachment});

  final PendingAttachment attachment;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${attachment.name} · ${attachment.sizeLabel}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.field),
        child: Image.memory(
          Uint8List.fromList(attachment.bytes),
          width: AttachmentStrip.height,
          height: AttachmentStrip.height,
          fit: BoxFit.cover,
          // Undecodable bytes must not blow up the composer; the tile falls back
          // to a plain image icon.
          errorBuilder: (context, error, stack) => _BrokenImage(),
        ),
      ),
    );
  }
}

class _BrokenImage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: AttachmentStrip.height,
      height: AttachmentStrip.height,
      color: AppColors.surfaceMuted,
      child: const Icon(Icons.broken_image_outlined, size: 22, color: AppColors.textSecondary),
    );
  }
}

/// A non-image attachment: file icon, name and size.
class _FileChip extends StatelessWidget {
  const _FileChip({required this.attachment});

  final PendingAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 190),
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.field),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 22, color: AppColors.textPrimary),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 122),
                child: Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(attachment.sizeLabel, style: theme.textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }
}

/// How many attachments are staged, and whether one is on its way up.
///
/// A file upload is a real request that can take seconds; saying so is the
/// difference between "working" and "frozen".
class _AttachmentStatus extends StatelessWidget {
  const _AttachmentStatus({required this.attachments, required this.uploading});

  final List<PendingAttachment> attachments;
  final bool uploading;

  @override
  Widget build(BuildContext context) {
    final pending = attachments.where((item) => !item.isImage).length;
    final label = uploading ? '上传中…' : '$pending 个文件待上传';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (uploading) ...[
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textSecondary),
          ),
          const SizedBox(width: 6),
        ],
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final Future<void> Function()? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap == null ? null : () => onTap!(),
          child: SizedBox(
            width: 44,
            height: 44,
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(13),
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Icon(icon, size: 21, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// The workspace chip: a pill on the muted surface, optionally tappable.
class WorkspaceChip extends StatelessWidget {
  const WorkspaceChip({super.key, required this.label, this.onTap, this.icon = Icons.folder_outlined});

  final String label;
  final VoidCallback? onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: AppColors.surfaceMuted,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 17, color: AppColors.textSecondary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
