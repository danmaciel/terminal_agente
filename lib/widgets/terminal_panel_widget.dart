import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import '../core/theme/app_theme.dart';
import '../models/domain_models.dart';
import '../services/terminal_session_controller.dart';

class TerminalPanelWidget extends StatelessWidget {
  final TerminalTabsManager tabsManager;
  final List<QuickSnippetModel> snippets;
  final List<String> commandHistory;
  final double fontSize;
  final void Function(String title, String command, String category) onAddSnippet;
  final void Function(int id, String title, String command, String category)? onUpdateSnippet;
  final void Function(int id) onDeleteSnippet;
  final VoidCallback? onResetDefaultSnippets;

  const TerminalPanelWidget({
    super.key,
    required this.tabsManager,
    required this.snippets,
    required this.commandHistory,
    this.fontSize = 13.0,
    required this.onAddSnippet,
    this.onUpdateSnippet,
    required this.onDeleteSnippet,
    this.onResetDefaultSnippets,
  });

  static const TerminalTheme _ideTerminalTheme = TerminalTheme(
    cursor: AppColors.primary,
    selection: Color(0x557AA2F7),
    foreground: AppColors.textPrimary,
    background: AppColors.background,
    black: Color(0xFF15161E),
    red: Color(0xFFF7768E),
    green: Color(0xFF9ECE6A),
    yellow: Color(0xFFE0AF68),
    blue: Color(0xFF7AA2F7),
    magenta: Color(0xFFBB9AF7),
    cyan: Color(0xFF7DCFFF),
    white: Color(0xFFA9B1D6),
    brightBlack: Color(0xFF414868),
    brightRed: Color(0xFFFF899D),
    brightGreen: Color(0xFFBAF688),
    brightYellow: Color(0xFFFFC777),
    brightBlue: Color(0xFF8DB6FF),
    brightMagenta: Color(0xFFC8ABFF),
    brightCyan: Color(0xFF94E2FF),
    brightWhite: Color(0xFFC0CAF5),
    searchHitBackground: Color(0x66E0AF68),
    searchHitBackgroundCurrent: Color(0x997AA2F7),
    searchHitForeground: Color(0xFF0F111A),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tabsManager,
      builder: (context, _) {
        final activeTab = tabsManager.activeTab;

        return Container(
          color: AppColors.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTabsHeader(context, activeTab),
              _buildQuickSnippetsBar(context),
              Expanded(
                child: activeTab == null
                    ? const Center(
                        child: Text(
                          'Abra um Workspace para iniciar o Terminal',
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(6.0),
                        child: TerminalView(
                          key: ValueKey('term_session_${activeTab.sessionId}'),
                          activeTab.terminal,
                          controller: activeTab.viewController,
                          theme: _ideTerminalTheme,
                          autofocus: true,
                          textStyle: TerminalStyle(
                            fontSize: fontSize,
                            fontFamily: AppTheme.monoFontFamily,
                          ),
                          onKeyEvent: (focusNode, event) =>
                              _handleTerminalKeyEvent(context, activeTab, event),
                          onSecondaryTapDown: (details, offset) {
                            _showTerminalContextMenu(
                              context,
                              details.globalPosition,
                              activeTab,
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  KeyEventResult _handleTerminalKeyEvent(
    BuildContext context,
    TerminalTabInstance tab,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    if (!isCtrl) {
      return KeyEventResult.ignored;
    }

    // Ctrl+C (when text is selected in terminal) OR Ctrl+Shift+C -> Copy Selection
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      final hasSelection = tab.viewController.selection != null;
      if (isShift || hasSelection) {
        _copySelectionToClipboard(context, tab);
        return KeyEventResult.handled;
      }
      // If no selection and Shift is not pressed, let Ctrl+C send SIGINT (^C)
      return KeyEventResult.ignored;
    }

    // Ctrl+V OR Ctrl+Shift+V -> Paste from Clipboard into Terminal
    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      _pasteFromClipboard(tab);
      return KeyEventResult.handled;
    }

    // Ctrl+Shift+A -> Select All in Terminal Buffer
    if (event.logicalKey == LogicalKeyboardKey.keyA && isShift) {
      _selectAllBuffer(tab);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<bool> _copySelectionToClipboard(
    BuildContext context,
    TerminalTabInstance tab,
  ) async {
    final selection = tab.viewController.selection;
    if (selection == null) return false;

    final selectedText = tab.terminal.buffer.getText(selection);
    if (selectedText.isEmpty) return false;

    await Clipboard.setData(ClipboardData(text: selectedText));
    tab.viewController.clearSelection();
    return true;
  }

  Future<void> _pasteFromClipboard(TerminalTabInstance tab) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      tab.terminal.paste(text);
      tab.viewController.clearSelection();
    }
  }

  void _selectAllBuffer(TerminalTabInstance tab) {
    final buffer = tab.terminal.buffer;
    final startLine = (buffer.height - tab.terminal.viewHeight).clamp(0, buffer.height - 1);
    final endLine = (buffer.height - 1).clamp(0, buffer.height);
    tab.viewController.setSelection(
      buffer.createAnchor(0, startLine),
      buffer.createAnchor(tab.terminal.viewWidth, endLine),
      mode: SelectionMode.line,
    );
  }

  Future<void> _showTerminalContextMenu(
    BuildContext context,
    Offset globalPosition,
    TerminalTabInstance tab,
  ) async {
    final hasSelection = tab.viewController.selection != null;

    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx + 1,
        globalPosition.dy + 1,
      ),
      color: AppColors.surfaceElevated,
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          enabled: hasSelection,
          child: Row(
            children: [
              Icon(
                Icons.copy_rounded,
                size: 16,
                color: hasSelection ? AppColors.primary : AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Copiar seleção', style: TextStyle(fontSize: 12)),
              ),
              const Text(
                'Ctrl+C',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'paste',
          child: Row(
            children: [
              Icon(Icons.content_paste_rounded, size: 16, color: AppColors.cyan),
              SizedBox(width: 8),
              Expanded(
                child: Text('Colar', style: TextStyle(fontSize: 12)),
              ),
              Text(
                'Ctrl+V',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'select_all',
          child: Row(
            children: [
              Icon(Icons.select_all_rounded, size: 16, color: AppColors.textSecondary),
              SizedBox(width: 8),
              Expanded(
                child: Text('Selecionar tudo', style: TextStyle(fontSize: 12)),
              ),
              Text(
                'Ctrl+Shift+A',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'send_sigint',
          child: Row(
            children: [
              Icon(Icons.stop_circle_outlined, size: 16, color: AppColors.statusDeleted),
              SizedBox(width: 8),
              Text(
                'Interromper processo (Enviar ^C)',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'clear',
          child: Row(
            children: [
              Icon(Icons.cleaning_services_outlined, size: 16, color: AppColors.textSecondary),
              SizedBox(width: 8),
              Text('Limpar terminal', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'new_tab',
          child: Row(
            children: [
              Icon(Icons.add_rounded, size: 16, color: AppColors.statusAdded),
              SizedBox(width: 8),
              Text('Nova aba de terminal', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ],
    );

    if (!context.mounted || action == null) return;

    switch (action) {
      case 'copy':
        await _copySelectionToClipboard(context, tab);
      case 'paste':
        await _pasteFromClipboard(tab);
      case 'select_all':
        _selectAllBuffer(tab);
      case 'send_sigint':
        tabsManager.sendCommandToTab(tab, '\x03', execute: false);
      case 'clear':
        tabsManager.clearActiveTerminal();
      case 'new_tab':
        tabsManager.createNewTab();
    }
  }

  Widget _buildTabsHeader(BuildContext context, TerminalTabInstance? activeTab) {
    final tabs = tabsManager.tabs;
    final activeIdx = tabsManager.activeTabIndex;

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
          const Icon(Icons.terminal_rounded, size: 16, color: AppColors.cyan),
          const SizedBox(width: 6),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (context, idx) {
                final tab = tabs[idx];
                final isSelected = idx == activeIdx;
                return InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => tabsManager.selectTab(idx),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 5),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.surfaceElevated : AppColors.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isSelected ? AppColors.primary : AppColors.border,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: tab.isExited
                                ? AppColors.statusModified
                                : AppColors.statusAdded,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          tab.title,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                            color: isSelected
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                          ),
                        ),
                        if (tabs.length > 1) ...[
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: () => tabsManager.closeTab(idx),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 13,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'Nova aba de terminal',
            icon: const Icon(Icons.add_rounded, size: 18, color: AppColors.primary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: () => tabsManager.createNewTab(),
          ),
          if (activeTab != null) ...[
            IconButton(
              tooltip: 'Copiar seleção (Ctrl+C)',
              icon: const Icon(Icons.copy_rounded, size: 15, color: AppColors.textSecondary),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              onPressed: () => _copySelectionToClipboard(context, activeTab),
            ),
            IconButton(
              tooltip: 'Colar no terminal (Ctrl+V)',
              icon: const Icon(Icons.content_paste_rounded, size: 15, color: AppColors.textSecondary),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              onPressed: () => _pasteFromClipboard(activeTab),
            ),
          ],
          IconButton(
            tooltip: 'Histórico de comandos (SQLite)',
            icon: const Icon(Icons.history_rounded, size: 17, color: AppColors.textSecondary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: () => _showCommandHistoryModal(context),
          ),
          IconButton(
            tooltip: 'Limpar terminal ativo',
            icon: const Icon(Icons.cleaning_services_outlined, size: 16, color: AppColors.textSecondary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: tabsManager.clearActiveTerminal,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickSnippetsBar(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          const Tooltip(
            message: 'Atalhos de Agentes CLI e Comandos (Clique direito para opções)',
            child: Icon(Icons.bolt_rounded, size: 16, color: AppColors.secondary),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: snippets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, idx) {
                final snippet = snippets[idx];
                final isAgent = snippet.category == 'agent';
                final (iconData, accentColor) = _resolveSnippetStyle(snippet);

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: GestureDetector(
                    onSecondaryTapDown: (details) {
                      _showSnippetContextMenu(context, details.globalPosition, snippet);
                    },
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      backgroundColor: isAgent
                          ? accentColor.withValues(alpha: 0.14)
                          : AppColors.surfaceElevated,
                      side: BorderSide(
                        color: isAgent
                            ? accentColor.withValues(alpha: 0.45)
                            : AppColors.border,
                      ),
                      avatar: Icon(
                        iconData,
                        size: 13,
                        color: accentColor,
                      ),
                      label: Text(
                        snippet.title,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      tooltip:
                          'Executar "${snippet.command}" (Clique direito: Nova Aba / Editar / Remover)',
                      onPressed: () {
                        tabsManager.sendCommandToActiveTab(snippet.command);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Novo atalho de Agente / Comando',
            icon: const Icon(Icons.add_circle_outline, size: 16, color: AppColors.primary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: () => _showSnippetFormDialog(context),
          ),
          IconButton(
            tooltip: 'Gerenciar atalhos de Agentes (SQLite)',
            icon: const Icon(Icons.tune_rounded, size: 16, color: AppColors.textSecondary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: () => _showManageSnippetsModal(context),
          ),
        ],
      ),
    );
  }

  (IconData, Color) _resolveSnippetStyle(QuickSnippetModel snippet) {
    final cmdLower = snippet.command.toLowerCase();
    final titleLower = snippet.title.toLowerCase();

    if (cmdLower.startsWith('agy') || titleLower.contains('antigravity')) {
      return (Icons.rocket_launch_rounded, AppColors.cyan);
    }
    if (cmdLower.startsWith('codex') || titleLower.contains('codex')) {
      return (Icons.memory_rounded, AppColors.statusAdded);
    }
    if (cmdLower.startsWith('claude') || titleLower.contains('claude')) {
      return (Icons.smart_toy_outlined, AppColors.statusModified);
    }
    if (cmdLower.startsWith('gemini') || titleLower.contains('gemini')) {
      return (Icons.auto_awesome_rounded, AppColors.primary);
    }
    if (cmdLower.startsWith('aider') || titleLower.contains('aider')) {
      return (Icons.psychology_outlined, AppColors.secondary);
    }
    if (snippet.category == 'git') {
      return (Icons.account_tree_outlined, AppColors.cyan);
    }
    if (snippet.category == 'build') {
      return (Icons.science_outlined, AppColors.statusAdded);
    }
    if (snippet.category == 'agent') {
      return (Icons.auto_awesome_rounded, AppColors.secondary);
    }
    return (Icons.play_arrow_rounded, AppColors.textSecondary);
  }

  Future<void> _showSnippetContextMenu(
    BuildContext context,
    Offset position,
    QuickSnippetModel snippet,
  ) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: AppColors.surfaceElevated,
      items: [
        PopupMenuItem<String>(
          value: 'run_active',
          child: Row(
            children: [
              const Icon(Icons.play_arrow_rounded, size: 16, color: AppColors.statusAdded),
              const SizedBox(width: 8),
              Text('Executar "${snippet.command}" na aba atual', style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'run_new_tab',
          child: Row(
            children: [
              const Icon(Icons.add_to_queue_rounded, size: 16, color: AppColors.cyan),
              const SizedBox(width: 8),
              Text('Abrir "${snippet.title}" em nova aba dedicada', style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 16, color: AppColors.primary),
              SizedBox(width: 8),
              Text('Editar atalho...', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 16, color: AppColors.statusDeleted),
              SizedBox(width: 8),
              Text('Remover atalho', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ],
    );

    if (!context.mounted || selected == null) return;

    switch (selected) {
      case 'run_active':
        tabsManager.sendCommandToActiveTab(snippet.command);
      case 'run_new_tab':
        tabsManager.createNewTab(
          customTitle: snippet.title,
          initialCommand: snippet.command,
        );
      case 'edit':
        _showSnippetFormDialog(context, existing: snippet);
      case 'delete':
        onDeleteSnippet(snippet.id);
    }
  }

  void _showManageSnippetsModal(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.bolt_rounded, color: AppColors.secondary, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Gerenciar Atalhos de Agentes & Comandos',
                    style: TextStyle(fontSize: 15, color: AppColors.textPrimary),
                  ),
                ],
              ),
              if (onResetDefaultSnippets != null)
                TextButton.icon(
                  onPressed: () {
                    onResetDefaultSnippets!();
                    Navigator.of(ctx).pop();
                  },
                  icon: const Icon(Icons.restore_rounded, size: 15, color: AppColors.statusModified),
                  label: const Text(
                    'Restaurar Padrões',
                    style: TextStyle(fontSize: 11.5, color: AppColors.statusModified),
                  ),
                ),
            ],
          ),
          content: SizedBox(
            width: 520,
            height: 360,
            child: ListView.separated(
              itemCount: snippets.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.border),
              itemBuilder: (_, idx) {
                final snippet = snippets[idx];
                final (iconData, accentColor) = _resolveSnippetStyle(snippet);
                return ListTile(
                  dense: true,
                  leading: Icon(iconData, color: accentColor, size: 18),
                  title: Text(
                    snippet.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    snippet.command,
                    style: const TextStyle(
                      fontFamily: AppTheme.monoFontFamily,
                      fontSize: 11.5,
                      color: AppColors.cyan,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Abrir em nova aba dedicada',
                        icon: const Icon(Icons.add_to_queue_rounded, size: 16, color: AppColors.cyan),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          tabsManager.createNewTab(
                            customTitle: snippet.title,
                            initialCommand: snippet.command,
                          );
                        },
                      ),
                      IconButton(
                        tooltip: 'Editar atalho',
                        icon: const Icon(Icons.edit_outlined, size: 16, color: AppColors.primary),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _showSnippetFormDialog(context, existing: snippet);
                        },
                      ),
                      IconButton(
                        tooltip: 'Remover',
                        icon: const Icon(Icons.delete_outline_rounded, size: 16, color: AppColors.statusDeleted),
                        onPressed: () {
                          onDeleteSnippet(snippet.id);
                          Navigator.of(ctx).pop();
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                _showSnippetFormDialog(context);
              },
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Adicionar Novo'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Fechar'),
            ),
          ],
        );
      },
    );
  }

  void _showCommandHistoryModal(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Row(
            children: [
              Icon(Icons.history_rounded, color: AppColors.primary, size: 20),
              SizedBox(width: 8),
              Text(
                'Histórico de Comandos (SQLite)',
                style: TextStyle(fontSize: 15, color: AppColors.textPrimary),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            height: 320,
            child: commandHistory.isEmpty
                ? const Center(
                    child: Text(
                      'Nenhum comando registrado neste workspace ainda.',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  )
                : ListView.separated(
                    itemCount: commandHistory.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: AppColors.border),
                    itemBuilder: (_, idx) {
                      final cmd = commandHistory[idx];
                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.chevron_right_rounded,
                          color: AppColors.cyan,
                          size: 18,
                        ),
                        title: Text(
                          cmd,
                          style: const TextStyle(
                            fontFamily: AppTheme.monoFontFamily,
                            fontSize: 12,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: 'Reexecutar no terminal',
                          icon: const Icon(
                            Icons.replay_rounded,
                            size: 16,
                            color: AppColors.primary,
                          ),
                          onPressed: () {
                            tabsManager.sendCommandToActiveTab(cmd);
                            Navigator.of(ctx).pop();
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Fechar'),
            ),
          ],
        );
      },
    );
  }

  void _showSnippetFormDialog(BuildContext context, {QuickSnippetModel? existing}) {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final cmdCtrl = TextEditingController(text: existing?.command ?? '');
    String category = existing?.category ?? 'agent';

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              title: Text(
                existing == null
                    ? 'Novo Atalho / Agente CLI'
                    : 'Editar Atalho "${existing.title}"',
                style: const TextStyle(fontSize: 15, color: AppColors.textPrimary),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Nome do Botão (ex: Antigravity, Codex CLI)',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: cmdCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Comando no Terminal (ex: agy, codex, claude)',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: category,
                      decoration: const InputDecoration(
                        labelText: 'Categoria',
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(value: 'agent', child: Text('Agente IA (CLI)')),
                        DropdownMenuItem(value: 'git', child: Text('Git')),
                        DropdownMenuItem(value: 'build', child: Text('Build / Test')),
                        DropdownMenuItem(value: 'custom', child: Text('Personalizado')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setModalState(() => category = val);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () {
                    final title = titleCtrl.text.trim();
                    final cmd = cmdCtrl.text.trim();
                    if (title.isNotEmpty && cmd.isNotEmpty) {
                      if (existing != null && onUpdateSnippet != null) {
                        onUpdateSnippet!(existing.id, title, cmd, category);
                      } else {
                        onAddSnippet(title, cmd, category);
                      }
                      Navigator.of(ctx).pop();
                    }
                  },
                  child: const Text('Salvar no SQLite'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
