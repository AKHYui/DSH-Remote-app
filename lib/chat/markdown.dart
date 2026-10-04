/// A deliberately small Markdown subset.
///
/// DSH output is full of `## headings`, `**bold**`, `inline code` and links, and
/// showing them literally makes correct output look broken. Rather than take a
/// rendering dependency, this handles the subset that actually appears and
/// leaves anything it does not understand **exactly as written** — a formatter
/// that silently mangles unusual input is worse than no formatter.
///
/// Links are rendered as `label` plus the URL, not as tappable text: opening a
/// URL needs a platform launcher, which this app does not have, and something
/// that looks tappable but is not is worse than something that obviously is not.
library;

/// A block-level piece of a message.
sealed class MdBlock {
  const MdBlock();
}

final class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

final class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

final class MdBullet extends MdBlock {
  const MdBullet(this.text, this.depth, {this.marker, this.checked});

  final String text;

  /// Nesting level, from the leading spaces (two per level).
  final int depth;

  /// The literal marker (`1.`, `-`) when it carries meaning. An ordered list whose
  /// numbers are thrown away reads as a broken list, so they are kept.
  final String? marker;

  /// Task-list state: null when the item is not a task, false for `[ ]`, true for
  /// `[x]`.
  final bool? checked;
}

final class MdCode extends MdBlock {
  const MdCode(this.text, this.language);
  final String text;
  final String? language;
}

/// `---`, `***` or `___` on a line of its own.
final class MdRule extends MdBlock {
  const MdRule();
}

/// A `> quoted` run, already stripped of its markers.
final class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

enum MdAlign { left, center, right }

/// One GFM pipe table: a header row, the body rows, and per-column alignment.
///
/// Cells hold their **raw** source so the renderer can format each one with the
/// same inline rules as a paragraph — a table cell full of `**bold**` should not
/// be the one place markdown leaks through as literal asterisks.
final class MdTable extends MdBlock {
  const MdTable(this.header, this.rows, this.alignments);

  final List<String> header;
  final List<List<String>> rows;

  /// One entry per column, taken from the delimiter row's colons.
  final List<MdAlign> alignments;

  int get columns => header.length;
}

enum MdInlineStyle { plain, bold, italic, code, strike }

class MdInline {
  const MdInline(this.text, this.style, {this.link});

  final String text;
  final MdInlineStyle style;

  /// Set when the run came from `[label](url)`.
  final String? link;
}

