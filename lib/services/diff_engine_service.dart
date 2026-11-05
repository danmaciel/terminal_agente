import 'package:diff_match_patch/diff_match_patch.dart';

enum DiffLineType {
  unchanged,
  added,
  removed,
}

class InlineDiffSpan {
  final String text;
  final bool isHighlighted;

  const InlineDiffSpan({
    required this.text,
    required this.isHighlighted,
  });
}

class DiffLine {
  final DiffLineType type;
  final int? oldLineNumber;
  final int? newLineNumber;
  final String content;
  final int? hunkId;
  final List<InlineDiffSpan> inlineSpans;

  const DiffLine({
    required this.type,
    this.oldLineNumber,
    this.newLineNumber,
    required this.content,
    this.hunkId,
    this.inlineSpans = const [],
  });
}

class SplitDiffRow {
  final DiffLine? left;
  final DiffLine? right;
  final int? hunkId;
  final bool isHunkHeader;

  const SplitDiffRow({
    this.left,
    this.right,
    this.hunkId,
    this.isHunkHeader = false,
  });
}

class DiffHunk {
  final int id;
  final int oldStartIndex; // 0-based index in oldLines
  final int oldCount;
  final int newStartIndex; // 0-based index in newLines
  final int newCount;
  final List<String> oldLines;
  final List<String> newLines;

  const DiffHunk({
    required this.id,
    required this.oldStartIndex,
    required this.oldCount,
    required this.newStartIndex,
    required this.newCount,
    required this.oldLines,
    required this.newLines,
  });

  String get header =>
      '@@ -${oldStartIndex + 1},$oldCount +${newStartIndex + 1},$newCount @@';
}

class FileDiffResult {
  final List<DiffLine> unifiedLines;
  final List<SplitDiffRow> splitRows;
  final List<DiffHunk> hunks;
  final int addedLines;
  final int removedLines;

  const FileDiffResult({
    required this.unifiedLines,
    required this.splitRows,
    required this.hunks,
    required this.addedLines,
    required this.removedLines,
  });
}

class DiffEngineService {
  final DiffMatchPatch _dmp = DiffMatchPatch();

  FileDiffResult computeDiff(String beforeContent, String afterContent) {
    final oldLines = _splitLines(beforeContent);
    final newLines = _splitLines(afterContent);

    // Line-level LCS / Myers diff
    final ops = _computeLineOperations(oldLines, newLines);

    final unifiedLines = <DiffLine>[];
    final splitRows = <SplitDiffRow>[];
    final hunks = <DiffHunk>[];

    int addedCount = 0;
    int removedCount = 0;
    int hunkIdCounter = 1;

    int i = 0;
    while (i < ops.length) {
      final op = ops[i];
      if (op.type == DiffLineType.unchanged) {
        final line = DiffLine(
          type: DiffLineType.unchanged,
          oldLineNumber: op.oldIndex! + 1,
          newLineNumber: op.newIndex! + 1,
          content: op.text,
        );
        unifiedLines.add(line);
        splitRows.add(SplitDiffRow(left: line, right: line));
        i++;
      } else {
        // Group contiguous removed/added operations into a single DiffHunk
        final hunkId = hunkIdCounter++;
        final removedOps = <_LineOp>[];
        final addedOps = <_LineOp>[];

        final firstOldIdx = op.oldIndex ??
            (i > 0 && ops[i - 1].oldIndex != null ? ops[i - 1].oldIndex! + 1 : 0);
        final firstNewIdx = op.newIndex ??
            (i > 0 && ops[i - 1].newIndex != null ? ops[i - 1].newIndex! + 1 : 0);

        while (i < ops.length && ops[i].type != DiffLineType.unchanged) {
          if (ops[i].type == DiffLineType.removed) {
            removedOps.add(ops[i]);
            removedCount++;
          } else if (ops[i].type == DiffLineType.added) {
            addedOps.add(ops[i]);
            addedCount++;
          }
          i++;
        }

        final hunk = DiffHunk(
          id: hunkId,
          oldStartIndex: removedOps.isNotEmpty ? removedOps.first.oldIndex! : firstOldIdx,
          oldCount: removedOps.length,
          newStartIndex: addedOps.isNotEmpty ? addedOps.first.newIndex! : firstNewIdx,
          newCount: addedOps.length,
          oldLines: removedOps.map((e) => e.text).toList(),
          newLines: addedOps.map((e) => e.text).toList(),
        );
        hunks.add(hunk);

        // Compute intra-line character highlights for paired removed/added lines
        final pairCount = removedOps.length < addedOps.length
            ? removedOps.length
            : addedOps.length;

        final removedDiffLines = <DiffLine>[];
        final addedDiffLines = <DiffLine>[];

        for (int r = 0; r < removedOps.length; r++) {
          List<InlineDiffSpan> spans = const [];
          if (r < pairCount) {
            spans = _computeInlineSpans(
              removedOps[r].text,
              addedOps[r].text,
              isOldSide: true,
            );
          }
          removedDiffLines.add(
            DiffLine(
              type: DiffLineType.removed,
              oldLineNumber: removedOps[r].oldIndex! + 1,
              content: removedOps[r].text,
              hunkId: hunkId,
              inlineSpans: spans,
            ),
          );
        }

        for (int a = 0; a < addedOps.length; a++) {
          List<InlineDiffSpan> spans = const [];
          if (a < pairCount) {
            spans = _computeInlineSpans(
              removedOps[a].text,
              addedOps[a].text,
              isOldSide: false,
            );
          }
          addedDiffLines.add(
            DiffLine(
              type: DiffLineType.added,
              newLineNumber: addedOps[a].newIndex! + 1,
              content: addedOps[a].text,
              hunkId: hunkId,
              inlineSpans: spans,
            ),
          );
        }

        unifiedLines.addAll(removedDiffLines);
        unifiedLines.addAll(addedDiffLines);

        final maxRows = removedDiffLines.length > addedDiffLines.length
            ? removedDiffLines.length
            : addedDiffLines.length;
        for (int rowIdx = 0; rowIdx < maxRows; rowIdx++) {
          splitRows.add(
            SplitDiffRow(
              left: rowIdx < removedDiffLines.length ? removedDiffLines[rowIdx] : null,
              right: rowIdx < addedDiffLines.length ? addedDiffLines[rowIdx] : null,
              hunkId: hunkId,
              isHunkHeader: rowIdx == 0,
            ),
          );
        }
      }
    }

    return FileDiffResult(
      unifiedLines: unifiedLines,
      splitRows: splitRows,
      hunks: hunks,
      addedLines: addedCount,
      removedLines: removedCount,
    );
  }

