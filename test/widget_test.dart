import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:terminal_agente/main.dart';
import 'package:terminal_agente/services/database_service.dart';

void main() {
  testWidgets(
      'TerminalAgenteApp renders 3 columns, displays file diff (Split/Unified), and supports rollback',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));

    final db = DatabaseService();
    await db.init(inMemory: true);

    final tempDir = Directory.systemTemp.createTempSync('terminal_agente_ui_');
    try {
      final nestedDir = Directory(p.join(tempDir.path, 'src', 'features'))
        ..createSync(recursive: true);
      final sampleFile = File(p.join(nestedDir.path, 'hello.dart'));
      sampleFile.writeAsStringSync('void main() {\n  print("Antes");\n}\n');

      await tester.pumpWidget(
        ProviderScope(
          child: TerminalAgenteApp(
            overrideDb: db,
            simulateTerminal: true,
            initialWorkspacePath: tempDir.path,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Terminal Agente'), findsOneWidget);
      expect(find.text('Alterados (0)'), findsOneWidget);

      // Modify sampleFile on disk and click Refresh button
      sampleFile.writeAsStringSync('void main() {\n  print("Depois!");\n}\n');
      await tester.tap(find.byTooltip('Atualizar detecção de arquivos'));
      await tester.pumpAndSettle();

      expect(find.text('Alterados (1)'), findsOneWidget);
      // Verify Directory Tree shows 'src', 'features', and 'hello.dart'
      expect(find.text('src'), findsOneWidget);
      expect(find.text('features'), findsOneWidget);
      expect(find.text('hello.dart'), findsWidgets);

      // Collapse 'src' directory and verify 'features' is hidden
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      expect(find.text('features'), findsNothing);

      // Expand 'src' directory again
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      expect(find.text('features'), findsOneWidget);

      expect(find.text('COMO ESTAVA (ANTES / BASELINE)'), findsOneWidget);
      expect(find.text('COMO FICOU (AGORA / ALTERADO)'), findsOneWidget);

      // Switch to Unified view mode
      await tester.tap(find.text('Unificado'));
      await tester.pumpAndSettle();
      expect(find.text('COMO ESTAVA (ANTES / BASELINE)'), findsNothing);

      // Click '@ Referenciar' on the hunk header to activate contextual reference bar
      await tester.tap(find.text('@ Referenciar').first);
      await tester.pumpAndSettle();
      expect(find.text('@src/features/hello.dart#L2'), findsOneWidget);

      // Click 'Inserir @ no Terminal' to inject the reference into the active terminal
      await tester.tap(find.text('Inserir @ no Terminal'));
      await tester.pumpAndSettle();

      // Switch to Editor mode, edit content and save
      await tester.tap(find.text('Editor'));
      await tester.pumpAndSettle();
      expect(find.text('Salvar (Ctrl+S)'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('code_editor_text_field')),
        'void main() {\n  print("Editado no Editor!");\n}\n',
      );
      await tester.pumpAndSettle();
      expect(find.text('Editor ●'), findsOneWidget);

      await tester.tap(find.text('Salvar (Ctrl+S)'));
      await tester.pumpAndSettle();
      expect(
        sampleFile.readAsStringSync(),
        'void main() {\n  print("Editado no Editor!");\n}\n',
      );

      // Switch back to Unified view and click 'Reverter este bloco' to rollback the hunk
      await tester.tap(find.text('Unificado'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reverter este bloco'));
      await tester.pumpAndSettle();

      expect(sampleFile.readAsStringSync(), 'void main() {\n  print("Antes");\n}\n');
      expect(find.text('Alterados (0)'), findsOneWidget);
    } finally {
      db.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
      await tester.binding.setSurfaceSize(null);
    }
  });
}
