import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'core/theme/app_theme.dart';
import 'models/domain_models.dart';
import 'services/database_service.dart';
import 'services/diff_engine_service.dart';
import 'services/hybrid_change_tracker.dart';
import 'services/terminal_session_controller.dart';
import 'widgets/diff_viewer_panel.dart';
import 'widgets/files_and_timeline_panel.dart';
import 'widgets/terminal_panel_widget.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const ProviderScope(
      child: TerminalAgenteApp(),
    ),
  );
}

class TerminalAgenteApp extends StatelessWidget {
  final DatabaseService? overrideDb;
  final bool simulateTerminal;
  final String? initialWorkspacePath;

  const TerminalAgenteApp({
    super.key,
    this.overrideDb,
    this.simulateTerminal = false,
    this.initialWorkspacePath,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Terminal Agente',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: AppShellScaffold(
        overrideDb: overrideDb,
        simulateTerminal: simulateTerminal,
        initialWorkspacePath: initialWorkspacePath,
      ),
    );
  }
}

class AppShellScaffold extends StatefulWidget {
  final DatabaseService? overrideDb;
  final bool simulateTerminal;
  final String? initialWorkspacePath;

  const AppShellScaffold({
    super.key,
    this.overrideDb,
    this.simulateTerminal = false,
    this.initialWorkspacePath,
  });

  @override
  State<AppShellScaffold> createState() => _AppShellScaffoldState();
}

class _AppShellScaffoldState extends State<AppShellScaffold> {
  late final DatabaseService _db;
  late final DiffEngineService _diffEngine;
  late final HybridChangeTracker _changeTracker;
  late final TerminalTabsManager _terminalManager;
  late final MultiSplitViewController _splitController;

  StreamSubscription<List<TrackedFileChange>>? _changesSub;
  StreamSubscription<List<SnapshotModel>>? _snapshotsSub;

  bool _isReady = false;
  WorkspaceModel? _activeWorkspace;
  List<WorkspaceModel> _recentWorkspaces = const [];
  List<TrackedFileChange> _changes = const [];
  List<SnapshotModel> _snapshots = const [];
  List<QuickSnippetModel> _snippets = const [];

  TrackedFileChange? _selectedChange;
  FileDiffResult? _selectedDiff;
  DiffViewMode _diffViewMode = DiffViewMode.split;
  double _fontSize = 13.0;
  String _statusMessage = 'Inicializando SQLite e rastreador...';

  @override
  void initState() {
    super.initState();
    _db = widget.overrideDb ?? DatabaseService();
    _diffEngine = DiffEngineService();
    _changeTracker = HybridChangeTracker(
      databaseService: _db,
      diffEngine: _diffEngine,
      enableWatcherAndGitCli: !widget.simulateTerminal,
    );
    _terminalManager = TerminalTabsManager(
      databaseService: _db,
      simulatePty: widget.simulateTerminal,
      onCommandExecuted: () {
        _changeTracker.refreshChanges(recordAutoSnapshot: true);
        if (mounted) setState(() {});
      },
    );

    _splitController = MultiSplitViewController(
      areas: [
        Area(
          flex: 2,
          min: 1,
          builder: (context, area) => FilesAndTimelinePanel(
            changes: _changes,
            snapshots: _snapshots,
            selectedFilePath: _selectedChange?.relativePath,
            onSelectFile: _selectFileChange,
            onRevertFile: _handleRevertFile,
            onRefresh: () => _changeTracker.refreshChanges(recordAutoSnapshot: false),
            onAcceptAllBaseline: _handleAcceptAllBaseline,
            onCreateManualCheckpoint: _handleCreateCheckpoint,
            onRestoreSnapshot: _handleRestoreSnapshot,
          ),
        ),
        Area(
          flex: 5,
          min: 2,
          builder: (context, area) => DiffViewerPanel(
            selectedChange: _selectedChange,
            diffResult: _selectedDiff,
            viewMode: _diffViewMode,
            fontSize: _fontSize,
            onToggleViewMode: _handleToggleViewMode,
            onRevertFile: _handleRevertFile,
            onRevertHunk: _handleRevertHunk,
            onSaveEditedFile: _handleSaveEditedFile,
            onEditHunk: _handleEditHunk,
            onSendReferenceToTerminal: _handleSendReferenceToTerminal,
          ),
        ),
        Area(
          flex: 4,
          min: 2,
          builder: (context, area) => TerminalPanelWidget(
            tabsManager: _terminalManager,
            snippets: _snippets,
            commandHistory: _activeWorkspace != null
                ? _db.getCommandHistory(_activeWorkspace!.id)
                : const [],
            fontSize: _fontSize,
            onAddSnippet: _handleAddSnippet,
            onUpdateSnippet: _handleUpdateSnippet,
            onDeleteSnippet: _handleDeleteSnippet,
            onResetDefaultSnippets: _handleResetDefaultSnippets,
          ),
        ),
      ],
    );

    _initializeApp();
  }

