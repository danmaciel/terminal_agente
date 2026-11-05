import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import '../core/theme/app_theme.dart';
import '../models/domain_models.dart';

class _FileTreeNode {
  final String name;
  final String fullPath;
  final bool isDirectory;
  final TrackedFileChange? fileChange;
  final Map<String, _FileTreeNode> childrenMap = {};

  _FileTreeNode({
    required this.name,
    required this.fullPath,
    required this.isDirectory,
    this.fileChange,
  });

  List<_FileTreeNode> get sortedChildren {
    final list = childrenMap.values.toList();
    list.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1; // Directories first
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  int get recursiveFileCount {
    if (!isDirectory) return 1;
    int total = 0;
    for (final child in childrenMap.values) {
      total += child.recursiveFileCount;
    }
    return total;
  }
}

class _FlattenedTreeRow {
  final _FileTreeNode node;
  final int depth;

  const _FlattenedTreeRow({
    required this.node,
    required this.depth,
  });
}

class FilesAndTimelinePanel extends StatefulWidget {
  final List<TrackedFileChange> changes;
  final List<SnapshotModel> snapshots;
  final String? selectedFilePath;
  final ValueChanged<TrackedFileChange> onSelectFile;
  final ValueChanged<String> onRevertFile;
  final VoidCallback onRefresh;
  final VoidCallback onAcceptAllBaseline;
  final ValueChanged<String> onCreateManualCheckpoint;
  final void Function(SnapshotModel snapshot, bool restoreBeforeState) onRestoreSnapshot;

  const FilesAndTimelinePanel({
    super.key,
    required this.changes,
    required this.snapshots,
    required this.selectedFilePath,
    required this.onSelectFile,
    required this.onRevertFile,
    required this.onRefresh,
    required this.onAcceptAllBaseline,
    required this.onCreateManualCheckpoint,
    required this.onRestoreSnapshot,
  });

  @override
  State<FilesAndTimelinePanel> createState() => _FilesAndTimelinePanelState();
}

class _FilesAndTimelinePanelState extends State<FilesAndTimelinePanel> {
  int _activeSubTab = 0; // 0 = Arquivos Alterados (Tree), 1 = Timeline
  final Set<String> _collapsedDirs = <String>{};

  _FileTreeNode _buildDirectoryTree() {
    final root = _FileTreeNode(
      name: '',
      fullPath: '',
      isDirectory: true,
    );

    for (final change in widget.changes) {
      final normalized = change.relativePath.replaceAll('\\', '/');
      final parts = p.posix.split(normalized).where((s) => s.isNotEmpty && s != '.').toList();
      if (parts.isEmpty) continue;

      _FileTreeNode current = root;
      String currentPath = '';

      for (int i = 0; i < parts.length; i++) {
        final part = parts[i];
        final isLast = i == parts.length - 1;
        currentPath = currentPath.isEmpty ? part : '$currentPath/$part';

        if (isLast) {
          current.childrenMap[part] = _FileTreeNode(
            name: part,
            fullPath: change.relativePath,
            isDirectory: false,
            fileChange: change,
          );
        } else {
          current = current.childrenMap.putIfAbsent(
            part,
            () => _FileTreeNode(
              name: part,
              fullPath: currentPath,
              isDirectory: true,
            ),
          );
        }
      }
    }

    return root;
  }

  List<_FlattenedTreeRow> _flattenTree(_FileTreeNode root) {
    final rows = <_FlattenedTreeRow>[];

    void visit(_FileTreeNode node, int depth) {
      for (final child in node.sortedChildren) {
        rows.add(_FlattenedTreeRow(node: child, depth: depth));
        if (child.isDirectory && !_collapsedDirs.contains(child.fullPath)) {
          visit(child, depth + 1);
        }
      }
    }

    visit(root, 0);
    return rows;
  }

  Set<String> _collectAllDirectoryPaths(_FileTreeNode root) {
    final dirs = <String>{};
    void visit(_FileTreeNode node) {
      for (final child in node.childrenMap.values) {
        if (child.isDirectory) {
          dirs.add(child.fullPath);
          visit(child);
        }
      }
    }

    visit(root);
    return dirs;
  }

