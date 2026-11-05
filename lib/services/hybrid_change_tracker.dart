import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';
import '../models/domain_models.dart';
import 'database_service.dart';
import 'diff_engine_service.dart';

class HybridChangeTracker {
  final DatabaseService databaseService;
  final DiffEngineService diffEngine;
  final bool enableWatcherAndGitCli;

  DatabaseService get _db => databaseService;
  DiffEngineService get _diffEngine => diffEngine;

  WorkspaceModel? _activeWorkspace;
  StreamSubscription<WatchEvent>? _watcherSub;
  Timer? _debounceTimer;
  bool _isScanning = false;
  bool _suppressWatcherEvents = false;
  String _lastSnapshotSignature = '';

  final StreamController<List<TrackedFileChange>> _changesController =
      StreamController<List<TrackedFileChange>>.broadcast();
  final StreamController<List<SnapshotModel>> _snapshotsController =
      StreamController<List<SnapshotModel>>.broadcast();

  List<TrackedFileChange> _currentChanges = const [];

  static const Set<String> _ignoredSegments = {
    '.git',
    '.dart_tool',
    'build',
    'node_modules',
    '.idea',
    '.vscode',
    '.gradle',
    'target',
    '__pycache__',
    '.venv',
    'venv',
    'Pods',
  };