  /// Reverts a single [DiffHunk] in [afterContent], restoring only that block
  /// to its state in [beforeContent].
  String revertHunk(String afterContent, DiffHunk hunk) {
    final currentLines = _splitLines(afterContent);
    final start = hunk.newStartIndex.clamp(0, currentLines.length);
    final end = (hunk.newStartIndex + hunk.newCount).clamp(start, currentLines.length);

    final updatedLines = <String>[
      ...currentLines.sublist(0, start),
      ...hunk.oldLines,
      ...currentLines.sublist(end),
    ];

    final hadTrailingNewline = afterContent.endsWith('\n');
    final joined = updatedLines.join('\n');
    if (hadTrailingNewline && updatedLines.isNotEmpty && !joined.endsWith('\n')) {
      return '$joined\n';
    }
    return joined;
  }

  /// Replaces a single [DiffHunk] in [afterContent] with custom edited lines.
  String replaceHunkContent(
    String afterContent,
    DiffHunk hunk,
    String replacementBlockText,
  ) {
    final currentLines = _splitLines(afterContent);
    final replacementLines = _splitLines(replacementBlockText);
    final start = hunk.newStartIndex.clamp(0, currentLines.length);
    final end = (hunk.newStartIndex + hunk.newCount).clamp(start, currentLines.length);

    final updatedLines = <String>[
      ...currentLines.sublist(0, start),
      ...replacementLines,
      ...currentLines.sublist(end),
    ];

    final hadTrailingNewline = afterContent.endsWith('\n');
    final joined = updatedLines.join('\n');
    if (hadTrailingNewline && updatedLines.isNotEmpty && !joined.endsWith('\n')) {
      return '$joined\n';
    }
    return joined;
  }

  List<InlineDiffSpan> _computeInlineSpans(
    String oldLine,
    String newLine, {
    required bool isOldSide,
  }) {
    final diffs = _dmp.diff(oldLine, newLine);
    _dmp.diffCleanupSemantic(diffs);

    final spans = <InlineDiffSpan>[];
    for (final d in diffs) {
      if (d.operation == DIFF_EQUAL) {
        spans.add(InlineDiffSpan(text: d.text, isHighlighted: false));
      } else if (isOldSide && d.operation == DIFF_DELETE) {
        spans.add(InlineDiffSpan(text: d.text, isHighlighted: true));
      } else if (!isOldSide && d.operation == DIFF_INSERT) {
        spans.add(InlineDiffSpan(text: d.text, isHighlighted: true));
      }
    }
    return spans;
  }

  List<String> _splitLines(String text) {
    if (text.isEmpty) return <String>[];
    final normalized = text.replaceAll('\r\n', '\n');
    final lines = normalized.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty && normalized.endsWith('\n')) {
      lines.removeLast();
    }
    return lines;
  }

  List<_LineOp> _computeLineOperations(List<String> oldLines, List<String> newLines) {
    // Encode lines to unique characters so diff_match_patch operates at line granularity
    final lineToChar = <String, int>{};
    final charToLine = <String>[];

    String encodeLines(List<String> lines) {
      final buffer = StringBuffer();
      for (final line in lines) {
        final code = lineToChar.putIfAbsent(line, () {
          final index = charToLine.length;
          charToLine.add(line);
          return index + 0xE000; // Private Use Area offset
        });
        buffer.writeCharCode(code);
      }
      return buffer.toString();
    }

    final encodedOld = encodeLines(oldLines);
    final encodedNew = encodeLines(newLines);

    final diffs = _dmp.diff(encodedOld, encodedNew, false);

    final ops = <_LineOp>[];
    int oldIdx = 0;
    int newIdx = 0;

    for (final d in diffs) {
      for (final rune in d.text.runes) {
        final lineText = charToLine[rune - 0xE000];
        if (d.operation == DIFF_EQUAL) {
          ops.add(_LineOp(
            type: DiffLineType.unchanged,
            text: lineText,
            oldIndex: oldIdx++,
            newIndex: newIdx++,
          ));
        } else if (d.operation == DIFF_DELETE) {
          ops.add(_LineOp(
            type: DiffLineType.removed,
            text: lineText,
            oldIndex: oldIdx++,
          ));
        } else if (d.operation == DIFF_INSERT) {
          ops.add(_LineOp(
            type: DiffLineType.added,
            text: lineText,
            newIndex: newIdx++,
          ));
        }
      }
    }

    return ops;
  }
}

class _LineOp {
  final DiffLineType type;
  final String text;
  final int? oldIndex;
  final int? newIndex;

  const _LineOp({
    required this.type,
    required this.text,
    this.oldIndex,
    this.newIndex,
  });
}
