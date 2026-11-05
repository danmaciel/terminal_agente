import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/theme/app_theme.dart';
import '../models/domain_models.dart';
import '../services/diff_engine_service.dart';

class DiffViewerPanel extends StatefulWidget {
  final TrackedFileChange? selectedChange;
  final FileDiffResult? diffResult;
  final DiffViewMode viewMode;
  final double fontSize;
  final ValueChanged<DiffViewMode> onToggleViewMode;
  final ValueChanged<String> onRevertFile;
  final void Function(String relativePath, DiffHunk hunk) onRevertHunk;
  final void Function(String relativePath, String updatedContent) onSaveEditedFile;
  final void Function(String relativePath, DiffHunk hunk, String replacementBlockText) onEditHunk;
  final void Function(String text, {required bool execute}) onSendReferenceToTerminal;

  const DiffViewerPanel({
    super.key,
    required this.selectedChange,
    required this.diffResult,
    required this.viewMode,
    this.fontSize = 13.0,
    required this.onToggleViewMode,
    required this.onRevertFile,
    required this.onRevertHunk,
    required this.onSaveEditedFile,
    required this.onEditHunk,
    required this.onSendReferenceToTerminal,
  });

  @override
  State<DiffViewerPanel> createState() => _DiffViewerPanelState();
}

class _DiffViewerPanelState extends State<DiffViewerPanel> {
  late final TextEditingController _editorController;
  String? _loadedFilePath;
  String _lastSyncedContent = '';
  bool _isDirty = false;
  CodeSelectionReference? _activeReference;
  int? _anchorLineNumber;

  @override
  void initState() {
    super.initState();
    _editorController = TextEditingController();
    _editorController.addListener(_onEditorStateChanged);
    _syncEditorWithSelectedChange(force: true);
  }

  @override
  void didUpdateWidget(covariant DiffViewerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newPath = widget.selectedChange?.relativePath;
    final newAfter = widget.selectedChange?.afterContent ?? '';

    if (newPath != _loadedFilePath) {
      _syncEditorWithSelectedChange(force: true);
      _activeReference = null;
      _anchorLineNumber = null;
    } else if (!_isDirty && newAfter != _lastSyncedContent) {
      _syncEditorWithSelectedChange(force: true);
    }
  }

  void _syncEditorWithSelectedChange({bool force = false}) {
    final change = widget.selectedChange;
    if (change == null) {
      _loadedFilePath = null;
      _lastSyncedContent = '';
      _isDirty = false;
      _editorController.text = '';
      return;
    }

    if (force || !_isDirty) {
      _loadedFilePath = change.relativePath;
      _lastSyncedContent = change.afterContent;
      _isDirty = false;
      if (_editorController.text != change.afterContent) {
        _editorController.value = TextEditingValue(
          text: change.afterContent,
          selection: const TextSelection.collapsed(offset: 0),
        );
      }
    }
  }

  void _onEditorStateChanged() {
    final change = widget.selectedChange;
    if (change == null) return;

    final currentText = _editorController.text;
    final dirtyNow = currentText != _lastSyncedContent;

    CodeSelectionReference? updatedRef = _activeReference;
    final sel = _editorController.selection;
    if (sel.isValid && !sel.isCollapsed) {
      final startOffset = sel.start.clamp(0, currentText.length);
      final endOffset = sel.end.clamp(startOffset, currentText.length);
      final startLine = _lineNumberAtOffset(currentText, startOffset);
      final endLine = _lineNumberAtOffset(currentText, endOffset);
      final snippet = currentText.substring(startOffset, endOffset);
      updatedRef = CodeSelectionReference(
        relativePath: change.relativePath,
        startLine: startLine,
        endLine: endLine,
        selectedText: snippet,
      );
    }

    if (dirtyNow != _isDirty || updatedRef?.referenceToken != _activeReference?.referenceToken) {
      setState(() {
        _isDirty = dirtyNow;
        _activeReference = updatedRef;
      });
    }
  }

  int _lineNumberAtOffset(String text, int offset) {
    if (offset <= 0 || text.isEmpty) return 1;
    int line = 1;
    final limit = offset.clamp(0, text.length);
    for (int i = 0; i < limit; i++) {
      if (text.codeUnitAt(i) == 10) {
        line++;
      }
    }
    return line;
  }

