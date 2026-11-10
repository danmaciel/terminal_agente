import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agente/models/domain_models.dart';
import 'package:terminal_agente/services/database_service.dart';

void main() {
  test('DatabaseService initializes in-memory, deduplicates CAS blobs, and stores snapshots & logs', () async {
    final db = DatabaseService(recordTerminalHistory: true);
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
  test('Terminal history stays disabled by default while sessions still work', () async {
    final db = DatabaseService();
    await db.init(inMemory: true);
    try {
      final ws = db.upsertWorkspace('/tmp/private_terminal', isGitRepo: false);
      final session = db.createTerminalSession(
        workspaceId: ws.id,
        title: 'private',
        shellExecutable: '/bin/sh',
      );

      db.recordCommand(session.id, 'export DEMO_SECRET=example');
      db.appendTerminalLog(session.id, 'DEMO_SECRET=example\\n');

      expect(db.getCommandHistory(ws.id), isEmpty);
      expect(db.getSessionLogs(session.id), isEmpty);

      // This does not delete existing history already stored on disk.
      // Explicit opt-in is covered by the storage test above.
    } finally {
      db.dispose();
    }
  });

  test('Clearing terminal history affects only the selected workspace', () async {
    final db = DatabaseService(recordTerminalHistory: true);
    await db.init(inMemory: true);
    try {
      final first = db.upsertWorkspace('/tmp/history_one', isGitRepo: false);
      final second = db.upsertWorkspace('/tmp/history_two', isGitRepo: false);
      final firstSession = db.createTerminalSession(
        workspaceId: first.id,
        title: 'first',
        shellExecutable: '/bin/sh',
      );
      final secondSession = db.createTerminalSession(
        workspaceId: second.id,
        title: 'second',
        shellExecutable: '/bin/sh',
      );

      db.recordCommand(firstSession.id, 'echo first');
      db.appendTerminalLog(firstSession.id, 'first output');
      db.recordCommand(secondSession.id, 'echo second');
      db.appendTerminalLog(secondSession.id, 'second output');

      db.saveFileBaseline(first.id, 'config.txt', 'keep baseline');
      final snapshot = db.createSnapshot(
        workspaceId: first.id,
        label: 'keep snapshot',
        triggerType: 'manual',
        changes: [
          TrackedFileChange(
            relativePath: 'config.txt',
            status: FileChangeStatus.modified,
            beforeContent: 'old',
            afterContent: 'new',
            addedLines: 1,
            removedLines: 1,
            updatedAt: DateTime.now(),
          ),
        ],
      );

      db.clearTerminalHistoryForWorkspace(first.id);

      expect(db.getCommandHistory(first.id), isEmpty);
      expect(db.getSessionLogs(firstSession.id), isEmpty);
      expect(db.getCommandHistory(second.id), ['echo second']);
      expect(db.getSessionLogs(secondSession.id), ['second output']);
      expect(db.getFileBaselineContent(first.id, 'config.txt'), 'keep baseline');
      expect(db.getSnapshotFiles(snapshot.id), hasLength(1));

      // Clearing again is safe and does not affect the other workspace.
      db.clearTerminalHistoryForWorkspace(first.id);
      expect(db.getCommandHistory(second.id), ['echo second']);
      expect(db.getSessionLogs(secondSession.id), ['second output']);
    } finally {
      db.dispose();
    }
  });

  test('Storage statistics are read-only and report UTF-8 payload bytes', () async {
    final db = DatabaseService(recordTerminalHistory: true);
    await db.init(inMemory: true);
    try {
      final empty = db.getStorageStatistics();
      expect(empty['snapshots'], 0);
      expect(empty['contentBlobBytes'], 0);
      expect(empty['terminalLogBytes'], 0);
      expect(empty['commandBytes'], 0);

      final ws = db.upsertWorkspace('/tmp/storage_stats', isGitRepo: false);
      db.saveFileBaseline(ws.id, 'test.txt', 'olá');
      final session = db.createTerminalSession(
        workspaceId: ws.id,
        title: 'shell',
        shellExecutable: '/bin/sh',
      );
      db.appendTerminalLog(session.id, 'ação');
      db.recordCommand(session.id, 'echo oi');

      final before = db.getStorageStatistics();
      expect(before['workspaces'], 1);
      expect(before['fileBaselines'], 1);
      expect(before['contentBlobs'], 1);
      expect(before['contentBlobBytes'], 4);
      expect(before['terminalSessions'], 1);
      expect(before['terminalLogs'], 1);
      expect(before['terminalLogBytes'], 5);
      expect(before['commands'], 1);
      expect(before['commandBytes'], 7);

      final after = db.getStorageStatistics();
      expect(after, before);
      expect(db.getFileBaselineContent(ws.id, 'test.txt'), 'olá');
      expect(db.getCommandHistory(ws.id), ['echo oi']);
    } finally {
      db.dispose();
    }
  });

  test('Pruning removes only content blobs not used by any workspace', () async {
    final db = DatabaseService();
    await db.init(inMemory: true);
    try {
      final first = db.upsertWorkspace('/tmp/cleanup_first', isGitRepo: false);
      final second = db.upsertWorkspace('/tmp/cleanup_second', isGitRepo: false);

      final unusedHash = db.storeBlob('temporary unreferenced secret');
      final sharedHash = db.storeBlob('shared baseline');
      final snapshotHash = db.storeBlob('snapshot retained');

      db.saveFileBaseline(first.id, 'shared.txt', 'shared baseline');
      db.saveFileBaseline(second.id, 'shared.txt', 'shared baseline');

      final snapshot = db.createSnapshot(
        workspaceId: first.id,
        label: 'keep snapshot',
        triggerType: 'manual',
        changes: [
          TrackedFileChange(
            relativePath: 'file.txt',
            status: FileChangeStatus.modified,
            beforeContent: 'snapshot retained',
            afterContent: 'snapshot updated',
            addedLines: 1,
            removedLines: 1,
            updatedAt: DateTime.now(),
          ),
        ],
      );
      expect(db.getBlobContent(unusedHash), isNotEmpty);
      expect(db.pruneUnreferencedContentBlobs(), 1);
      expect(db.getBlobContent(unusedHash), isEmpty);
      expect(db.getBlobContent(sharedHash), 'shared baseline');
      expect(db.getBlobContent(snapshotHash), 'snapshot retained');
      expect(db.getSnapshotFiles(snapshot.id), hasLength(1));

      db.removeFileBaseline(first.id, 'shared.txt');
      expect(db.pruneUnreferencedContentBlobs(), 0);
      expect(db.getFileBaselineContent(second.id, 'shared.txt'), 'shared baseline');

      db.removeFileBaseline(second.id, 'shared.txt');
      expect(db.pruneUnreferencedContentBlobs(), 1);
      expect(db.getBlobContent(sharedHash), isEmpty);
      expect(db.getSnapshotFiles(snapshot.id).first.beforeContent, 'snapshot retained');
      expect(db.pruneUnreferencedContentBlobs(), 0);
    } finally {
      db.dispose();
    }
  });

}