  void _toggleDirectory(String dirPath) {
    setState(() {
      if (_collapsedDirs.contains(dirPath)) {
        _collapsedDirs.remove(dirPath);
      } else {
        _collapsedDirs.add(dirPath);
      }
    });
  }

  void _expandAll() {
    setState(() {
      _collapsedDirs.clear();
    });
  }

  void _collapseAll(_FileTreeNode root) {
    setState(() {
      _collapsedDirs
        ..clear()
        ..addAll(_collectAllDirectoryPaths(root));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSubTabHeader(),
          Expanded(
            child: _activeSubTab == 0
                ? _buildChangedFilesTree(context)
                : _buildTimelineList(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSubTabHeader() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: AppColors.panelHeader,
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTabButton(
                    index: 0,
                    icon: Icons.account_tree_outlined,
                    label: 'Alterados (${widget.changes.length})',
                  ),
                  const SizedBox(width: 6),
                  _buildTabButton(
                    index: 1,
                    icon: Icons.timeline_rounded,
                    label: 'Timeline (${widget.snapshots.length})',
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Atualizar detecção de arquivos',
            icon: const Icon(Icons.refresh_rounded, size: 16, color: AppColors.textSecondary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: widget.onRefresh,
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _activeSubTab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() => _activeSubTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.surfaceElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? AppColors.primary : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChangedFilesTree(BuildContext context) {
    final rootNode = _buildDirectoryTree();
    final visibleRows = _flattenTree(rootNode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.changes.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.changes.length} arq.',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
                IconButton(
                  tooltip: 'Expandir todas as pastas',
                  icon: const Icon(Icons.unfold_more_rounded, size: 15, color: AppColors.textSecondary),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  onPressed: _expandAll,
                ),
                IconButton(
                  tooltip: 'Recolher todas as pastas',
                  icon: const Icon(Icons.unfold_less_rounded, size: 15, color: AppColors.textSecondary),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  onPressed: () => _collapseAll(rootNode),
                ),
                const SizedBox(width: 2),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: const Size(0, 24),
                  ),
                  onPressed: widget.onAcceptAllBaseline,
                  icon: const Icon(
                    Icons.check_circle_outline,
                    size: 13,
                    color: AppColors.statusAdded,
                  ),
                  label: const Text(
                    'Base',
                    style: TextStyle(fontSize: 11, color: AppColors.statusAdded),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: widget.changes.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.verified_outlined,
                          size: 36,
                          color: AppColors.textMuted,
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Nenhuma alteração pendente',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Execute comandos ou agentes no terminal ao lado para visualizar a árvore de diretórios e o Diff em tempo real.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: visibleRows.length,
                  itemBuilder: (context, idx) {
                    final row = visibleRows[idx];
                    if (row.node.isDirectory) {
                      return _buildDirectoryRow(row.node, row.depth);
                    } else {
                      return _buildFileRow(row.node, row.depth);
                    }
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDirectoryRow(_FileTreeNode dirNode, int depth) {
    final isCollapsed = _collapsedDirs.contains(dirNode.fullPath);
    final fileCount = dirNode.recursiveFileCount;

    return InkWell(
      onTap: () => _toggleDirectory(dirNode.fullPath),
      child: Container(
        padding: EdgeInsets.only(
          left: 8.0 + (depth * 14.0),
          right: 8.0,
          top: 5.0,
          bottom: 5.0,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: AppColors.border.withValues(alpha: 0.35),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isCollapsed
                  ? Icons.keyboard_arrow_right_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 2),
            Icon(
              isCollapsed
                  ? Icons.folder_rounded
                  : Icons.folder_open_rounded,
              size: 15,
              color: AppColors.statusModified,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                dirNode.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$fileCount',
                style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted,
                  fontFamily: AppTheme.monoFontFamily,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileRow(_FileTreeNode fileNode, int depth) {
    final change = fileNode.fileChange!;
    final isSelected = change.relativePath == widget.selectedFilePath;

    return Material(
      color: isSelected
          ? AppColors.primary.withValues(alpha: 0.16)
          : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onSelectFile(change),
        child: Container(
          padding: EdgeInsets.only(
            left: 12.0 + (depth * 14.0),
            right: 6.0,
            top: 5.0,
            bottom: 5.0,
          ),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: isSelected ? AppColors.primary : Colors.transparent,
                width: 2.5,
              ),
              bottom: BorderSide(
                color: AppColors.border.withValues(alpha: 0.35),
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children: [
              _buildStatusBadge(change.status),
              const SizedBox(width: 6),
              const Icon(
                Icons.description_outlined,
                size: 14,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  fileNode.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                    color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _buildDeltaCounts(change),
              const SizedBox(width: 2),
              IconButton(
                tooltip: 'Reverter "${change.relativePath}" para como estava antes',
                icon: const Icon(
                  Icons.restore_rounded,
                  size: 15,
                  color: AppColors.statusModified,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 24,
                  minHeight: 24,
                ),
                onPressed: () => widget.onRevertFile(change.relativePath),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineList(BuildContext context) {
    final timeFmt = DateFormat('HH:mm:ss');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Snapshots SQLite',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: const Size(0, 24),
                ),
                onPressed: () => _showCheckpointDialog(context),
                icon: const Icon(
                  Icons.add_task_rounded,
                  size: 13,
                  color: AppColors.primary,
                ),
                label: const Text(
                  'Checkpoint',
                  style: TextStyle(fontSize: 11, color: AppColors.primary),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: widget.snapshots.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      'Nenhum snapshot registrado ainda nesta sessão.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: widget.snapshots.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.border),
                  itemBuilder: (context, idx) {
                    final snap = widget.snapshots[idx];
                    final isManual = snap.triggerType == 'manual';
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isManual
                                ? Icons.bookmark_added_rounded
                                : Icons.history_toggle_off_rounded,
                            size: 16,
                            color: isManual
                                ? AppColors.secondary
                                : AppColors.cyan,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  snap.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                Text(
                                  '${timeFmt.format(snap.createdAt)} • ${snap.filesCount} arq.',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuButton<bool>(
                            tooltip: 'Opções de restauração deste ponto',
                            icon: const Icon(
                              Icons.settings_backup_restore_rounded,
                              size: 17,
                              color: AppColors.primary,
                            ),
                            onSelected: (restoreBefore) {
                              widget.onRestoreSnapshot(snap, restoreBefore);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem<bool>(
                                value: false,
                                child: Text(
                                  'Restaurar estado DESTE snapshot (Depois)',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              PopupMenuItem<bool>(
                                value: true,
                                child: Text(
                                  'Reverter para ANTES deste snapshot',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildStatusBadge(FileChangeStatus status) {
    final (String letter, Color color) = switch (status) {
      FileChangeStatus.modified => ('M', AppColors.statusModified),
      FileChangeStatus.added => ('A', AppColors.statusAdded),
      FileChangeStatus.deleted => ('D', AppColors.statusDeleted),
      FileChangeStatus.untracked => ('U', AppColors.statusUntracked),
    };

    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
          fontFamily: AppTheme.monoFontFamily,
        ),
      ),
    );
  }

  Widget _buildDeltaCounts(TrackedFileChange change) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (change.addedLines > 0)
          Text(
            '+${change.addedLines}',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: AppColors.statusAdded,
              fontFamily: AppTheme.monoFontFamily,
            ),
          ),
        if (change.addedLines > 0 && change.removedLines > 0)
          const SizedBox(width: 3),
        if (change.removedLines > 0)
          Text(
            '-${change.removedLines}',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: AppColors.statusDeleted,
              fontFamily: AppTheme.monoFontFamily,
            ),
          ),
      ],
    );
  }

  void _showCheckpointDialog(BuildContext context) {
    final ctrl = TextEditingController(text: 'Checkpoint Manual');
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Criar Checkpoint na Timeline',
            style: TextStyle(fontSize: 15, color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Descrição do momento (ex: Antes de rodar Agente)',
              isDense: true,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final text = ctrl.text.trim();
                if (text.isNotEmpty) {
                  widget.onCreateManualCheckpoint(text);
                  Navigator.of(ctx).pop();
                }
              },
              child: const Text('Salvar Snapshot'),
            ),
          ],
        );
      },
    );
  }
}
