import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:xterm/xterm.dart';
import 'database_service.dart';

class TerminalTabInstance {
  final int sessionId;
  String title;
  final String shellExecutable;
  final String workingDirectory;
  final Terminal terminal;
  final TerminalController viewController;
  Pty? pty;
  StreamSubscription<Uint8List>? _outputSub;
  final StringBuffer _inputLineBuffer = StringBuffer();
  final StringBuffer _pendingLogBuffer = StringBuffer();
  Timer? _logFlushTimer;
  bool isExited = false;
  int? exitCode;

  TerminalTabInstance({
    required this.sessionId,
    required this.title,
    required this.shellExecutable,
    required this.workingDirectory,
    required this.terminal,
    required this.viewController,
    this.pty,
  });

  void dispose(DatabaseService db) {
    _logFlushTimer?.cancel();
    if (_pendingLogBuffer.isNotEmpty) {
      db.appendTerminalLog(sessionId, _pendingLogBuffer.toString());
      _pendingLogBuffer.clear();
    }
    _outputSub?.cancel();
    viewController.dispose();
    try {
      pty?.kill();
    } catch (_) {}
  }
}

class TerminalTabsManager extends ChangeNotifier {
  final DatabaseService databaseService;
  final VoidCallback? onCommandExecuted;
  final bool simulatePty;

  final List<TerminalTabInstance> _tabs = [];
  int _activeTabIndex = 0;
  int _tabCounter = 1;
  int? _currentWorkspaceId;
  String? _currentWorkingDirectory;

  TerminalTabsManager({
    required this.databaseService,
    this.onCommandExecuted,
    this.simulatePty = false,
  });

  List<TerminalTabInstance> get tabs => List.unmodifiable(_tabs);
  int get activeTabIndex => _activeTabIndex;
  TerminalTabInstance? get activeTab =>
      (_tabs.isNotEmpty && _activeTabIndex >= 0 && _activeTabIndex < _tabs.length)
          ? _tabs[_activeTabIndex]
          : null;

  void bindWorkspace({
    required int workspaceId,
    required String workingDirectory,
  }) {
    if (_currentWorkspaceId == workspaceId && _tabs.isNotEmpty) {
      return;
    }

    _disposeAllTabs();
    _currentWorkspaceId = workspaceId;
    _currentWorkingDirectory = workingDirectory;
    _tabCounter = 1;

    createNewTab();
  }