  Future<void> _initializeApp() async {
    if (!_db.isInitialized) {
      await _db.init();
    }

    final savedMode = _db.getSetting('diff_view_mode', defaultValue: 'split');
    _diffViewMode = switch (savedMode) {
      'unified' => DiffViewMode.unified,
      'editor' => DiffViewMode.editor,
      _ => DiffViewMode.split,
    };
    _fontSize = double.tryParse(
          _db.getSetting('terminal_font_size', defaultValue: '13.0'),
        ) ??
        13.0;
    _snippets = _db.getQuickSnippets();
    _recentWorkspaces = _db.getRecentWorkspaces();

    _changesSub = _changeTracker.changesStream.listen((updatedChanges) {
      if (!mounted) return;
      setState(() {
        _changes = updatedChanges;
        if (_selectedChange != null) {
          final updatedSelected = updatedChanges
              .where((c) => c.relativePath == _selectedChange!.relativePath)
              .firstOrNull;
          if (updatedSelected != null) {
            _selectedChange = updatedSelected;
            _selectedDiff = _diffEngine.computeDiff(
              updatedSelected.beforeContent,
              updatedSelected.afterContent,
            );
          } else {
            _selectedChange = updatedChanges.firstOrNull;
            _selectedDiff = _selectedChange != null
                ? _diffEngine.computeDiff(
                    _selectedChange!.beforeContent,
                    _selectedChange!.afterContent,
                  )
                : null;
          }
        } else if (updatedChanges.isNotEmpty) {
          _selectedChange = updatedChanges.first;
          _selectedDiff = _diffEngine.computeDiff(
            _selectedChange!.beforeContent,
            _selectedChange!.afterContent,
          );
        }
      });
    });

    _snapshotsSub = _changeTracker.snapshotsStream.listen((updatedSnapshots) {
      if (!mounted) return;
      setState(() {
        _snapshots = updatedSnapshots;
      });
    });

    final targetDir = widget.initialWorkspacePath ??
        (_recentWorkspaces.isNotEmpty
            ? _recentWorkspaces.first.rootPath
            : Directory.current.path);

    if (Directory(targetDir).existsSync()) {
      await _openWorkspaceDirectory(targetDir);
    }

    if (mounted) {
      setState(() {
        _isReady = true;
      });
    }
  }

  Future<void> _openWorkspaceDirectory(String path) async {
    try {
      final ws = await _changeTracker.openWorkspace(path);
      _terminalManager.bindWorkspace(
        workspaceId: ws.id,
        workingDirectory: ws.rootPath,
      );
      if (!mounted) return;
      setState(() {
        _activeWorkspace = ws;
        _recentWorkspaces = _db.getRecentWorkspaces();
        _snapshots = _db.getSnapshotsForWorkspace(ws.id);
        _statusMessage =
            'Monitorando ${ws.rootPath} (${ws.isGitRepo ? "Híbrido: Git + SQLite" : "Snapshots SQLite"})';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Erro ao abrir diretório: $e';
      });
    }
  }

