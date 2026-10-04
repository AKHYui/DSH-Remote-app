/// Tests for the Markdown subset.
///
/// The formatter's contract is narrow on purpose: format what it recognises,
/// pass everything else through untouched. Most of these tests are about the
/// second half of that promise, because silent mangling is the failure mode that
/// matters — a wrong render is harder to notice than a missing one.
library;

import 'package:dsh_remote_app/chat/markdown.dart';
import 'package:flutter_test/flutter_test.dart';

String plainText(List<MdInline> runs) => runs.map((run) => run.text).join();

void main() {
  group('parseMarkdown blocks', () {
    test('reads headings with their level', () {
      final blocks = parseMarkdown('## 结论\n### 细节');
      expect(blocks, hasLength(2));
      expect((blocks[0] as MdHeading).level, 2);
      expect((blocks[0] as MdHeading).text, '结论');
      expect((blocks[1] as MdHeading).level, 3);
    });

    test('reads bullets and their nesting', () {
      final blocks = parseMarkdown('- one\n  - nested\n* two\n1. three');
      expect(blocks.whereType<MdBullet>().map((b) => (b.text, b.depth)).toList(), [
        ('one', 0),
        ('nested', 1),
        ('two', 0),
        ('three', 0),
      ]);
    });

    test('reads a fenced code block without parsing inside it', () {
      final blocks = parseMarkdown('text\n```dart\nfinal a = **b**;\n```\nafter');
      expect(blocks, hasLength(3));
      expect(blocks[0], isA<MdParagraph>());
      final code = blocks[1] as MdCode;
      expect(code.language, 'dart');
      expect(code.text, 'final a = **b**;');
      expect(blocks[2], isA<MdParagraph>());
    });

    test('tolerates an unterminated fence', () {
      final blocks = parseMarkdown('```\nstill code');
      expect(blocks, hasLength(1));
      expect((blocks.single as MdCode).text, 'still code');
    });

    test('blank lines split paragraphs and keep internal newlines', () {
      final blocks = parseMarkdown('line one\nline two\n\nsecond para');
      expect(blocks, hasLength(2));
      expect((blocks[0] as MdParagraph).text, 'line one\nline two');
      expect((blocks[1] as MdParagraph).text, 'second para');
    });

    test('plain prose is one paragraph', () {
      final blocks = parseMarkdown('just a sentence.');
      expect(blocks, hasLength(1));
      expect(blocks.single, isA<MdParagraph>());
    });

    test('an empty message yields no blocks', () {
      expect(parseMarkdown(''), isEmpty);
      expect(parseMarkdown('\n\n'), isEmpty);
    });

    test('a heading-like line inside prose is not a heading without the space', () {
      final blocks = parseMarkdown('#nospace');
      expect(blocks.single, isA<MdParagraph>());
    });
  });

  group('parseInline', () {
    test('reads bold', () {
      final runs = parseInline('a **b** c');
      expect(runs.map((r) => r.text).toList(), ['a ', 'b', ' c']);
      expect(runs[1].style, MdInlineStyle.bold);
    });

    test('reads inline code', () {
      final runs = parseInline('run `pwsh -v` now');
      expect(runs[1].text, 'pwsh -v');
      expect(runs[1].style, MdInlineStyle.code);
    });

    test('reads a link with its url', () {
      final runs = parseInline('see [docs](https://example.com/x) here');
      expect(runs[1].text, 'docs');
      expect(runs[1].link, 'https://example.com/x');
    });

    test('reads italic at word boundaries', () {
      final runs = parseInline('this is *important* stuff');
      expect(runs[1].text, 'important');
      expect(runs[1].style, MdInlineStyle.italic);
    });

    test('leaves arithmetic alone', () {
      // The boundary rule exists for exactly this: `2 * 3 * 4` must not become
      // an italic " 3 ".
      final runs = parseInline('2 * 3 * 4 = 24');
      expect(plainText(runs), '2 * 3 * 4 = 24');
      expect(runs.every((r) => r.style == MdInlineStyle.plain), isTrue);
    });

    test('leaves snake_case identifiers alone', () {
      final runs = parseInline('read ro.build.version.sdk and a_b_c');
      expect(plainText(runs), 'read ro.build.version.sdk and a_b_c');
      expect(runs.every((r) => r.style == MdInlineStyle.plain), isTrue);
    });

    test('an unmatched marker is kept verbatim', () {
      expect(plainText(parseInline('a **b')), 'a **b');
      expect(plainText(parseInline('a `b')), 'a `b');
      expect(plainText(parseInline('a [b](c')), 'a [b](c');
    });

    test('an empty marker pair is kept verbatim', () {
      expect(plainText(parseInline('a ** b')), 'a ** b');
    });

    test('handles several runs in one line', () {
      final runs = parseInline('**bold** then `code` then [x](y)');
      expect(runs.map((r) => r.style).toList(), [
        MdInlineStyle.bold,
        MdInlineStyle.plain,
        MdInlineStyle.code,
        MdInlineStyle.plain,
        MdInlineStyle.plain,
      ]);
      expect(plainText(runs), 'bold then code then x');
    });

    test('never loses characters', () {
      const source = '混合 **粗体**、`代码`、[链接](http://a) 与 *斜体* 以及 2 * 3。';
      final runs = parseInline(source);
      // Removing the markers must reproduce the original.
      final rebuilt = StringBuffer();
      for (final run in runs) {
        switch (run.style) {
          case MdInlineStyle.bold:
            rebuilt.write('**${run.text}**');
          case MdInlineStyle.code:
            rebuilt.write('`${run.text}`');
          case MdInlineStyle.italic:
            rebuilt.write('*${run.text}*');
          case MdInlineStyle.strike:
            rebuilt.write('~~${run.text}~~');
          case MdInlineStyle.plain:
            rebuilt.write(run.link == null ? run.text : '[${run.text}](${run.link})');
        }
      }
      expect(rebuilt.toString(), source);
    });
  });

  group('hasMarkdown', () {
    test('detects the constructs it can render', () {
      expect(hasMarkdown('plain sentence'), isFalse);
      expect(hasMarkdown('a **b**'), isTrue);
      expect(hasMarkdown('a `b`'), isTrue);
      expect(hasMarkdown('## heading'), isTrue);
      expect(hasMarkdown('- bullet'), isTrue);
      expect(hasMarkdown('[x](y)'), isTrue);
      expect(hasMarkdown('a ~~b~~'), isTrue);
      expect(hasMarkdown('> quoted'), isTrue);
      expect(hasMarkdown('---'), isTrue);
      expect(hasMarkdown('1. numbered'), isTrue);
    });

    test('a pipe on its own is not a table', () {
      // The delimiter row is what makes it one, so this must stay on the fast path.
      expect(hasMarkdown('a | b'), isFalse);
      expect(hasMarkdown('ls | grep x'), isFalse);
    });

    test('a real table turns it on', () {
      expect(hasMarkdown('| a | b |\n| --- | --- |'), isTrue);
      expect(hasMarkdown('a | b\n--- | ---'), isTrue);
    });
  });

  group('tables', () {
    test('reads a table with outer pipes', () {
      final blocks = parseMarkdown('| 名字 | 值 |\n| --- | --- |\n| a | 1 |\n| b | 2 |');
      expect(blocks, hasLength(1));
      final table = blocks.single as MdTable;
      expect(table.header, ['名字', '值']);
      expect(table.rows, [
        ['a', '1'],
        ['b', '2'],
      ]);
      expect(table.alignments, [MdAlign.left, MdAlign.left]);
    });

    test('reads a table without outer pipes', () {
      final table = parseMarkdown('a | b\n--- | ---\n1 | 2').single as MdTable;
      expect(table.header, ['a', 'b']);
      expect(table.rows, [
        ['1', '2'],
      ]);
    });

    test('reads per-column alignment from the colons', () {
      final table = parseMarkdown('| a | b | c |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |').single as MdTable;
      expect(table.alignments, [MdAlign.left, MdAlign.center, MdAlign.right]);
    });

    test('pads and truncates ragged rows instead of dropping them', () {
      final table = parseMarkdown('| a | b | c |\n| - | - | - |\n| 1 |\n| 1 | 2 | 3 | 4 |').single as MdTable;
      expect(table.rows, [
        ['1', '', ''],
        ['1', '2', '3'],
      ]);
    });

    test('a pipe in prose is not a table', () {
      final blocks = parseMarkdown('用 ls | grep 过滤\n第二行照旧');
      expect(blocks.single, isA<MdParagraph>());
    });

    test('a mismatched delimiter row is not a table', () {
      // Two header cells, three delimiters: GFM rejects it, so it stays prose.
      final blocks = parseMarkdown('| a | b |\n| --- | --- | --- |');
      expect(blocks, hasLength(1));
      expect(blocks.single, isA<MdParagraph>());
    });

    test('an escaped pipe stays inside its cell', () {
      final table = parseMarkdown('| a | b |\n| - | - |\n| x \\| y | 2 |').single as MdTable;
      expect(table.rows.single, ['x | y', '2']);
    });

    test('a pipe inside a code span does not split the cell', () {
      final table = parseMarkdown('| a | b |\n| - | - |\n| `ls \\| wc` | 2 |').single as MdTable;
      expect(table.rows.single.first, '`ls | wc`');
    });

    test('a table ends at a blank line', () {
      final blocks = parseMarkdown('| a | b |\n| - | - |\n| 1 | 2 |\n\nafter');
      expect(blocks, hasLength(2));
      expect(blocks[0], isA<MdTable>());
      expect((blocks[1] as MdParagraph).text, 'after');
    });

    test('a table ends at a line without pipes', () {
      final blocks = parseMarkdown('| a | b |\n| - | - |\n| 1 | 2 |\nafter');
      expect(blocks, hasLength(2));
      expect((blocks[0] as MdTable).rows, hasLength(1));
      expect((blocks[1] as MdParagraph).text, 'after');
    });

    test('a header-only table is still a table', () {
      final blocks = parseMarkdown('| a | b |\n| - | - |');
      expect(blocks.single, isA<MdTable>());
      expect((blocks.single as MdTable).rows, isEmpty);
    });
  });

  group('rules, quotes, lists and strikethrough', () {
    test('reads a horizontal rule in each spelling', () {
      expect(parseMarkdown('---').single, isA<MdRule>());
      expect(parseMarkdown('***').single, isA<MdRule>());
      expect(parseMarkdown('___').single, isA<MdRule>());
      expect(parseMarkdown('- - -').single, isA<MdRule>());
    });

    test('two dashes are not a rule', () {
      expect(parseMarkdown('--').single, isA<MdParagraph>());
    });

    test('joins consecutive quote lines and stops at the first that is not one', () {
      final blocks = parseMarkdown('> first\n> second\nafter');
      expect(blocks, hasLength(2));
      expect((blocks[0] as MdQuote).text, 'first\nsecond');
      expect((blocks[1] as MdParagraph).text, 'after');
    });

    test('keeps the number of an ordered list and drops a plain bullet marker', () {
      final blocks = parseMarkdown('1. first\n2) second\n- third');
      final bullets = blocks.whereType<MdBullet>().toList();
      expect(bullets.map((b) => b.marker).toList(), ['1.', '2)', null]);
      expect(bullets.map((b) => b.text).toList(), ['first', 'second', 'third']);
    });

    test('reads task list state', () {
      final bullets = parseMarkdown('- [ ] todo\n- [x] done\n- [X] also done').whereType<MdBullet>().toList();
      expect(bullets.map((b) => b.checked).toList(), [false, true, true]);
      expect(bullets.map((b) => b.text).toList(), ['todo', 'done', 'also done']);
    });

    test('a bullet that merely starts with a bracket is not a task', () {
      final bullet = parseMarkdown('- [note] something').whereType<MdBullet>().single;
      expect(bullet.checked, isNull);
      expect(bullet.text, '[note] something');
    });

    test('reads strikethrough', () {
      final runs = parseInline('a ~~gone~~ b');
      expect(runs[1].text, 'gone');
      expect(runs[1].style, MdInlineStyle.strike);
    });

    test('leaves a lone tilde alone', () {
      expect(plainText(parseInline('about ~40 ms')), 'about ~40 ms');
    });
  });
}