/// Splits one table row into cells.
///
/// `\|` is an escaped pipe, and a pipe inside a code span (`` `a|b` ``) is content
/// rather than a separator — GFM's rule, and the one that actually shows up when a
/// model puts a shell pipeline in a table.
List<String>? splitTableRow(String line) {
  final trimmed = line.trim();
  if (!trimmed.contains('|')) return null;

  var body = trimmed;
  if (body.startsWith('|')) body = body.substring(1);
  if (body.endsWith('|') && !body.endsWith(r'\|')) body = body.substring(0, body.length - 1);

  final cells = <String>[];
  final buffer = StringBuffer();
  var inCode = false;

  for (var i = 0; i < body.length; i++) {
    final char = body[i];
    if (char == '`') {
      inCode = !inCode;
      buffer.write(char);
      continue;
    }
    // `\|` is the table's own escape, so it is unescaped even inside a code span:
    // a model that writes `` `ls \| wc` `` means the pipe, not a backslash.
    if (char == r'\' && i + 1 < body.length && body[i + 1] == '|') {
      buffer.write('|');
      i++;
      continue;
    }
    if (!inCode && char == '|') {
      cells.add(buffer.toString().trim());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  buffer.write('');
  cells.add(buffer.toString().trim());
  return cells;
}

final _delimiterCell = RegExp(r'^:?-+:?$');

/// Parses a `|---|:--:|` row into per-column alignments, or null when it is not a
/// delimiter row at all.
List<MdAlign>? tableAlignments(List<String> cells) {
  if (cells.isEmpty) return null;
  final alignments = <MdAlign>[];
  for (final cell in cells) {
    if (!_delimiterCell.hasMatch(cell)) return null;
    final left = cell.startsWith(':');
    final right = cell.endsWith(':');
    alignments.add(
      left && right
          ? MdAlign.center
          : right
              ? MdAlign.right
              : MdAlign.left,
    );
  }
  return alignments;
}

final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
final _bullet = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$');
final _task = RegExp(r'^\[([ xX])\]\s*(.*)$');

/// Splits a message into blocks.
List<MdBlock> parseMarkdown(String source) {
  final blocks = <MdBlock>[];
  final lines = source.split('\n');
  final paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(MdParagraph(paragraph.join('\n')));
    paragraph.clear();
  }

  var index = 0;
  while (index < lines.length) {
    final line = lines[index];

    // Fenced code: no inline parsing inside, and the fence itself is dropped.
    final fence = RegExp(r'^\s*```\s*(\S*)\s*$').firstMatch(line);
    if (fence != null) {
      flushParagraph();
      final language = fence.group(1);
      final body = <String>[];
      index++;
      while (index < lines.length && !RegExp(r'^\s*```').hasMatch(lines[index])) {
        body.add(lines[index]);
        index++;
      }
      // Skip the closing fence when there is one.
      if (index < lines.length) index++;
      blocks.add(MdCode(body.join('\n'), (language ?? '').isEmpty ? null : language));
      continue;
    }

    if (line.trim().isEmpty) {
      flushParagraph();
      index++;
      continue;
    }

    // A table needs both a header row and the delimiter row under it, and the two
    // must agree on the number of columns. Without that check a paragraph that
    // merely contains a pipe would be swallowed.
    final header = splitTableRow(line);
    if (header != null && index + 1 < lines.length) {
      final delimiters = splitTableRow(lines[index + 1]);
      final alignments = delimiters == null ? null : tableAlignments(delimiters);
      if (alignments != null && alignments.length == header.length) {
        flushParagraph();
        final rows = <List<String>>[];
        index += 2;
        while (index < lines.length) {
          final row = splitTableRow(lines[index]);
          if (row == null || row.every((cell) => cell.isEmpty)) break;
          // Ragged rows are common in model output; pad and truncate to the header
          // rather than dropping the row or throwing.
          final fitted = List<String>.generate(
            header.length,
            (column) => column < row.length ? row[column] : '',
          );
          rows.add(fitted);
          index++;
        }
        blocks.add(MdTable(header, rows, alignments));
        continue;
      }
    }

    if (_rule.hasMatch(line)) {
      flushParagraph();
      blocks.add(const MdRule());
      index++;
      continue;
    }

    final quote = RegExp(r'^\s*>\s?(.*)$').firstMatch(line);
    if (quote != null) {
      flushParagraph();
      final body = <String>[quote.group(1)!];
      index++;
      while (index < lines.length) {
        final next = RegExp(r'^\s*>\s?(.*)$').firstMatch(lines[index]);
        if (next == null) break;
        body.add(next.group(1)!);
        index++;
      }
      blocks.add(MdQuote(body.join('\n')));
      continue;
    }

    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      flushParagraph();
      blocks.add(MdHeading(heading.group(1)!.length, heading.group(2)!.trim()));
      index++;
      continue;
    }

    final bullet = _bullet.firstMatch(line);
    if (bullet != null) {
      flushParagraph();
      final marker = bullet.group(2)!;
      var text = bullet.group(3)!.trim();
      bool? checked;
      final task = _task.firstMatch(text);
      if (task != null) {
        checked = task.group(1)!.toLowerCase() == 'x';
        text = task.group(2)!.trim();
      }
      blocks.add(
        MdBullet(
          text,
          bullet.group(1)!.length ~/ 2,
          // A bullet that is literally `-` says nothing; a number does.
          marker: marker == '-' || marker == '*' || marker == '+' ? null : marker,
          checked: checked,
        ),
      );
      index++;
      continue;
    }

    paragraph.add(line);
    index++;
  }

  flushParagraph();
  return blocks;
}

const _punctuation = '.,;:!?)]}\'"、。，！？；：）】」';

