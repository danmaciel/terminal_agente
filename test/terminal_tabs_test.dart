import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agente/core/theme/app_theme.dart';
import 'package:terminal_agente/services/database_service.dart';
import 'package:terminal_agente/services/terminal_session_controller.dart';
import 'package:terminal_agente/widgets/terminal_panel_widget.dart';

void main() {
  testWidgets(
      'TerminalTabsManager manages multiple tabs, logs commands to SQLite, and renders TerminalPanelWidget',
      (WidgetTester tester) async {
    final db = DatabaseService();
    await db.init(inMemory: true);
    final ws = db.upsertWorkspace('/tmp/term_ws', isGitRepo: false);

    int commandCallbacks = 0;
    final manager = TerminalTabsManager(
      databaseService: db,
      simulatePty: true,
      onCommandExecuted: () => commandCallbacks++,
    );

    manager.bindWorkspace(
      workspaceId: ws.id,
      workingDirectory: ws.rootPath,
    );
    expect(manager.tabs.length, 1);

    // Create a second tab
    manager.createNewTab(customTitle: 'Agente IA #2');
    expect(manager.tabs.length, 2);
    expect(manager.activeTabIndex, 1);
    expect(manager.activeTab?.title, 'Agente IA #2');

    // Render TerminalPanelWidget
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: TerminalPanelWidget(
              tabsManager: manager,
              snippets: db.getQuickSnippets(),
              commandHistory: db.getCommandHistory(ws.id),
              onAddSnippet: (title, cmd, cat) {
                db.addQuickSnippet(title: title, command: cmd, category: cat);
              },
              onDeleteSnippet: db.deleteQuickSnippet,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Agente IA #2'), findsOneWidget);
    expect(find.text('Antigravity'), findsOneWidget);
    expect(find.text('Codex CLI'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);

    // Click 'Antigravity' and 'Codex CLI' quick snippet chips to inject commands
    await tester.tap(find.text('Antigravity'));
    await tester.pump();
    await tester.tap(find.text('Codex CLI'));
    await tester.pump();

    expect(commandCallbacks, 2);
    expect(db.getCommandHistory(ws.id), containsAll(['agy', 'codex']));

    // Close second tab and verify fallback to first tab
    manager.closeTab(1);
    expect(manager.tabs.length, 1);
    expect(manager.activeTabIndex, 0);

    manager.dispose();
    db.dispose();
  });
}