  void _saveCurrentEditorFile({bool alsoReferenceSelection = false}) {
    final change = widget.selectedChange;
    if (change == null) return;

    final updatedText = _editorController.text;
    _lastSyncedContent = updatedText;
    setState(() {
      _isDirty = false;
    });
    widget.onSaveEditedFile(change.relativePath, updatedText);

    if (alsoReferenceSelection && _activeReference != null) {
      _showAgentPromptDialog(context, _activeReference!);
    }
  }

  void _handleLineTapInDiff(TrackedFileChange change, int lineNumber) {
    final lines = change.afterContent.replaceAll('\r\n', '\n').split('\n');
    setState(() {
      if (_anchorLineNumber == null) {
        _anchorLineNumber = lineNumber;
        final safeIdx = (lineNumber - 1).clamp(0, lines.length - 1);
        _activeReference = CodeSelectionReference(
          relativePath: change.relativePath,
          startLine: lineNumber,
          endLine: lineNumber,
          selectedText: lines.isNotEmpty ? lines[safeIdx] : '',
        );
      } else {
        final start = _anchorLineNumber! < lineNumber ? _anchorLineNumber! : lineNumber;
        final end = _anchorLineNumber! > lineNumber ? _anchorLineNumber! : lineNumber;
        _anchorLineNumber = null;
        final sIdx = (start - 1).clamp(0, lines.length - 1);
        final eIdx = end.clamp(sIdx, lines.length);
        _activeReference = CodeSelectionReference(
          relativePath: change.relativePath,
          startLine: start,
          endLine: end,
          selectedText: lines.isNotEmpty ? lines.sublist(sIdx, eIdx).join('\n') : '',
        );
      }
    });
  }

  void _selectHunkAsReference(TrackedFileChange change, DiffHunk hunk) {
    final startLine = hunk.newStartIndex + 1;
    final endLine = hunk.newCount > 0
        ? hunk.newStartIndex + hunk.newCount
        : startLine;

    setState(() {
      _activeReference = CodeSelectionReference(
        relativePath: change.relativePath,
        startLine: startLine,
        endLine: endLine,
        selectedText: hunk.newLines.join('\n'),
      );
    });
  }

  bool _isLineSelected(int? lineNumber) {
    if (lineNumber == null || _activeReference == null) return false;
    return lineNumber >= _activeReference!.startLine &&
        lineNumber <= _activeReference!.endLine;
  }