bool _isSpace(String char) => char == ' ' || char == '\t' || char == '\n';

bool _isBoundary(String char) =>
    _isSpace(char) || _punctuation.contains(char);

/// Splits a line into styled runs.
///
/// Unmatched markers (`**oops`) are emitted as plain text rather than swallowed.
List<MdInline> parseInline(String text) {
  final runs = <MdInline>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    runs.add(MdInline(buffer.toString(), MdInlineStyle.plain));
    buffer.clear();
  }

  var i = 0;
  while (i < text.length) {
    final char = text[i];

    if (char == '`') {
      final end = text.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        runs.add(MdInline(text.substring(i + 1, end), MdInlineStyle.code));
        i = end + 1;
        continue;
      }
    }

    if (text.startsWith('**', i)) {
      final end = text.indexOf('**', i + 2);
      if (end > i + 2) {
        flush();
        runs.add(MdInline(text.substring(i + 2, end), MdInlineStyle.bold));
        i = end + 2;
        continue;
      }
    }

    if (text.startsWith('~~', i)) {
      final end = text.indexOf('~~', i + 2);
      if (end > i + 2) {
        flush();
        runs.add(MdInline(text.substring(i + 2, end), MdInlineStyle.strike));
        i = end + 2;
        continue;
      }
    }

    if (char == '[') {
      final close = text.indexOf(']', i + 1);
      if (close > i + 1 && close + 1 < text.length && text[close + 1] == '(') {
        final end = text.indexOf(')', close + 2);
        if (end > close + 2) {
          flush();
          runs.add(MdInline(
            text.substring(i + 1, close),
            MdInlineStyle.plain,
            link: text.substring(close + 2, end),
          ));
          i = end + 1;
          continue;
        }
      }
    }

    // Italic needs three conditions, not just word boundaries: the opener must
    // sit at a boundary, the character *after* the opener must not be a space,
    // and the character *before* the closer must not be one either. Without the
    // last two, `2 * 3 * 4` renders as "2  3  4".
    if (char == '*' || char == '_') {
      final atStart = i == 0 || _isBoundary(text[i - 1]);
      final opensCleanly = i + 1 < text.length && !_isSpace(text[i + 1]);
      if (atStart && opensCleanly) {
        final end = text.indexOf(char, i + 1);
        if (end > i + 1 && !_isSpace(text[end - 1])) {
          final atEnd = end + 1 >= text.length || _isBoundary(text[end + 1]);
          if (atEnd) {
            flush();
            runs.add(MdInline(text.substring(i + 1, end), MdInlineStyle.italic));
            i = end + 1;
            continue;
          }
        }
      }
    }

    buffer.write(char);
    i++;
  }

  flush();
  return runs;
}

/// True when [source] contains anything worth formatting, so callers can skip
/// the whole pipeline for ordinary prose.
///
/// Erring towards `true` is the safe direction: a false positive only means the
/// parser looks at text that turns out to be plain, while a false negative shows
/// raw markdown to the user.
bool hasMarkdown(String source) =>
    source.contains('**') ||
    source.contains('~~') ||
    source.contains('`') ||
    source.contains('[') ||
    source.contains('##') ||
    RegExp(r'^\s*([-*+]|\d+[.)])\s', multiLine: true).hasMatch(source) ||
    RegExp(r'^\s*>', multiLine: true).hasMatch(source) ||
    RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$', multiLine: true).hasMatch(source) ||
    looksLikeTable(source);

/// True when a line is followed by a delimiter row, i.e. an actual table header.
///
/// Checked separately from [hasMarkdown]'s simple substring tests because a lone
/// pipe is ordinary text, and only the delimiter row makes it a table.
bool looksLikeTable(String source) {
  final lines = source.split('\n');
  for (var index = 0; index + 1 < lines.length; index++) {
    final header = splitTableRow(lines[index]);
    if (header == null) continue;
    final delimiters = splitTableRow(lines[index + 1]);
    final alignments = delimiters == null ? null : tableAlignments(delimiters);
    if (alignments != null && alignments.length == header.length) return true;
  }
  return false;
}