  TerminalTabInstance? createNewTab({String? customTitle, String? initialCommand}) {
    final wsId = _currentWorkspaceId;
    final workDir = _currentWorkingDirectory;
    if (wsId == null || workDir == null) return null;

    final shell = resolveDefaultShell();
    final shellName = p.basename(shell);
    final tabTitle = customTitle ?? '$shellName #${_tabCounter++}';

    final sessionRecord = databaseService.createTerminalSession(
      workspaceId: wsId,
      title: tabTitle,
      shellExecutable: shell,
    );

    final terminal = Terminal(maxLines: 10000);
    final viewController = TerminalController();

    final tab = TerminalTabInstance(
      sessionId: sessionRecord.id,
      title: tabTitle,
      shellExecutable: shell,
      workingDirectory: workDir,
      terminal: terminal,
      viewController: viewController,
    );

    if (simulatePty) {
      _setupSimulatedTerminal(tab);
    } else {
      _startNativePty(tab);
    }

    _tabs.add(tab);
    _activeTabIndex = _tabs.length - 1;
    notifyListeners();

    if (initialCommand != null && initialCommand.trim().isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 250), () {
        sendCommandToTab(tab, initialCommand);
      });
    }

    return tab;
  }

  void selectTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _activeTabIndex = index;
    notifyListeners();
  }

  void closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final removed = _tabs.removeAt(index);
    removed.dispose(databaseService);

    if (_tabs.isEmpty && _currentWorkspaceId != null && _currentWorkingDirectory != null) {
      createNewTab();
      return;
    }

    if (_activeTabIndex >= _tabs.length) {
      _activeTabIndex = _tabs.length - 1;
    }
    notifyListeners();
  }

  void sendCommandToActiveTab(String command, {bool execute = true}) {
    final tab = activeTab;
    if (tab == null) return;
    sendCommandToTab(tab, command, execute: execute);
  }

  void sendCommandToTab(
    TerminalTabInstance tab,
    String command, {
    bool execute = true,
  }) {
    final payload = execute ? '$command\r' : command;
    if (simulatePty || tab.pty == null) {
      tab.terminal.write(execute ? '$command\r\n' : command);
      if (execute) {
        databaseService.recordCommand(tab.sessionId, command);
        databaseService.appendTerminalLog(tab.sessionId, '$command\n');
        onCommandExecuted?.call();
      } else {
        tab._inputLineBuffer.write(command);
        databaseService.appendTerminalLog(tab.sessionId, command);
      }
      return;
    }

    final bytes = utf8.encode(payload);
    tab.pty!.write(Uint8List.fromList(bytes));
    if (execute) {
      databaseService.recordCommand(tab.sessionId, command);
      Future.delayed(const Duration(milliseconds: 450), () {
        onCommandExecuted?.call();
      });
    }
  }

  void clearActiveTerminal() {
    final tab = activeTab;
    if (tab == null) return;
    sendCommandToTab(tab, 'clear', execute: true);
  }

  void _startNativePty(TerminalTabInstance tab) {
    try {
      final pty = Pty.start(
        tab.shellExecutable,
        workingDirectory: tab.workingDirectory,
        environment: {
          ...Platform.environment,
          'TERM': 'xterm-256color',
        },
        rows: tab.terminal.viewHeight > 0 ? tab.terminal.viewHeight : 28,
        columns: tab.terminal.viewWidth > 0 ? tab.terminal.viewWidth : 100,
      );
      tab.pty = pty;

      tab._outputSub = pty.output.listen((Uint8List data) {
        final decoded = utf8.decode(data, allowMalformed: true);
        tab.terminal.write(decoded);
        _queueLogChunk(tab, decoded);
      });

      pty.exitCode.then((code) {
        tab.isExited = true;
        tab.exitCode = code;
        tab.terminal.write('\r\n\x1b[33m[Processo finalizado com código $code]\x1b[0m\r\n');
        notifyListeners();
      });

      tab.terminal.onOutput = (String input) {
        pty.write(Uint8List.fromList(utf8.encode(input)));
        _handleUserInputTracking(tab, input);
      };

      tab.terminal.onResize = (int width, int height, int pixelWidth, int pixelHeight) {
        pty.resize(height, width);
      };
    } catch (e) {
      // Fallback to simulated shell if PTY creation fails in restricted environment
      tab.terminal.write('\x1b[31m[Aviso PTY: $e — modo simulado ativado]\x1b[0m\r\n');
      _setupSimulatedTerminal(tab);
    }
  }

  void _setupSimulatedTerminal(TerminalTabInstance tab) {
    tab.terminal.write(
      '\x1b[36mTerminal Agente (${tab.title}) — Diretório: ${tab.workingDirectory}\x1b[0m\r\n\$ ',
    );
    tab.terminal.onOutput = (String input) {
      if (input == '\r' || input == '\n') {
        final cmd = tab._inputLineBuffer.toString().trim();
        tab._inputLineBuffer.clear();
        tab.terminal.write('\r\n');
        if (cmd.isNotEmpty) {
          databaseService.recordCommand(tab.sessionId, cmd);
          databaseService.appendTerminalLog(tab.sessionId, '\$ $cmd\n');
          onCommandExecuted?.call();
        }
        tab.terminal.write('\$ ');
      } else if (input == '\x7f' || input == '\b') {
        final current = tab._inputLineBuffer.toString();
        if (current.isNotEmpty) {
          tab._inputLineBuffer.clear();
          tab._inputLineBuffer.write(current.substring(0, current.length - 1));
          tab.terminal.write('\b \b');
        }
      } else {
        tab._inputLineBuffer.write(input);
        tab.terminal.write(input);
      }
    };
  }

  void _handleUserInputTracking(TerminalTabInstance tab, String input) {
    for (int i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '\r' || ch == '\n') {
        final cmd = tab._inputLineBuffer.toString().trim();
        tab._inputLineBuffer.clear();
        if (cmd.isNotEmpty) {
          databaseService.recordCommand(tab.sessionId, cmd);
        }
        Future.delayed(const Duration(milliseconds: 450), () {
          onCommandExecuted?.call();
        });
      } else if (ch == '\x7f' || ch == '\b') {
        final str = tab._inputLineBuffer.toString();
        if (str.isNotEmpty) {
          tab._inputLineBuffer.clear();
          tab._inputLineBuffer.write(str.substring(0, str.length - 1));
        }
      } else if (ch.codeUnitAt(0) >= 32) {
        tab._inputLineBuffer.write(ch);
      }
    }
  }

  void _queueLogChunk(TerminalTabInstance tab, String text) {
    tab._pendingLogBuffer.write(text);
    tab._logFlushTimer ??= Timer(const Duration(milliseconds: 600), () {
      tab._logFlushTimer = null;
      if (tab._pendingLogBuffer.isNotEmpty) {
        databaseService.appendTerminalLog(
          tab.sessionId,
          tab._pendingLogBuffer.toString(),
        );
        tab._pendingLogBuffer.clear();
      }
    });
  }

  static String resolveDefaultShell() {
    if (Platform.isWindows) {
      return Platform.environment['COMSPEC'] ?? 'powershell.exe';
    }
    final envShell = Platform.environment['SHELL'];
    if (envShell != null && envShell.isNotEmpty && File(envShell).existsSync()) {
      return envShell;
    }
    for (final candidate in ['/bin/bash', '/usr/bin/bash', '/bin/zsh', '/bin/sh']) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return 'sh';
  }

  void _disposeAllTabs() {
    for (final tab in _tabs) {
      tab.dispose(databaseService);
    }
    _tabs.clear();
    _activeTabIndex = 0;
  }

  @override
  void dispose() {
    _disposeAllTabs();
    super.dispose();
  }
}