  Future<void> _pickWorkspaceFolder() async {
    final selectedDir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Selecione a pasta do Projeto / Workspace',
    );
    if (selectedDir != null && selectedDir.isNotEmpty) {
      await _openWorkspaceDirectory(selectedDir);
    }
  }

  void _selectFileChange(TrackedFileChange change) {
    setState(() {
      _selectedChange = change;
      _selectedDiff = _diffEngine.computeDiff(
        change.beforeContent,
        change.afterContent,
      );
    });
  }

  void _handleToggleViewMode(DiffViewMode mode) {
    setState(() {
      _diffViewMode = mode;
    });
    _db.setSetting('diff_view_mode', mode.name);
  }

  void _adjustFontSize(double delta) {
    final updated = (_fontSize + delta).clamp(10.0, 22.0);
    setState(() {
      _fontSize = updated;
    });
    _db.setSetting('terminal_font_size', updated.toStringAsFixed(1));
  }

  Future<void> _handleRevertFile(String relativePath) async {
    await _changeTracker.revertFile(relativePath);
    if (!mounted) return;
    setState(() {
      _statusMessage = 'Arquivo revertido para o estado anterior: $relativePath';
    });
  }

  Future<void> _handleRevertHunk(String relativePath, DiffHunk hunk) async {
    await _changeTracker.revertHunkInFile(relativePath, hunk);
    if (!mounted) return;
    setState(() {
      _statusMessage =
          'Bloco #${hunk.id} (${hunk.header}) revertido em $relativePath';
    });
  }

  Future<void> _handleSaveEditedFile(
    String relativePath,
    String updatedContent,
  ) async {
    await _changeTracker.saveEditedFile(relativePath, updatedContent);
    if (!mounted) return;
    setState(() {
      _statusMessage =
          'Alterações salvas em $relativePath e Snapshot registrado na Timeline';
    });
  }

  Future<void> _handleEditHunk(
    String relativePath,
    DiffHunk hunk,
    String replacementBlockText,
  ) async {
    await _changeTracker.editHunkInFile(
      relativePath,
      hunk,
      replacementBlockText,
    );
    if (!mounted) return;
    setState(() {
      _statusMessage =
          'Bloco #${hunk.id} (${hunk.header}) editado e salvo em $relativePath';
    });
  }

  void _handleSendReferenceToTerminal(
    String text, {
    required bool execute,
  }) {
    _terminalManager.sendCommandToActiveTab(text, execute: execute);
    if (!mounted) return;
    setState(() {
      _statusMessage = execute
          ? 'Prompt com referência enviado para a aba ativa do terminal'
          : 'Referência inserida no terminal: ${text.trim()}';
    });
  }

  Future<void> _handleAcceptAllBaseline() async {
    await _changeTracker.acceptAllAsNewBaseline();
    if (!mounted) return;
    setState(() {
      _statusMessage =
          'Todos os arquivos atuais foram salvos como novo Baseline no SQLite.';
    });
  }

  Future<void> _handleCreateCheckpoint(String label) async {
    await _changeTracker.createManualCheckpoint(label);
    if (!mounted) return;
    setState(() {
      _statusMessage = 'Checkpoint criado na Timeline: "$label"';
    });
  }

  Future<void> _handleRestoreSnapshot(
    SnapshotModel snapshot,
    bool restoreBeforeState,
  ) async {
    await _changeTracker.restoreSnapshot(
      snapshot.id,
      restoreBeforeState: restoreBeforeState,
    );
    if (!mounted) return;
    setState(() {
      _statusMessage =
          'Timeline restaurada para ${restoreBeforeState ? "ANTES de" : "DEPOIS de"} "${snapshot.label}"';
    });
  }

  void _handleAddSnippet(String title, String command, String category) {
    _db.addQuickSnippet(title: title, command: command, category: category);
    setState(() {
      _snippets = _db.getQuickSnippets();
    });
  }

  void _handleUpdateSnippet(
    int id,
    String title,
    String command,
    String category,
  ) {
    _db.updateQuickSnippet(
      id: id,
      title: title,
      command: command,
      category: category,
    );
    setState(() {
      _snippets = _db.getQuickSnippets();
    });
  }

  void _handleDeleteSnippet(int id) {
    _db.deleteQuickSnippet(id);
    setState(() {
      _snippets = _db.getQuickSnippets();
    });
  }

  void _handleResetDefaultSnippets() {
    _db.resetDefaultSnippets();
    setState(() {
      _snippets = _db.getQuickSnippets();
      _statusMessage = 'Atalhos de agentes padrão restaurados no SQLite.';
    });
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _snapshotsSub?.cancel();
    _changeTracker.dispose();
    _terminalManager.dispose();
    _splitController.dispose();
    if (widget.overrideDb == null) {
      _db.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildTopToolbar(),
          Expanded(
            child: !_isReady
                ? const Center(child: CircularProgressIndicator())
                : MultiSplitViewTheme(
                    data: MultiSplitViewThemeData(
                      dividerThickness: 4,
                      dividerPainter: DividerPainters.background(
                        color: AppColors.border,
                        highlightedColor: AppColors.primary,
                      ),
                    ),
                    child: MultiSplitView(
                      controller: _splitController,
                    ),
                  ),
          ),
          _buildBottomStatusBar(),
        ],
      ),
    );
  }

  Widget _buildTopToolbar() {
    final ws = _activeWorkspace;

    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: AppColors.panelHeader,
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.hub_outlined, color: AppColors.primary, size: 20),
          const SizedBox(width: 8),
          const Text(
            'Terminal Agente',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 14),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.border),
              backgroundColor: AppColors.surface,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              minimumSize: const Size(0, 30),
            ),
            onPressed: _pickWorkspaceFolder,
            icon: const Icon(
              Icons.folder_open_rounded,
              size: 15,
              color: AppColors.primary,
            ),
            label: Text(
              ws != null ? ws.name : 'Abrir Workspace...',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_recentWorkspaces.length > 1)
            PopupMenuButton<String>(
              tooltip: 'Workspaces recentes (SQLite)',
              icon: const Icon(
                Icons.arrow_drop_down_rounded,
                color: AppColors.textSecondary,
              ),
              onSelected: _openWorkspaceDirectory,
              itemBuilder: (_) => _recentWorkspaces.map((item) {
                return PopupMenuItem<String>(
                  value: item.rootPath,
                  child: Row(
                    children: [
                      Icon(
                        item.isGitRepo
                            ? Icons.account_tree_outlined
                            : Icons.folder_outlined,
                        size: 15,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${item.name} (${item.rootPath})',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          if (ws != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: ws.isGitRepo
                    ? AppColors.statusAdded.withValues(alpha: 0.14)
                    : AppColors.cyan.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: ws.isGitRepo
                      ? AppColors.statusAdded.withValues(alpha: 0.45)
                      : AppColors.cyan.withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    ws.isGitRepo
                        ? Icons.account_tree_rounded
                        : Icons.storage_rounded,
                    size: 12,
                    color: ws.isGitRepo ? AppColors.statusAdded : AppColors.cyan,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    ws.isGitRepo ? 'Git + Watcher Ativo' : 'SQLite Watcher Ativo',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color:
                          ws.isGitRepo ? AppColors.statusAdded : AppColors.cyan,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            tooltip: 'Diminuir fonte',
            icon: const Icon(Icons.text_decrease_rounded, size: 16),
            onPressed: () => _adjustFontSize(-1.0),
          ),
          Text(
            '${_fontSize.toInt()}px',
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              fontFamily: AppTheme.monoFontFamily,
            ),
          ),
          IconButton(
            tooltip: 'Aumentar fonte',
            icon: const Icon(Icons.text_increase_rounded, size: 16),
            onPressed: () => _adjustFontSize(1.0),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomStatusBar() {
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: AppColors.panelHeader,
        border: Border(
          top: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.circle,
            size: 8,
            color: AppColors.statusAdded,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _statusMessage,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Text(
            'Arquivos alterados: ${_changes.length}  |  Snapshots na Timeline: ${_snapshots.length}  |  SQLite CAS Ativo',
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textMuted,
              fontFamily: AppTheme.monoFontFamily,
            ),
          ),
        ],
      ),
    );
  }
}
