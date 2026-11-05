import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import '../models/domain_models.dart';

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  final service = DatabaseService();
  ref.onDispose(service.dispose);
  return service;
});

class DatabaseService {
  Database? _db;
  String? _dbPath;

  bool get isInitialized => _db != null;
  String? get databasePath => _dbPath;

  Future<void> init({String? overridePath, bool inMemory = false}) async {
    if (_db != null) return;

    if (inMemory) {
      _dbPath = ':memory:';
      _db = sqlite3.openInMemory();
    } else {
      final String targetPath;
      if (overridePath != null) {
        targetPath = overridePath;
      } else {
        final supportDir = await getApplicationSupportDirectory();
        await supportDir.create(recursive: true);
        targetPath = p.join(supportDir.path, 'terminal_agente.sqlite');
      }
      _dbPath = targetPath;
      _db = sqlite3.open(targetPath);
    }

    _configurePragmas();
    _createSchema();
    _seedDefaultsIfEmpty();
  }

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('DatabaseService has not been initialized. Call init() first.');
    }
    return db;
  }

  void _configurePragmas() {
    _database.execute('PRAGMA foreign_keys = ON;');
    if (_dbPath != ':memory:') {
      _database.execute('PRAGMA journal_mode = WAL;');
    }
  }

  void _createSchema() {
    _database.execute('''
      CREATE TABLE IF NOT EXISTS workspaces (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        root_path TEXT NOT NULL UNIQUE,
        is_git_repo INTEGER NOT NULL DEFAULT 0,
        last_opened_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS content_blobs (
        sha256_hash TEXT PRIMARY KEY,
        content_text TEXT NOT NULL,
        byte_size INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS file_baselines (
        workspace_id INTEGER NOT NULL,
        relative_path TEXT NOT NULL,
        baseline_hash TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (workspace_id, relative_path),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (baseline_hash) REFERENCES content_blobs(sha256_hash)
      );

      CREATE TABLE IF NOT EXISTS snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id INTEGER NOT NULL,
        label TEXT NOT NULL,
        trigger_type TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS snapshot_files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        snapshot_id INTEGER NOT NULL,
        relative_path TEXT NOT NULL,
        change_status TEXT NOT NULL,
        before_hash TEXT,
        after_hash TEXT,
        FOREIGN KEY (snapshot_id) REFERENCES snapshots(id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS terminal_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        shell_executable TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS terminal_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        output_chunk TEXT NOT NULL,
        logged_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES terminal_sessions(id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS command_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        command_line TEXT NOT NULL,
        executed_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES terminal_sessions(id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS quick_snippets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        command TEXT NOT NULL,
        category TEXT NOT NULL,
        icon_name TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
  }

  static const List<(String, String, String, String)> _defaultSnippets = [
    ('Antigravity', 'agy', 'agent', 'rocket_launch'),
    ('Codex CLI', 'codex', 'agent', 'memory'),
    ('Claude Code', 'claude', 'agent', 'smart_toy'),
    ('Gemini CLI', 'gemini', 'agent', 'auto_awesome'),
    ('Aider AI', 'aider', 'agent', 'psychology'),
    ('Git Status', 'git status -sb', 'git', 'account_tree'),
    ('Git Diff', 'git diff', 'git', 'compare_arrows'),
    ('Flutter Test', 'flutter test', 'build', 'science'),
  ];

  void _seedDefaultsIfEmpty() {
    final result = _database.select('SELECT COUNT(*) AS cnt FROM quick_snippets;');
    final count = result.first['cnt'] as int;
    if (count == 0) {
      resetDefaultSnippets();
    } else {
      // Ensure newly added default agents (Antigravity / Codex) exist in older DBs
      for (final item in [
        ('Antigravity', 'agy', 'agent', 'rocket_launch'),
        ('Codex CLI', 'codex', 'agent', 'memory'),
      ]) {
        final existing = _database.select(
          'SELECT id FROM quick_snippets WHERE command = ? OR title = ? LIMIT 1;',
          [item.$2, item.$1],
        );
        if (existing.isEmpty) {
          _database.execute(
            'INSERT INTO quick_snippets (title, command, category, icon_name) VALUES (?, ?, ?, ?);',
            [item.$1, item.$2, item.$3, item.$4],
          );
        }
      }
    }

    final settingsResult = _database.select('SELECT COUNT(*) AS cnt FROM app_settings;');
    if ((settingsResult.first['cnt'] as int) == 0) {
      setSetting('diff_view_mode', 'split');
      setSetting('terminal_font_size', '13.0');
      setSetting('auto_snapshot_on_change', 'true');
    }
  }

  void resetDefaultSnippets() {
    _database.execute('DELETE FROM quick_snippets;');
    final stmt = _database.prepare(
      'INSERT INTO quick_snippets (title, command, category, icon_name) VALUES (?, ?, ?, ?);',
    );
    for (final item in _defaultSnippets) {
      stmt.execute([item.$1, item.$2, item.$3, item.$4]);
    }
    stmt.close();
  }

  // ---------------------------------------------------------------------------
  // Content-Addressable Storage (CAS) Blobs
  // ---------------------------------------------------------------------------

  String computeSha256(String content) {
    final bytes = utf8.encode(content);
    return sha256.convert(bytes).toString();
  }

  String storeBlob(String content) {
    final bytes = utf8.encode(content);
    final hash = sha256.convert(bytes).toString();
    _database.execute(
      'INSERT OR IGNORE INTO content_blobs (sha256_hash, content_text, byte_size) VALUES (?, ?, ?);',
      [hash, content, bytes.length],
    );
    return hash;
  }

  String getBlobContent(String? hash) {
    if (hash == null || hash.isEmpty) return '';
    final rows = _database.select(
      'SELECT content_text FROM content_blobs WHERE sha256_hash = ? LIMIT 1;',
      [hash],
    );
    if (rows.isEmpty) return '';
    return rows.first['content_text'] as String;
  }

  // ---------------------------------------------------------------------------
  // Workspaces
  // ---------------------------------------------------------------------------

  WorkspaceModel upsertWorkspace(String rootPath, {required bool isGitRepo}) {
    final normalizedPath = Directory(rootPath).absolute.path;
    final name = p.basename(normalizedPath);
    final nowIso = DateTime.now().toIso8601String();

    _database.execute(
      '''
      INSERT INTO workspaces (name, root_path, is_git_repo, last_opened_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(root_path) DO UPDATE SET
        name = excluded.name,
        is_git_repo = excluded.is_git_repo,
        last_opened_at = excluded.last_opened_at;
      ''',
      [name, normalizedPath, isGitRepo ? 1 : 0, nowIso],
    );

    final rows = _database.select(
      'SELECT * FROM workspaces WHERE root_path = ? LIMIT 1;',
      [normalizedPath],
    );
    return _mapWorkspace(rows.first);
  }

  List<WorkspaceModel> getRecentWorkspaces({int limit = 15}) {
    final rows = _database.select(
      'SELECT * FROM workspaces ORDER BY last_opened_at DESC LIMIT ?;',
      [limit],
    );
    return rows.map(_mapWorkspace).toList();
  }

  WorkspaceModel _mapWorkspace(Row row) {
    return WorkspaceModel(
      id: row['id'] as int,
      name: row['name'] as String,
      rootPath: row['root_path'] as String,
      isGitRepo: (row['is_git_repo'] as int) == 1,
      lastOpenedAt: DateTime.tryParse(row['last_opened_at'] as String) ?? DateTime.now(),
    );
  }

  // ---------------------------------------------------------------------------
  // File Baselines ("Como Estava")
  // ---------------------------------------------------------------------------

  void saveFileBaseline(int workspaceId, String relativePath, String content) {
    final hash = storeBlob(content);
    final nowIso = DateTime.now().toIso8601String();
    _database.execute(
      '''
      INSERT INTO file_baselines (workspace_id, relative_path, baseline_hash, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(workspace_id, relative_path) DO UPDATE SET
        baseline_hash = excluded.baseline_hash,
        updated_at = excluded.updated_at;
      ''',
      [workspaceId, relativePath, hash, nowIso],
    );
  }

  void removeFileBaseline(int workspaceId, String relativePath) {
    _database.execute(
      'DELETE FROM file_baselines WHERE workspace_id = ? AND relative_path = ?;',
      [workspaceId, relativePath],
    );
  }

  String? getFileBaselineContent(int workspaceId, String relativePath) {
    final rows = _database.select(
      '''
      SELECT b.content_text
      FROM file_baselines fb
      JOIN content_blobs b ON b.sha256_hash = fb.baseline_hash
      WHERE fb.workspace_id = ? AND fb.relative_path = ?
      LIMIT 1;
      ''',
      [workspaceId, relativePath],
    );
    if (rows.isEmpty) return null;
    return rows.first['content_text'] as String;
  }

  Map<String, String> getAllBaselineContents(int workspaceId) {
    final rows = _database.select(
      '''
      SELECT fb.relative_path, b.content_text
      FROM file_baselines fb
      JOIN content_blobs b ON b.sha256_hash = fb.baseline_hash
      WHERE fb.workspace_id = ?;
      ''',
      [workspaceId],
    );
    final result = <String, String>{};
    for (final row in rows) {
      result[row['relative_path'] as String] = row['content_text'] as String;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Snapshots & Timeline
  // ---------------------------------------------------------------------------

  SnapshotModel createSnapshot({
    required int workspaceId,
    required String label,
    required String triggerType,
    required List<TrackedFileChange> changes,
  }) {
    final nowIso = DateTime.now().toIso8601String();
    _database.execute(
      'INSERT INTO snapshots (workspace_id, label, trigger_type, created_at) VALUES (?, ?, ?, ?);',
      [workspaceId, label, triggerType, nowIso],
    );
    final snapshotId = _database.lastInsertRowId;

    final stmt = _database.prepare(
      '''
      INSERT INTO snapshot_files (snapshot_id, relative_path, change_status, before_hash, after_hash)
      VALUES (?, ?, ?, ?, ?);
      ''',
    );

    try {
      for (final change in changes) {
        final beforeHash = storeBlob(change.beforeContent);
        final afterHash = storeBlob(change.afterContent);
        stmt.execute([
          snapshotId,
          change.relativePath,
          change.status.name,
          beforeHash,
          afterHash,
        ]);
      }
    } finally {
      stmt.close();
    }

    return SnapshotModel(
      id: snapshotId,
      workspaceId: workspaceId,
      label: label,
      triggerType: triggerType,
      createdAt: DateTime.parse(nowIso),
      filesCount: changes.length,
    );
  }

  List<SnapshotModel> getSnapshotsForWorkspace(int workspaceId, {int limit = 50}) {
    final rows = _database.select(
      '''
      SELECT s.*, COUNT(sf.id) AS files_count
      FROM snapshots s
      LEFT JOIN snapshot_files sf ON sf.snapshot_id = s.id
      WHERE s.workspace_id = ?
      GROUP BY s.id
      ORDER BY s.id DESC
      LIMIT ?;
      ''',
      [workspaceId, limit],
    );

    return rows.map((row) {
      return SnapshotModel(
        id: row['id'] as int,
        workspaceId: row['workspace_id'] as int,
        label: row['label'] as String,
        triggerType: row['trigger_type'] as String,
        createdAt: DateTime.tryParse(row['created_at'] as String) ?? DateTime.now(),
        filesCount: row['files_count'] as int? ?? 0,
      );
    }).toList();
  }

  List<SnapshotFileEntry> getSnapshotFiles(int snapshotId) {
    final rows = _database.select(
      'SELECT * FROM snapshot_files WHERE snapshot_id = ? ORDER BY relative_path ASC;',
      [snapshotId],
    );

    return rows.map((row) {
      final statusName = row['change_status'] as String;
      final status = FileChangeStatus.values.firstWhere(
        (e) => e.name == statusName,
        orElse: () => FileChangeStatus.modified,
      );
      return SnapshotFileEntry(
        id: row['id'] as int,
        snapshotId: row['snapshot_id'] as int,
        relativePath: row['relative_path'] as String,
        status: status,
        beforeContent: getBlobContent(row['before_hash'] as String?),
        afterContent: getBlobContent(row['after_hash'] as String?),
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Terminal Sessions, Logs & Command History
  // ---------------------------------------------------------------------------

  TerminalSessionRecord createTerminalSession({
    required int workspaceId,
    required String title,
    required String shellExecutable,
  }) {
    final nowIso = DateTime.now().toIso8601String();
    _database.execute(
      'INSERT INTO terminal_sessions (workspace_id, title, shell_executable, created_at) VALUES (?, ?, ?, ?);',
      [workspaceId, title, shellExecutable, nowIso],
    );
    final id = _database.lastInsertRowId;
    return TerminalSessionRecord(
      id: id,
      workspaceId: workspaceId,
      title: title,
      shellExecutable: shellExecutable,
      createdAt: DateTime.parse(nowIso),
    );
  }

  void appendTerminalLog(int sessionId, String outputChunk) {
    if (outputChunk.isEmpty) return;
    _database.execute(
      'INSERT INTO terminal_logs (session_id, output_chunk, logged_at) VALUES (?, ?, ?);',
      [sessionId, outputChunk, DateTime.now().toIso8601String()],
    );
  }

  List<String> getSessionLogs(int sessionId, {int limit = 200}) {
    final rows = _database.select(
      'SELECT output_chunk FROM terminal_logs WHERE session_id = ? ORDER BY id ASC LIMIT ?;',
      [sessionId, limit],
    );
    return rows.map((r) => r['output_chunk'] as String).toList();
  }

  void recordCommand(int sessionId, String commandLine) {
    final trimmed = commandLine.trim();
    if (trimmed.isEmpty) return;
    _database.execute(
      'INSERT INTO command_history (session_id, command_line, executed_at) VALUES (?, ?, ?);',
      [sessionId, trimmed, DateTime.now().toIso8601String()],
    );
  }

  List<String> getCommandHistory(int workspaceId, {int limit = 100}) {
    final rows = _database.select(
      '''
      SELECT ch.command_line
      FROM command_history ch
      JOIN terminal_sessions ts ON ts.id = ch.session_id
      WHERE ts.workspace_id = ?
      ORDER BY ch.id DESC
      LIMIT ?;
      ''',
      [workspaceId, limit],
    );
    return rows.map((r) => r['command_line'] as String).toList();
  }

  // ---------------------------------------------------------------------------
  // Quick Snippets & Settings
  // ---------------------------------------------------------------------------

  List<QuickSnippetModel> getQuickSnippets() {
    final rows = _database.select('SELECT * FROM quick_snippets ORDER BY id ASC;');
    return rows.map((row) {
      return QuickSnippetModel(
        id: row['id'] as int,
        title: row['title'] as String,
        command: row['command'] as String,
        category: row['category'] as String,
        iconName: row['icon_name'] as String,
      );
    }).toList();
  }

  QuickSnippetModel addQuickSnippet({
    required String title,
    required String command,
    String category = 'custom',
    String iconName = 'terminal',
  }) {
    _database.execute(
      'INSERT INTO quick_snippets (title, command, category, icon_name) VALUES (?, ?, ?, ?);',
      [title, command, category, iconName],
    );
    final id = _database.lastInsertRowId;
    return QuickSnippetModel(
      id: id,
      title: title,
      command: command,
      category: category,
      iconName: iconName,
    );
  }

  void updateQuickSnippet({
    required int id,
    required String title,
    required String command,
    required String category,
    String iconName = 'terminal',
  }) {
    _database.execute(
      'UPDATE quick_snippets SET title = ?, command = ?, category = ?, icon_name = ? WHERE id = ?;',
      [title, command, category, iconName, id],
    );
  }

  void deleteQuickSnippet(int id) {
    _database.execute('DELETE FROM quick_snippets WHERE id = ?;', [id]);
  }

  String getSetting(String key, {String defaultValue = ''}) {
    final rows = _database.select(
      'SELECT value FROM app_settings WHERE key = ? LIMIT 1;',
      [key],
    );
    if (rows.isEmpty) return defaultValue;
    return rows.first['value'] as String;
  }

  void setSetting(String key, String value) {
    _database.execute(
      '''
      INSERT INTO app_settings (key, value)
      VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value;
      ''',
      [key, value],
    );
  }

  void dispose() {
    _db?.close();
    _db = null;
  }
}
