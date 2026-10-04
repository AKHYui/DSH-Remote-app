/// A collapsed run of reasoning and tool activity.
///
/// Collapsed by default. The process is what makes a long agent run unreadable,
/// but collapsing must never hide a problem — so the header always reports how
/// much happened, whether anything failed, and whether a call is still in
/// flight. The body is a timeline with a left rail, each step a muted card.
library;

import 'package:flutter/material.dart';

import '../chat/transcript.dart';
import '../theme.dart';

class ProcessTimelineView extends StatefulWidget {
  const ProcessTimelineView({
    super.key,
    required this.timeline,
    this.initiallyExpanded = false,
  });

  final ProcessTimeline timeline;
  final bool initiallyExpanded;

  @override
  State<ProcessTimelineView> createState() => _ProcessTimelineViewState();
}

class _ProcessTimelineViewState extends State<ProcessTimelineView> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeline = widget.timeline;

    final failed = timeline.failureCount;
    final running = timeline.runningCount;

    // The dot carries the worst state in the run, so a collapsed timeline cannot
    // look healthy when it is not.
    final Color dotColor;
    if (failed > 0) {
      dotColor = AppColors.danger;
    } else if (running > 0) {
      dotColor = AppColors.accent;
    } else {
      dotColor = AppColors.accent;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppGap.tight),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.timeline),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  _StatusDot(color: dotColor, pulsing: running > 0),
                  const SizedBox(width: 8),
                  Text(
                    '共 ${timeline.count} 段过程',
                    style: theme.textTheme.titleSmall,
                  ),
                  if (failed > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      '$failed 失败',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.danger,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (running > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      '进行中',
                      style: theme.textTheme.labelSmall?.copyWith(color: AppColors.accentText),
                    ),
                  ],
                  const Spacer(),
                  _PillToggle(expanded: _expanded),
                ],
              ),
            ),
          ),
          // Only worth a summary line when collapsed and there is more than one
          // step: otherwise it just repeats the single card below it.
          if (!_expanded && timeline.count > 1 && timeline.toolNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 18, bottom: 2),
              child: Text(
                timeline.toolNames.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 5, top: 4, bottom: 4),
                      child: _Rail(),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final item in timeline.items)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: switch (item) {
                                ReasoningNote() => _ReasoningStep(text: item.text),
                                ToolCall() => _ToolStep(call: item),
                                _ => const SizedBox.shrink(),
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The vertical line the steps hang off.
class _Rail extends StatelessWidget {
  const _Rail();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 2,
      decoration: BoxDecoration(
        color: AppColors.rail,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color, this.pulsing = false});

  final Color color;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12,
      height: 12,
      child: Center(
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _PillToggle extends StatelessWidget {
  const _PillToggle({required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            expanded ? '收起' : '展开',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.accentText,
            ),
          ),
          Icon(
            expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
            size: 16,
            color: AppColors.accentText,
          ),
        ],
      ),
    );
  }
}

/// A reasoning step: muted prose, clamped until tapped.
class _ReasoningStep extends StatefulWidget {
  const _ReasoningStep({required this.text});

  final String text;

  @override
  State<_ReasoningStep> createState() => _ReasoningStepState();
}

class _ReasoningStepState extends State<_ReasoningStep> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      behavior: HitTestBehavior.opaque,
      child: Text(
        widget.text,
        maxLines: _expanded ? null : 3,
        overflow: _expanded ? null : TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
      ),
    );
  }
}

/// A tool call: name and status on one line, details on demand.
class _ToolStep extends StatefulWidget {
  const _ToolStep({required this.call});

  final ToolCall call;

  @override
  State<_ToolStep> createState() => _ToolStepState();
}

class _ToolStepState extends State<_ToolStep> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final call = widget.call;

    final (IconData icon, Color color, String label) = call.isError
        ? (Icons.error_outline_rounded, AppColors.danger, '失败')
        : call.hasResult
            ? (Icons.check_circle_outline_rounded, AppColors.accent, '完成')
            : (Icons.schedule_rounded, AppColors.textSecondary, '等待结果…');

    final hasDetail = call.arguments.isNotEmpty || (call.result?.isNotEmpty ?? false);

    return Material(
      // White, not muted: these cards sit directly on the grey page, so a muted
      // fill at page level made them invisible.
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.timeline),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.timeline),
        onTap: hasDetail ? () => setState(() => _expanded = !_expanded) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      call.name.isEmpty ? '工具调用' : call.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (hasDetail)
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: AppColors.textTertiary,
                    ),
                ],
              ),
              if (_expanded) ...[
                if (call.arguments.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _CodeBlock(label: '参数', text: call.arguments),
                ],
                if (call.result != null && call.result!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _CodeBlock(label: call.isError ? '错误' : '结果', text: call.result!),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.4),
          ),
        ),
      ],
    );
  }
}
