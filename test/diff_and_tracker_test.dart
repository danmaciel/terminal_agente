import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:terminal_agente/models/domain_models.dart';
import 'package:terminal_agente/services/database_service.dart';
import 'package:terminal_agente/services/diff_engine_service.dart';
import 'package:terminal_agente/services/hybrid_change_tracker.dart';

void main() {
  test('DiffEngineService computes unified/split rows and reverts individual hunk', () {
    final engine = DiffEngineService();

    const before = '''
line 1
line 2 old
line 3
line 4
line 5 old
line 6''';

    const after = '''
line 1
line 2 new
line 3
line 4
line 5 new
line 6''';

    final diff = engine.computeDiff(before, after);
    expect(diff.addedLines, 2);
    expect(diff.removedLines, 2);
    expect(diff.hunks.length, 2);

    // Revert ONLY the first hunk (line 2), keeping the second hunk (line 5 new)
    final patched = engine.revertHunk(after, diff.hunks.first);
    expect(patched, contains('line 2 old'));
    expect(patched, contains('line 5 new'));

    // Replace the second hunk with custom edited text
    final editedHunk = engine.replaceHunkContent(
      after,
      diff.hunks.last,
      'line 5 custom edited',
    );
    expect(editedHunk, contains('line 2 new'));
    expect(editedHunk, contains('line 5 custom edited'));

    // Verify CodeSelectionReference formatting
    const ref = CodeSelectionReference(
      relativePath: 'lib/main.dart',
      startLine: 10,
      endLine: 25,
      selectedText: 'void test() {}',
    );
    expect(ref.referenceToken, '@lib/main.dart#L10-L25');
    expect(
      ref.formatPrompt('Verifique se é possível simplificar'),
      contains('@lib/main.dart#L10-L25'),
    );
  });

  test('HybridChangeTracker tracks changes, creates snapshots, and performs hunk/file rollback', () async {
    final db = DatabaseService();
    await db.init(inMemory: true);
    final diffEngine = DiffEngineService();
    final tracker = HybridChangeTracker(
      databaseService: db,
      diffEngine: diffEngine,
    );

    final tempDir = await Directory.systemTemp.createTemp('terminal_agente_test_');
    try {
      final fileA = File(p.join(tempDir.path, 'app.dart'));
      await fileA.writeAsString('void main() {\n  print("A");\n  print("B");\n}\n');

      // 1. Open workspace and capture baseline
      final ws = await tracker.openWorkspace(tempDir.path);
      expect(ws.rootPath, tempDir.path);
      expect(tracker.currentChanges, isEmpty);

      // 2. Modify existing file and create a new file
      await fileA.writeAsString('void main() {\n  print("A_mod");\n  print("B");\n}\n');
      final fileB = File(p.join(tempDir.path, 'new_helper.dart'));
      await fileB.writeAsString('int sum(int a, int b) => a + b;\n');

      final changes = await tracker.refreshChanges(
        recordAutoSnapshot: true,
        customSnapshotLabel: 'Agente alterou 2 arquivos',
      );
      expect(changes.length, 2);

      final appChange = changes.firstWhere((c) => c.relativePath == 'app.dart');
      expect(appChange.status, FileChangeStatus.modified);
      expect(appChange.addedLines, 1);
      expect(appChange.removedLines, 1);

      // 3. Test Hunk Rollback on app.dart
      final fileDiff = diffEngine.computeDiff(appChange.beforeContent, appChange.afterContent);
      expect(fileDiff.hunks.length, 1);
      await tracker.revertHunkInFile('app.dart', fileDiff.hunks.first);

      expect(await fileA.readAsString(), 'void main() {\n  print("A");\n  print("B");\n}\n');

      // 4. Test File Rollback on newly created file (new_helper.dart should be deleted)
      await tracker.revertFile('new_helper.dart');
      expect(await fileB.exists(), isFalse);
      expect(tracker.currentChanges, isEmpty);

      // 5. Verify snapshots were recorded in SQLite timeline
      final snapshots = db.getSnapshotsForWorkspace(ws.id);
      expect(snapshots, isNotEmpty);
    } finally {
      await tracker.dispose();
      db.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });
}