  static const Set<String> _ignoredExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.ico',
    '.pdf',
    '.zip',
    '.tar',
    '.gz',
    '.7z',
    '.so',
    '.dll',
    '.dylib',
    '.exe',
    '.bin',
    '.o',
    '.a',
    '.jar',
    '.class',
    '.sqlite',
    '.sqlite-wal',
    '.sqlite-shm',
    '.db',
    '.appimage',
    '.ttf',
    '.otf',
    '.woff',
    '.woff2',
  };

  HybridChangeTracker({
    required this.databaseService,
    required this.diffEngine,
    this.enableWatcherAndGitCli = true,
  });

  WorkspaceModel? get activeWorkspace => _activeWorkspace;
  List<TrackedFileChange> get currentChanges => _currentChanges;
  Stream<List<TrackedFileChange>> get changesStream => _changesController.stream;
  Stream<List<SnapshotModel>> get snapshotsStream => _snapshotsController.stream;

  Future<WorkspaceModel> openWorkspace(String directoryPath) async {
    await _stopWatcher();

    final dir = Directory(directoryPath).absolute;
    if (!dir.existsSync()) {
      throw ArgumentError('O diretório informado não existe: ${dir.path}');
    }

    final isGit = await _detectGitRepository(dir.path);
    final workspace = _db.upsertWorkspace(dir.path, isGitRepo: isGit);
    _activeWorkspace = workspace;
    _lastSnapshotSignature = '';

    await _captureInitialBaselineIfNeeded(workspace);
    await refreshChanges(recordAutoSnapshot: false, customSnapshotLabel: null);
    _emitTimeline();

    if (enableWatcherAndGitCli) {
      _startWatcher(dir.path);
    }
    return workspace;
  }

  Future<bool> _detectGitRepository(String rootPath) async {
    final gitEntity = FileSystemEntity.typeSync(p.join(rootPath, '.git'));
    if (gitEntity != FileSystemEntityType.notFound) {
      return true;
    }
    if (!enableWatcherAndGitCli) {
      return false;
    }
    try {
      final res = await Process.run(
        'git',
        ['rev-parse', '--is-inside-work-tree'],
        workingDirectory: rootPath,
      );
      return res.exitCode == 0 && res.stdout.toString().trim() == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> _captureInitialBaselineIfNeeded(WorkspaceModel workspace) async {
    final existingBaselines = _db.getAllBaselineContents(workspace.id);
    final filesOnDisk = _scanWorkspaceTextFilesSync(workspace.rootPath);

    for (final entry in filesOnDisk.entries) {
      final relPath = entry.key;
      final diskContent = entry.value;

      if (workspace.isGitRepo && enableWatcherAndGitCli) {
        final gitHeadContent = await _getGitHeadFileContent(workspace.rootPath, relPath);
        if (gitHeadContent != null) {
          _db.saveFileBaseline(workspace.id, relPath, gitHeadContent);
          continue;
        }
      }

      if (!existingBaselines.containsKey(relPath)) {
        _db.saveFileBaseline(workspace.id, relPath, diskContent);
      }
    }
  }

  Future<String?> _getGitHeadFileContent(String rootPath, String relativePath) async {
    try {
      final normalizedRel = relativePath.replaceAll('\\', '/');
      final result = await Process.run(
        'git',
        ['show', 'HEAD:$normalizedRel'],
        workingDirectory: rootPath,
      );
      if (result.exitCode == 0) {
        return result.stdout.toString();
      }
    } catch (_) {
      // Git binary missing or file is untracked in HEAD
    }
    return null;
  }

  void _startWatcher(String rootPath) {
    final watcher = DirectoryWatcher(rootPath);
    _watcherSub = watcher.events.listen(
      (event) {
        if (_suppressWatcherEvents) return;
        final relPath = p.relative(event.path, from: rootPath);
        if (_shouldIgnorePath(relPath)) return;

        _debounceTimer?.cancel();
        _debounceTimer = Timer(const Duration(milliseconds: 350), () {
          refreshChanges(recordAutoSnapshot: true);
        });
      },
      onError: (_) {
        // Ignore transient OS watcher errors on temporary swap files
      },
    );
  }

  Future<void> _stopWatcher() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _watcherSub?.cancel();
    _watcherSub = null;
  }

  Future<List<TrackedFileChange>> refreshChanges({
    bool recordAutoSnapshot = false,
    String? customSnapshotLabel,
  }) async {
    final workspace = _activeWorkspace;
    if (workspace == null || _isScanning) return _currentChanges;

    _isScanning = true;
    try {
      final baselines = _db.getAllBaselineContents(workspace.id);
      final currentDiskFiles = _scanWorkspaceTextFilesSync(workspace.rootPath);

      Set<String>? gitUntracked;
      if (workspace.isGitRepo && enableWatcherAndGitCli) {
        gitUntracked = await _getGitUntrackedFiles(workspace.rootPath);
      }

      final allPaths = <String>{
        ...baselines.keys,
        ...currentDiskFiles.keys,
      }.toList()
        ..sort();

      final detectedChanges = <TrackedFileChange>[];

      for (final relPath in allPaths) {
        final hasBaseline = baselines.containsKey(relPath);
        final hasCurrent = currentDiskFiles.containsKey(relPath);

        if (hasBaseline && hasCurrent) {
          final before = baselines[relPath]!;
          final after = currentDiskFiles[relPath]!;

          if (before != after) {
            final diff = _diffEngine.computeDiff(before, after);
            final isUntracked = gitUntracked?.contains(relPath) ?? false;
            detectedChanges.add(
              TrackedFileChange(
                relativePath: relPath,
                status: isUntracked
                    ? FileChangeStatus.untracked
                    : FileChangeStatus.modified,
                beforeContent: before,
                afterContent: after,
                beforeHash: _db.computeSha256(before),
                afterHash: _db.computeSha256(after),
                addedLines: diff.addedLines,
                removedLines: diff.removedLines,
                updatedAt: DateTime.now(),
              ),
            );
          }
        } else if (!hasBaseline && hasCurrent) {
          final after = currentDiskFiles[relPath]!;
          final diff = _diffEngine.computeDiff('', after);
          final isUntracked = gitUntracked?.contains(relPath) ?? false;
          detectedChanges.add(
            TrackedFileChange(
              relativePath: relPath,
              status: isUntracked
                  ? FileChangeStatus.untracked
                  : FileChangeStatus.added,
              beforeContent: '',
              afterContent: after,
              beforeHash: _db.computeSha256(''),
              afterHash: _db.computeSha256(after),
              addedLines: diff.addedLines,
              removedLines: 0,
              updatedAt: DateTime.now(),
            ),
          );
        } else if (hasBaseline && !hasCurrent) {
          final before = baselines[relPath]!;
          final diff = _diffEngine.computeDiff(before, '');
          detectedChanges.add(
            TrackedFileChange(
              relativePath: relPath,
              status: FileChangeStatus.deleted,
              beforeContent: before,
              afterContent: '',
              beforeHash: _db.computeSha256(before),
              afterHash: _db.computeSha256(''),
              addedLines: 0,
              removedLines: diff.removedLines,
              updatedAt: DateTime.now(),
            ),
          );
        }
      }

      _currentChanges = detectedChanges;
      _changesController.add(detectedChanges);

      if (detectedChanges.isNotEmpty &&
          (recordAutoSnapshot || customSnapshotLabel != null)) {
        final signature = detectedChanges
            .map((c) => '${c.relativePath}:${c.afterHash}')
            .join('|');
        if (customSnapshotLabel != null || signature != _lastSnapshotSignature) {
          _lastSnapshotSignature = signature;
          _db.createSnapshot(
            workspaceId: workspace.id,
            label: customSnapshotLabel ??
                'Auto-Snapshot (${detectedChanges.length} arq.)',
            triggerType: customSnapshotLabel != null ? 'manual' : 'watcher',
            changes: detectedChanges,
          );
          _emitTimeline();
        }
      }

      return detectedChanges;
    } finally {
      _isScanning = false;
    }
  }

  /// Creates an explicit manual checkpoint on the Timeline.
  Future<SnapshotModel?> createManualCheckpoint(String label) async {
    final workspace = _activeWorkspace;
    if (workspace == null) return null;

    await refreshChanges(recordAutoSnapshot: false);
    final snap = _db.createSnapshot(
      workspaceId: workspace.id,
      label: label,
      triggerType: 'manual',
      changes: _currentChanges,
    );
    _emitTimeline();
    return snap;
  }

  /// Accepts all current files on disk as the new baseline ("como estava").
  Future<void> acceptAllAsNewBaseline() async {
    final workspace = _activeWorkspace;
    if (workspace == null) return;

    final filesOnDisk = _scanWorkspaceTextFilesSync(workspace.rootPath);
    final existingBaselines = _db.getAllBaselineContents(workspace.id);

    for (final oldPath in existingBaselines.keys) {
      if (!filesOnDisk.containsKey(oldPath)) {
        _db.removeFileBaseline(workspace.id, oldPath);
      }
    }
    for (final entry in filesOnDisk.entries) {
      _db.saveFileBaseline(workspace.id, entry.key, entry.value);
    }

    await refreshChanges(recordAutoSnapshot: false);
  }

  // ---------------------------------------------------------------------------
  // Granular Rollback: By File, By Hunk, or By Timeline Snapshot
  // ---------------------------------------------------------------------------

  /// Reverts an entire file back to its baseline ("como estava").
  Future<void> revertFile(String relativePath) async {
    final workspace = _activeWorkspace;
    if (workspace == null) return;

    final change = _currentChanges
        .where((c) => c.relativePath == relativePath)
        .firstOrNull;
    if (change == null) return;

    final targetFile = File(p.join(workspace.rootPath, relativePath));
    _suppressWatcherEvents = true;
    try {
      if (change.status == FileChangeStatus.added ||
          (change.status == FileChangeStatus.untracked &&
              change.beforeContent.isEmpty)) {
        if (targetFile.existsSync()) {
          targetFile.deleteSync();
        }
      } else {
        targetFile.parent.createSync(recursive: true);
        targetFile.writeAsStringSync(change.beforeContent);
      }
    } finally {
      _suppressWatcherEvents = false;
    }

    await refreshChanges(
      recordAutoSnapshot: true,
      customSnapshotLabel: 'Rollback de arquivo: $relativePath',
    );
  }

  /// Reverts only a single [DiffHunk] inside [relativePath].
  Future<void> revertHunkInFile(String relativePath, DiffHunk hunk) async {
    final workspace = _activeWorkspace;
    if (workspace == null) return;

    final change = _currentChanges
        .where((c) => c.relativePath == relativePath)
        .firstOrNull;
    if (change == null) return;

    final patchedContent = _diffEngine.revertHunk(change.afterContent, hunk);
    final targetFile = File(p.join(workspace.rootPath, relativePath));

    _suppressWatcherEvents = true;
    try {
      targetFile.parent.createSync(recursive: true);
      targetFile.writeAsStringSync(patchedContent);
    } finally {
      _suppressWatcherEvents = false;
    }

    await refreshChanges(
      recordAutoSnapshot: true,
      customSnapshotLabel: 'Rollback de bloco (${hunk.header}) em $relativePath',
    );
  }

  /// Saves manual edits made to [relativePath] in the integrated editor.
  Future<void> saveEditedFile(
    String relativePath,
    String updatedContent, {
    String? customSnapshotLabel,
  }) async {
    final workspace = _activeWorkspace;
    if (workspace == null) return;

    final targetFile = File(p.join(workspace.rootPath, relativePath));
    _suppressWatcherEvents = true;
    try {
      targetFile.parent.createSync(recursive: true);
      targetFile.writeAsStringSync(updatedContent);
    } finally {
      _suppressWatcherEvents = false;
    }

    await refreshChanges(
      recordAutoSnapshot: true,
      customSnapshotLabel:
          customSnapshotLabel ?? 'Edição manual salva em $relativePath',
    );
  }

  /// Replaces only a single [DiffHunk] inside [relativePath] with custom edited text.
  Future<void> editHunkInFile(
    String relativePath,
    DiffHunk hunk,
    String replacementBlockText,
  ) async {
    final workspace = _activeWorkspace;
    if (workspace == null) return;

    final change = _currentChanges
        .where((c) => c.relativePath == relativePath)
        .firstOrNull;
    if (change == null) return;

    final patchedContent = _diffEngine.replaceHunkContent(
      change.afterContent,
      hunk,
      replacementBlockText,
    );
    await saveEditedFile(
      relativePath,
      patchedContent,
      customSnapshotLabel:
          'Edição manual do bloco #${hunk.id} (${hunk.header}) em $relativePath',
    );
  }

  /// Restores all files recorded in a specific Timeline [snapshotId].
  Future<void> restoreSnapshot(
    int snapshotId, {
    bool restoreBeforeState = false,
  }) async {
    final workspace = _activeWorkspace;
    if (workspace == null) return;

    final entries = _db.getSnapshotFiles(snapshotId);
    _suppressWatcherEvents = true;
    try {
      for (final entry in entries) {
        final targetFile = File(p.join(workspace.rootPath, entry.relativePath));
        final contentToWrite =
            restoreBeforeState ? entry.beforeContent : entry.afterContent;

        if (!restoreBeforeState && entry.status == FileChangeStatus.deleted) {
          if (targetFile.existsSync()) {
            targetFile.deleteSync();
          }
        } else if (restoreBeforeState &&
            (entry.status == FileChangeStatus.added ||
                entry.status == FileChangeStatus.untracked) &&
            entry.beforeContent.isEmpty) {
          if (targetFile.existsSync()) {
            targetFile.deleteSync();
          }
        } else {
          targetFile.parent.createSync(recursive: true);
          targetFile.writeAsStringSync(contentToWrite);
        }
      }
    } finally {
      _suppressWatcherEvents = false;
    }

    await refreshChanges(
      recordAutoSnapshot: true,
      customSnapshotLabel: 'Restaurado Snapshot #$snapshotId',
    );
  }

  void _emitTimeline() {
    final workspace = _activeWorkspace;
    if (workspace == null) return;
    final list = _db.getSnapshotsForWorkspace(workspace.id);
    _snapshotsController.add(list);
  }

  Future<Set<String>> _getGitUntrackedFiles(String rootPath) async {
    final untracked = <String>{};
    try {
      final res = await Process.run(
        'git',
        ['ls-files', '--others', '--exclude-standard'],
        workingDirectory: rootPath,
      );
      if (res.exitCode == 0) {
        final lines = res.stdout.toString().split('\n');
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            untracked.add(p.normalize(trimmed));
          }
        }
      }
    } catch (_) {}
    return untracked;
  }

  Map<String, String> _scanWorkspaceTextFilesSync(String rootPath) {
    final result = <String, String>{};
    final rootDir = Directory(rootPath);
    if (!rootDir.existsSync()) return result;

    try {
      final entities = rootDir.listSync(recursive: true, followLinks: false);
      for (final entity in entities) {
        if (entity is! File) continue;
        final relPath = p.relative(entity.path, from: rootPath);
        if (_shouldIgnorePath(relPath)) continue;

        try {
          final stat = entity.statSync();
          // Skip files larger than 512 KB to keep UI & diff engine snappy
          if (stat.size > 512 * 1024) continue;

          final bytes = entity.readAsBytesSync();
          final sampleLen = bytes.length < 1024 ? bytes.length : 1024;
          bool isBinary = false;
          for (int i = 0; i < sampleLen; i++) {
            if (bytes[i] == 0) {
              isBinary = true;
              break;
            }
          }
          if (isBinary) continue;

          final content = utf8.decode(bytes, allowMalformed: true);
          result[relPath] = content;
        } catch (_) {
          // Ignore locked/temporary files
        }
      }
    } catch (_) {}
    return result;
  }

  bool _shouldIgnorePath(String relativePath) {
    final parts = p.split(relativePath);
    for (final part in parts) {
      if (_ignoredSegments.contains(part)) return true;
    }
    final ext = p.extension(relativePath).toLowerCase();
    if (_ignoredExtensions.contains(ext)) return true;
    return false;
  }

  Future<void> dispose() async {
    await _stopWatcher();
    await _changesController.close();
    await _snapshotsController.close();
  }
}
