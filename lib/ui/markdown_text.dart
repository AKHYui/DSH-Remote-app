/// Renders the Markdown subset from `chat/markdown.dart`.
///
/// Kept separate from the parser so the formatting rules stay unit-testable
/// without a widget tree.
library;

import 'package:flutter/material.dart';

import '../chat/markdown.dart';
import '../theme.dart';

class MarkdownText extends StatelessWidget {
  const MarkdownText({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final blocks = parseMarkdown(text);
    if (blocks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks)
          Padding(
            padding: EdgeInsets.only(
              top: switch (block) {
                MdHeading() => 10,
                MdTable() => 8,
                MdRule() => 8,
                _ => 4,
              },
              bottom: 2,
            ),
            child: switch (block) {
              MdHeading() => _heading(context, block),
              MdParagraph() => _paragraph(context, block.text),
              MdBullet() => _bullet(context, block),
              MdCode() => _code(context, block),
              MdQuote() => _quote(context, block),
              MdRule() => _rule(),
              MdTable() => _table(context, block),
            },
          ),
      ],
    );
  }

  Widget _heading(BuildContext context, MdHeading heading) {
    final theme = Theme.of(context);
    final size = switch (heading.level) {
      1 => 20.0,
      2 => 17.5,
      _ => 15.5,
    };
    return SelectableText.rich(
      inlineSpans(
        heading.text,
        theme.textTheme.bodyMedium!.copyWith(fontSize: size, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _paragraph(BuildContext context, String source) {
    final theme = Theme.of(context);
    return SelectableText.rich(inlineSpans(source, theme.textTheme.bodyMedium!));
  }

  Widget _bullet(BuildContext context, MdBullet bullet) {
    final theme = Theme.of(context);

    // A task item shows a box, an ordered item shows its number, everything else
    // shows the usual dot. The lead column is fixed so the text of a mixed list
    // still lines up.
    final Widget lead = switch (bullet.checked) {
      true => const Icon(Icons.check_box_rounded, size: 15, color: AppColors.accentText),
      false => const Icon(Icons.check_box_outline_blank_rounded, size: 15, color: AppColors.textTertiary),
      null => Text(
          bullet.marker ?? '•',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: bullet.marker == null ? AppColors.textTertiary : AppColors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
    };

    return Padding(
      padding: EdgeInsets.only(left: 2 + bullet.depth * 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: SizedBox(width: 22, child: Align(alignment: Alignment.topLeft, child: lead)),
          ),
          Expanded(child: SelectableText.rich(inlineSpans(bullet.text, theme.textTheme.bodyMedium!))),
        ],
      ),
    );
  }

  Widget _quote(BuildContext context, MdQuote quote) {
    final theme = Theme.of(context);
    return Container(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.rail, width: 3)),
      ),
      padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
      child: SelectableText.rich(
        inlineSpans(
          quote.text,
          theme.textTheme.bodyMedium!.copyWith(color: AppColors.textSecondary),
        ),
      ),
    );
  }

  Widget _rule() => Container(height: 1, color: AppColors.divider);

  /// A GFM table.
  ///
  /// Scrolls sideways instead of squeezing: a four-column table on a phone cannot
  /// fit at a readable size, and shrinking the columns is how a table becomes
  /// unreadable rather than merely wide. Cells keep their raw source and go through
  /// the same inline parser as a paragraph.
  Widget _table(BuildContext context, MdTable table) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.bodySmall!.copyWith(fontWeight: FontWeight.w700);
    final cellStyle = theme.textTheme.bodySmall!;
    final available = MediaQuery.of(context).size.width - AppGap.page * 2;

    TextAlign alignOf(int column) => switch (table.alignments[column]) {
          MdAlign.center => TextAlign.center,
          MdAlign.right => TextAlign.right,
          MdAlign.left => TextAlign.left,
        };

    TableRow buildRow(List<String> cells, {required bool header}) {
      return TableRow(
        decoration: header ? const BoxDecoration(color: AppColors.surfaceMuted) : null,
        children: [
          for (var column = 0; column < table.columns; column++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: SelectableText.rich(
                inlineSpans(
                  column < cells.length ? cells[column] : '',
                  header ? headerStyle : cellStyle,
                ),
                textAlign: alignOf(column),
              ),
            ),
        ],
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        // Fill the width when the table is narrow, grow (and scroll) when it is not.
        constraints: BoxConstraints(minWidth: available > 0 ? available : 0),
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(
            color: AppColors.divider,
            width: 0.6,
            borderRadius: BorderRadius.circular(10),
          ),
          children: [
            buildRow(table.header, header: true),
            for (final row in table.rows) buildRow(row, header: false),
          ],
        ),
      ),
    );
  }

  Widget _code(BuildContext context, MdCode code) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (code.language != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(code.language!, style: theme.textTheme.labelSmall),
          ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            code.text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45),
          ),
        ),
      ],
    );
  }
}

/// Builds a styled [TextSpan] from one line of Markdown.
///
/// Links are shown as the label in the accent colour followed by the raw URL
/// when the two differ: this app has no URL launcher, so a tappable-looking link
/// would be a lie, but hiding the target would lose information.
TextSpan inlineSpans(String source, TextStyle base) {
  final runs = parseInline(source);
  return TextSpan(
    style: base,
    children: [
      for (final run in runs) ...[
        TextSpan(
          text: run.text,
          style: switch (run.style) {
            MdInlineStyle.plain =>
              run.link == null ? null : const TextStyle(color: AppColors.accentText),
            MdInlineStyle.bold => const TextStyle(fontWeight: FontWeight.w700),
            MdInlineStyle.italic => const TextStyle(fontStyle: FontStyle.italic),
            MdInlineStyle.code => const TextStyle(fontFamily: 'monospace', fontSize: 13.5),
            MdInlineStyle.strike =>
              const TextStyle(decoration: TextDecoration.lineThrough, color: AppColors.textTertiary),
          },
        ),
        if (run.link != null && run.link != run.text)
          TextSpan(
            text: ' ${run.link}',
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.textTertiary,
              fontFamily: 'monospace',
            ),
          ),
      ],
    ],
  );
}

/// Plain-prose fast path: skips the parser entirely when there is nothing to
/// format, which is most single-line messages.
class MarkdownOrPlain extends StatelessWidget {
  const MarkdownOrPlain({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (!hasMarkdown(text)) {
      return SelectableText(text, style: Theme.of(context).textTheme.bodyMedium);
    }
    return MarkdownText(text: text);
  }
}