  @override
  void dispose() {
    _editorController.removeListener(_onEditorStateChanged);
    _editorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final change = widget.selectedChange;
    final diff = widget.diffResult;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (widget.viewMode == DiffViewMode.editor || _isDirty) {
            _saveCurrentEditorFile();
          }
        },
      },
      child: Container(
        color: AppColors.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(change, diff),
            if (change != null && widget.viewMode == DiffViewMode.split)
              _buildSplitSubHeader(),
            if (change != null && widget.viewMode == DiffViewMode.editor)
              _buildEditorToolbar(change),
            Expanded(
              child: (change == null || diff == null)
                  ? _buildEmptyState()
                  : switch (widget.viewMode) {
                      DiffViewMode.split => _buildSplitDiffBody(change, diff),
                      DiffViewMode.unified => _buildUnifiedDiffBody(change, diff),
                      DiffViewMode.editor => _buildCodeEditorBody(change),
                    },
            ),
            if (change != null && _activeReference != null)
              _buildSelectionReferenceBar(context, _activeReference!),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(TrackedFileChange? change, FileDiffResult? diff) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: AppColors.panelHeader,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Icon(
            widget.viewMode == DiffViewMode.editor
                ? Icons.edit_document
                : Icons.compare_arrows_rounded,
            size: 17,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: change == null
                ? const Text(
                    'Visualizador de Diff & Editor',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  )
                : Text(
                    diff != null
                        ? '${change.relativePath}${_isDirty ? " ●" : ""}  (+${diff.addedLines}/-${diff.removedLines})'
                        : '${change.relativePath}${_isDirty ? " ●" : ""}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      fontFamily: AppTheme.monoFontFamily,
                    ),
                  ),
          ),
          _buildViewModeToggle(),
          if (change != null) ...[
            const SizedBox(width: 6),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.statusModified.withValues(alpha: 0.16),
                foregroundColor: AppColors.statusModified,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                minimumSize: const Size(0, 24),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => widget.onRevertFile(change.relativePath),
              icon: const Icon(Icons.restore_rounded, size: 13),
              label: const Text(
                'Reverter Arquivo',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildViewModeToggle() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeChip(
            label: 'Lado a Lado',
            icon: Icons.view_column_outlined,
            mode: DiffViewMode.split,
          ),
          _buildModeChip(
            label: 'Unificado',
            icon: Icons.view_headline_outlined,
            mode: DiffViewMode.unified,
          ),
          _buildModeChip(
            label: _isDirty ? 'Editor ●' : 'Editor',
            icon: Icons.edit_outlined,
            mode: DiffViewMode.editor,
          ),
        ],
      ),
    );
  }

  Widget _buildModeChip({
    required String label,
    required IconData icon,
    required DiffViewMode mode,
  }) {
    final isSelected = widget.viewMode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: () => widget.onToggleViewMode(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 12,
              color: isSelected ? AppColors.primary : AppColors.textMuted,
            ),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorToolbar(TrackedFileChange change) {
    final totalLines = '\n'.allMatches(_editorController.text).length + 1;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Icon(
            _isDirty ? Icons.circle : Icons.check_circle_outline,
            size: 12,
            color: _isDirty ? AppColors.statusModified : AppColors.statusAdded,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _isDirty
                  ? 'Alterações manuais pendentes ($totalLines linhas) — Selecione qualquer trecho para referenciar no terminal'
                  : 'Modo Edição ($totalLines linhas) — Selecione texto com o mouse para gerar @referência para o Agente',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: _isDirty ? AppColors.statusModified : AppColors.textSecondary,
              ),
            ),
          ),
          if (_isDirty) ...[
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                minimumSize: const Size(0, 24),
              ),
              onPressed: () => _syncEditorWithSelectedChange(force: true),
              child: const Text(
                'Descartar',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ),
            const SizedBox(width: 4),
          ],
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _isDirty ? AppColors.statusAdded : AppColors.surfaceElevated,
              foregroundColor: _isDirty ? const Color(0xFF0F111A) : AppColors.textPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              minimumSize: const Size(0, 24),
            ),
            onPressed: () => _saveCurrentEditorFile(),
            icon: const Icon(Icons.save_outlined, size: 13),
            label: const Text(
              'Salvar (Ctrl+S)',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeEditorBody(TrackedFileChange change) {
    final linesCount = '\n'.allMatches(_editorController.text).length + 1;

    return SingleChildScrollView(
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Line numbers gutter
            Container(
              width: 48,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(right: BorderSide(color: AppColors.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(linesCount, (index) {
                  final lineNum = index + 1;
                  final isSelected = _isLineSelected(lineNum);
                  return GestureDetector(
                    onTap: () => _handleLineTapInDiff(change, lineNum),
                    child: Container(
                      color: isSelected
                          ? AppColors.primary.withValues(alpha: 0.25)
                          : Colors.transparent,
                      child: Text(
                        '$lineNum',
                        style: TextStyle(
                          fontSize: widget.fontSize,
                          fontFamily: AppTheme.monoFontFamily,
                          height: 1.4,
                          color: isSelected
                              ? AppColors.cyan
                              : AppColors.textMuted,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
            // Editable code field
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: TextField(
                  key: const ValueKey('code_editor_text_field'),
                  controller: _editorController,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(
                    fontSize: widget.fontSize,
                    fontFamily: AppTheme.monoFontFamily,
                    color: AppColors.textPrimary,
                    height: 1.4,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionReferenceBar(
    BuildContext context,
    CodeSelectionReference ref,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border(
          top: BorderSide(color: AppColors.primary.withValues(alpha: 0.6), width: 1.5),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.alternate_email_rounded, size: 15, color: AppColors.cyan),
          const SizedBox(width: 5),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.cyan.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppColors.cyan.withValues(alpha: 0.45)),
                    ),
                    child: Text(
                      ref.referenceToken,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.cyan,
                        fontFamily: AppTheme.monoFontFamily,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '(${ref.lineLabel})',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.cyan),
              foregroundColor: AppColors.cyan,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
              minimumSize: const Size(0, 24),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () {
              if (_isDirty) _saveCurrentEditorFile();
              widget.onSendReferenceToTerminal('${ref.referenceToken} ', execute: false);
            },
            icon: const Icon(Icons.terminal_rounded, size: 12),
            label: const Text(
              'Inserir @ no Terminal',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 5),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: const Color(0xFF0F111A),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
              minimumSize: const Size(0, 24),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () {
              if (_isDirty) _saveCurrentEditorFile();
              _showAgentPromptDialog(context, ref);
            },
            icon: const Icon(Icons.auto_awesome_rounded, size: 12),
            label: const Text(
              'Perguntar ao Agente...',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: 'Limpar seleção de referência',
            icon: const Icon(Icons.close_rounded, size: 14, color: AppColors.textMuted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            onPressed: () {
              setState(() {
                _activeReference = null;
                _anchorLineNumber = null;
              });
            },
          ),
        ],
      ),
    );
  }

  void _showAgentPromptDialog(BuildContext context, CodeSelectionReference ref) {
    final promptCtrl = TextEditingController(
      text: 'Analise este ponto em ${ref.referenceToken} e verifique se é possível simplificar',
    );

    final presets = [
      (
        'Simplificar',
        'Analise este ponto em ${ref.referenceToken} e verifique se é possível simplificar'
      ),
      (
        'Revisar Bugs',
        'Revise o código em ${ref.referenceToken} e verifique possíveis bugs ou casos de borda'
      ),
      (
        'Explicar',
        'Explique detalhadamente o que o trecho em ${ref.referenceToken} faz'
      ),
      (
        'Refatorar / Otimizar',
        'Refatore o trecho em ${ref.referenceToken} melhorando a legibilidade e performance'
      ),
    ];

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, color: AppColors.cyan, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Enviar Referência ${ref.referenceToken} ao Terminal',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Sugestões rápidas de instrução:',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: presets.map((preset) {
                    return ActionChip(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: AppColors.surfaceElevated,
                      side: const BorderSide(color: AppColors.border),
                      label: Text(
                        preset.$1,
                        style: const TextStyle(fontSize: 11, color: AppColors.cyan),
                      ),
                      onPressed: () {
                        promptCtrl.text = preset.$2;
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: promptCtrl,
                  maxLines: 3,
                  autofocus: true,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Comando / Instrução para o Agente no Terminal',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (ref.selectedText.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 110),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        ref.selectedText,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: AppTheme.monoFontFamily,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
            OutlinedButton.icon(
              onPressed: () {
                final text = promptCtrl.text.trim();
                if (text.isNotEmpty) {
                  widget.onSendReferenceToTerminal(text, execute: false);
                  Navigator.of(ctx).pop();
                }
              },
              icon: const Icon(Icons.edit_note_rounded, size: 16),
              label: const Text('Colar sem Enter'),
            ),
            FilledButton.icon(
              onPressed: () {
                final text = promptCtrl.text.trim();
                if (text.isNotEmpty) {
                  widget.onSendReferenceToTerminal(text, execute: true);
                  Navigator.of(ctx).pop();
                }
              },
              icon: const Icon(Icons.send_rounded, size: 15),
              label: const Text('Enviar ao Terminal (Enter)'),
            ),
          ],
        );
      },
    );
  }

  void _showQuickEditHunkDialog(
    BuildContext context,
    TrackedFileChange change,
    DiffHunk hunk,
  ) {
    final hunkCtrl = TextEditingController(text: hunk.newLines.join('\n'));
    final startLine = hunk.newStartIndex + 1;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Row(
            children: [
              const Icon(Icons.edit_note_rounded, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Editar Bloco #${hunk.id} (${hunk.header}) em ${change.relativePath}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Edite as linhas deste bloco abaixo:',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 280),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: TextField(
                    controller: hunkCtrl,
                    maxLines: null,
                    autofocus: true,
                    style: TextStyle(
                      fontSize: widget.fontSize,
                      fontFamily: AppTheme.monoFontFamily,
                      color: AppColors.textPrimary,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
            OutlinedButton.icon(
              onPressed: () {
                final newBlock = hunkCtrl.text;
                final newLinesCount = '\n'.allMatches(newBlock).length + 1;
                final endLine = startLine + newLinesCount - 1;
                widget.onEditHunk(change.relativePath, hunk, newBlock);
                final ref = CodeSelectionReference(
                  relativePath: change.relativePath,
                  startLine: startLine,
                  endLine: endLine,
                  selectedText: newBlock,
                );
                setState(() {
                  _activeReference = ref;
                });
                Navigator.of(ctx).pop();
                _showAgentPromptDialog(context, ref);
              },
              icon: const Icon(Icons.auto_awesome_rounded, size: 15, color: AppColors.cyan),
              label: const Text('Salvar e Perguntar ao Agente'),
            ),
            FilledButton.icon(
              onPressed: () {
                widget.onEditHunk(change.relativePath, hunk, hunkCtrl.text);
                Navigator.of(ctx).pop();
              },
              icon: const Icon(Icons.save_outlined, size: 15),
              label: const Text('Salvar Bloco'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSplitSubHeader() {
    return Container(
      height: 26,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.diffRemovedText,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'COMO ESTAVA (ANTES / BASELINE)',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.diffRemovedText,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(width: 1, color: AppColors.border),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.diffAddedText,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'COMO FICOU (AGORA / ALTERADO)',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.diffAddedText,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.find_in_page_outlined,
              size: 42,
              color: AppColors.textMuted,
            ),
            SizedBox(height: 12),
            Text(
              'Selecione um arquivo na árvore à esquerda',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Visualize o Diff Lado a Lado ou Unificado, edite o código diretamente no modo Editor (Ctrl+S) ou clique nas linhas/blocos para enviar a referência exata (@arquivo#L10-L20) para o Agente no terminal.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSplitDiffBody(TrackedFileChange change, FileDiffResult diff) {
    final hunkMap = {for (final h in diff.hunks) h.id: h};

    return ListView.builder(
      itemCount: diff.splitRows.length,
      itemBuilder: (context, idx) {
        final row = diff.splitRows[idx];
        final hunk = row.hunkId != null ? hunkMap[row.hunkId] : null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (row.isHunkHeader && hunk != null)
              _buildHunkHeaderBar(context, change, hunk),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _buildSingleDiffCell(
                      change: change,
                      line: row.left,
                      isLeftSide: true,
                    ),
                  ),
                  Container(width: 1, color: AppColors.border),
                  Expanded(
                    child: _buildSingleDiffCell(
                      change: change,
                      line: row.right,
                      isLeftSide: false,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildUnifiedDiffBody(TrackedFileChange change, FileDiffResult diff) {
    final hunkMap = {for (final h in diff.hunks) h.id: h};
    final renderedHunks = <int>{};

    return ListView.builder(
      itemCount: diff.unifiedLines.length,
      itemBuilder: (context, idx) {
        final line = diff.unifiedLines[idx];
        final hunkId = line.hunkId;
        DiffHunk? hunkToRender;
        if (hunkId != null && !renderedHunks.contains(hunkId)) {
          renderedHunks.add(hunkId);
          hunkToRender = hunkMap[hunkId];
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hunkToRender != null)
              _buildHunkHeaderBar(context, change, hunkToRender),
            _buildUnifiedDiffRow(change, line),
          ],
        );
      },
    );
  }

  Widget _buildHunkHeaderBar(
    BuildContext context,
    TrackedFileChange change,
    DiffHunk hunk,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: const BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border(
          top: BorderSide(color: AppColors.border),
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.code_rounded, size: 14, color: AppColors.cyan),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Bloco #${hunk.id}  ${hunk.header}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: AppTheme.monoFontFamily,
                color: AppColors.cyan,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // 1. Referenciar bloco no terminal
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => _selectHunkAsReference(change, hunk),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.cyan.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: AppColors.cyan.withValues(alpha: 0.45),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.alternate_email_rounded, size: 11, color: AppColors.cyan),
                  SizedBox(width: 3),
                  Text(
                    '@ Referenciar',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.cyan,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 2. Edição rápida deste bloco
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => _showQuickEditHunkDialog(context, change, hunk),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: AppColors.secondary.withValues(alpha: 0.45),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit_note_rounded, size: 12, color: AppColors.secondary),
                  SizedBox(width: 3),
                  Text(
                    'Editar bloco',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 3. Reverter este bloco
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => widget.onRevertHunk(change.relativePath, hunk),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.5),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.undo_rounded, size: 12, color: AppColors.primary),
                  SizedBox(width: 3),
                  Text(
                    'Reverter este bloco',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleDiffCell({
    required TrackedFileChange change,
    required DiffLine? line,
    required bool isLeftSide,
  }) {
    if (line == null) {
      return Container(
        color: AppColors.surface.withValues(alpha: 0.45),
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: const SizedBox(height: 18),
      );
    }

    final int? lineNumber =
        isLeftSide ? line.oldLineNumber : line.newLineNumber;
    final bool isSelectedLine = !isLeftSide && _isLineSelected(lineNumber);

    final Color bgColor = isSelectedLine
        ? AppColors.cyan.withValues(alpha: 0.18)
        : switch (line.type) {
            DiffLineType.removed => AppColors.diffRemovedBg,
            DiffLineType.added => AppColors.diffAddedBg,
            DiffLineType.unchanged => Colors.transparent,
          };

    final String prefix = switch (line.type) {
      DiffLineType.removed => '-',
      DiffLineType.added => '+',
      DiffLineType.unchanged => ' ',
    };

    return Container(
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: (!isLeftSide && lineNumber != null)
                ? () => _handleLineTapInDiff(change, lineNumber)
                : null,
            child: SizedBox(
              width: 34,
              child: Text(
                lineNumber?.toString() ?? '',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: widget.fontSize - 1.5,
                  color: isSelectedLine ? AppColors.cyan : AppColors.textMuted,
                  fontWeight:
                      isSelectedLine ? FontWeight.bold : FontWeight.normal,
                  fontFamily: AppTheme.monoFontFamily,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 12,
            child: Text(
              prefix,
              style: TextStyle(
                fontSize: widget.fontSize,
                fontWeight: FontWeight.bold,
                color: line.type == DiffLineType.removed
                    ? AppColors.diffRemovedText
                    : line.type == DiffLineType.added
                        ? AppColors.diffAddedText
                        : AppColors.textMuted,
                fontFamily: AppTheme.monoFontFamily,
              ),
            ),
          ),
          Expanded(
            child: _buildLineRichText(line),
          ),
        ],
      ),
    );
  }

  Widget _buildUnifiedDiffRow(TrackedFileChange change, DiffLine line) {
    final targetLineNum = line.newLineNumber ?? line.oldLineNumber;
    final isSelectedLine = _isLineSelected(line.newLineNumber);

    final Color bgColor = isSelectedLine
        ? AppColors.cyan.withValues(alpha: 0.18)
        : switch (line.type) {
            DiffLineType.removed => AppColors.diffRemovedBg,
            DiffLineType.added => AppColors.diffAddedBg,
            DiffLineType.unchanged => Colors.transparent,
          };

    final String prefix = switch (line.type) {
      DiffLineType.removed => '-',
      DiffLineType.added => '+',
      DiffLineType.unchanged => ' ',
    };

    return Container(
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              line.oldLineNumber?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: widget.fontSize - 1.5,
                color: AppColors.textMuted,
                fontFamily: AppTheme.monoFontFamily,
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: targetLineNum != null
                ? () => _handleLineTapInDiff(change, targetLineNum)
                : null,
            child: SizedBox(
              width: 32,
              child: Text(
                line.newLineNumber?.toString() ?? '',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: widget.fontSize - 1.5,
                  color: isSelectedLine ? AppColors.cyan : AppColors.textMuted,
                  fontWeight:
                      isSelectedLine ? FontWeight.bold : FontWeight.normal,
                  fontFamily: AppTheme.monoFontFamily,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 14,
            child: Text(
              prefix,
              style: TextStyle(
                fontSize: widget.fontSize,
                fontWeight: FontWeight.bold,
                color: line.type == DiffLineType.removed
                    ? AppColors.diffRemovedText
                    : line.type == DiffLineType.added
                        ? AppColors.diffAddedText
                        : AppColors.textMuted,
                fontFamily: AppTheme.monoFontFamily,
              ),
            ),
          ),
          Expanded(
            child: _buildLineRichText(line),
          ),
        ],
      ),
    );
  }

  Widget _buildLineRichText(DiffLine line) {
    final baseColor = switch (line.type) {
      DiffLineType.removed => AppColors.diffRemovedText,
      DiffLineType.added => AppColors.diffAddedText,
      DiffLineType.unchanged => AppColors.textPrimary,
    };

    if (line.inlineSpans.isEmpty) {
      return SelectableText(
        line.content,
        style: TextStyle(
          fontSize: widget.fontSize,
          color: baseColor,
          fontFamily: AppTheme.monoFontFamily,
          height: 1.35,
        ),
      );
    }

    final highlightBg = line.type == DiffLineType.removed
        ? AppColors.diffRemovedHighlight
        : AppColors.diffAddedHighlight;

    return SelectableText.rich(
      TextSpan(
        style: TextStyle(
          fontSize: widget.fontSize,
          color: baseColor,
          fontFamily: AppTheme.monoFontFamily,
          height: 1.35,
        ),
        children: line.inlineSpans.map((span) {
          return TextSpan(
            text: span.text,
            style: span.isHighlighted
                ? TextStyle(
                    backgroundColor: highlightBg,
                    fontWeight: FontWeight.w700,
                  )
                : null,
          );
        }).toList(),
      ),
    );
  }
}
