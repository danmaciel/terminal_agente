import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agente/models/domain_models.dart';
import 'package:terminal_agente/services/database_service.dart';

void main() {
  test('DatabaseService initializes in-memory, deduplicates CAS blobs, and stores snapshots & logs', () async {
    final db = DatabaseService();
    await db.init(inMemory: true);

    // 1. Workspace upsert
    final ws = db.upsertWorkspace('/tmp/demo_project', isGitRepo: true);
    expect(ws.name, 'demo_project');
    expect(ws.isGitRepo, isTrue);

    // 2. Content-Addressable Storage (CAS) deduplication
    final hash1 = db.storeBlob('void main() => print("hello");');
    final hash2 = db.storeBlob('void main() => print("hello");');
    expect(hash1, equals(hash2));
    expect(db.getBlobContent(hash1), 'void main() => print("hello");');

    // 3. Baseline storage ("Como Estava")
    db.saveFileBaseline(ws.id, 'lib/main.dart', 'void main() {}');
    expect(db.getFileBaselineContent(ws.id, 'lib/main.dart'), 'void main() {}');

    // 4. Snapshot creation & retrieval
    final snapshot = db.createSnapshot(
      workspaceId: ws.id,
      label: 'Alteração via Agente CLI',
      triggerType: 'watcher',
      changes: [
        TrackedFileChange(
          relativePath: 'lib/main.dart',
          status: FileChangeStatus.modified,
          beforeContent: 'void main() {}',
          afterContent: 'void main() {\n  print("Novo!");\n}',
          addedLines: 2,
          removedLines: 0,
          updatedAt: DateTime.now(),
        ),
      ],
    );
    expect(snapshot.filesCount, 1);

    final files = db.getSnapshotFiles(snapshot.id);
    expect(files.length, 1);
    expect(files.first.relativePath, 'lib/main.dart');
    expect(files.first.beforeContent, 'void main() {}');
    expect(files.first.afterContent, contains('print("Novo!")'));

    // 5. Terminal session, logs & command history
    final session = db.createTerminalSession(
      workspaceId: ws.id,
      title: 'bash #1',
      shellExecutable: '/bin/bash',
    );
    db.appendTerminalLog(session.id, 'dan@linux:~\$ ls -la\n');
    db.recordCommand(session.id, 'claude');

    expect(db.getSessionLogs(session.id).first, contains('ls -la'));
    expect(db.getCommandHistory(ws.id).first, 'claude');

    // 6. Seeded Quick Snippets & Settings
    expect(db.getQuickSnippets(), isNotEmpty);
    expect(db.getSetting('diff_view_mode'), 'split');

    db.dispose();
  });
}
