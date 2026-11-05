enum FileChangeStatus {
  added,
  modified,
  deleted,
  untracked,
}

enum DiffViewMode {
  split,
  unified,
  editor,
}

class CodeSelectionReference {
  final String relativePath;
  final int startLine;
  final int endLine;
  final String selectedText;

  const CodeSelectionReference({
    required this.relativePath,
    required this.startLine,
    required this.endLine,
    required this.selectedText,
  });

  String get referenceToken => startLine == endLine
      ? '@$relativePath#L$startLine'
      : '@$relativePath#L$startLine-L$endLine';

  String get lineLabel =>
      startLine == endLine ? 'linha $startLine' : 'linhas $startLine a $endLine';

  String formatPrompt(String userInstruction) {
    final trimmed = userInstruction.trim();
    if (trimmed.contains(referenceToken)) {
      return trimmed;
    }
    return '$trimmed (referência: $referenceToken — $lineLabel)';
  }
}

class WorkspaceModel {
  final int id;
  final String name;
  final String rootPath;
  final bool isGitRepo;
  final DateTime lastOpenedAt;

  const WorkspaceModel({
    required this.id,
    required this.name,
    required this.rootPath,
    required this.isGitRepo,
    required this.lastOpenedAt,
  });

  WorkspaceModel copyWith({
    int? id,
    String? name,
    String? rootPath,
    bool? isGitRepo,
    DateTime? lastOpenedAt,
  }) {
    return WorkspaceModel(
      id: id ?? this.id,
      name: name ?? this.name,
      rootPath: rootPath ?? this.rootPath,
      isGitRepo: isGitRepo ?? this.isGitRepo,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    );
  }
}

class TrackedFileChange {
  final String relativePath;
  final FileChangeStatus status;
  final String beforeContent;
  final String afterContent;
  final String? beforeHash;
  final String? afterHash;
  final int addedLines;
  final int removedLines;
  final DateTime updatedAt;

  const TrackedFileChange({
    required this.relativePath,
    required this.status,
    required this.beforeContent,
    required this.afterContent,
    this.beforeHash,
    this.afterHash,
    required this.addedLines,
    required this.removedLines,
    required this.updatedAt,
  });
}

class SnapshotModel {
  final int id;
  final int workspaceId;
  final String label;
  final String triggerType; // 'initial', 'watcher', 'manual', 'command'
  final DateTime createdAt;
  final int filesCount;

  const SnapshotModel({
    required this.id,
    required this.workspaceId,
    required this.label,
    required this.triggerType,
    required this.createdAt,
    this.filesCount = 0,
  });
}

class SnapshotFileEntry {
  final int id;
  final int snapshotId;
  final String relativePath;
  final FileChangeStatus status;
  final String beforeContent;
  final String afterContent;

  const SnapshotFileEntry({
    required this.id,
    required this.snapshotId,
    required this.relativePath,
    required this.status,
    required this.beforeContent,
    required this.afterContent,
  });
}

class QuickSnippetModel {
  final int id;
  final String title;
  final String command;
  final String category;
  final String iconName;

  const QuickSnippetModel({
    required this.id,
    required this.title,
    required this.command,
    required this.category,
    required this.iconName,
  });
}

class TerminalSessionRecord {
  final int id;
  final int workspaceId;
  final String title;
  final String shellExecutable;
  final DateTime createdAt;

  const TerminalSessionRecord({
    required this.id,
    required this.workspaceId,
    required this.title,
    required this.shellExecutable,
    required this.createdAt,
  });
}
