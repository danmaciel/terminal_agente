import 'package:flutter/material.dart';

class AppColors {
  // Base IDE Dark Palette (Tokyo Night / Catppuccin Mocha inspired)
  static const Color background = Color(0xFF0F111A);
  static const Color surface = Color(0xFF161925);
  static const Color surfaceElevated = Color(0xFF1E2233);
  static const Color panelHeader = Color(0xFF131620);
  static const Color border = Color(0xFF282E44);

  // Accent Colors
  static const Color primary = Color(0xFF7AA2F7);
  static const Color secondary = Color(0xFFBB9AF7);
  static const Color cyan = Color(0xFF7DCFFF);

  // Text Colors
  static const Color textPrimary = Color(0xFFC0CAF5);
  static const Color textSecondary = Color(0xFF9AA5CE);
  static const Color textMuted = Color(0xFF565F89);

  // Diff & File Status Semantic Colors
  static const Color diffAddedBg = Color(0x262EA043);
  static const Color diffAddedHighlight = Color(0x592EA043);
  static const Color diffAddedText = Color(0xFF73DACA);

  static const Color diffRemovedBg = Color(0x26F85149);
  static const Color diffRemovedHighlight = Color(0x59F85149);
  static const Color diffRemovedText = Color(0xFFF7768E);

  static const Color statusModified = Color(0xFFE0AF68);
  static const Color statusAdded = Color(0xFF9ECE6A);
  static const Color statusDeleted = Color(0xFFF7768E);
  static const Color statusUntracked = Color(0xFF7DCFFF);
}

class AppTheme {
  static const String monoFontFamily = 'monospace';

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        secondary: AppColors.secondary,
        surface: AppColors.surface,
        error: AppColors.statusDeleted,
        onPrimary: Color(0xFF0F111A),
        onSecondary: Color(0xFF0F111A),
        onSurface: AppColors.textPrimary,
      ),
      dividerColor: AppColors.border,
      cardColor: AppColors.surface,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.panelHeader,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      iconTheme: const IconThemeData(
        color: AppColors.textSecondary,
        size: 18,
      ),
      textTheme: const TextTheme(
        titleMedium: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        bodyMedium: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 13,
        ),
        bodySmall: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        textStyle: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 12,
        ),
      ),
    );
  }
}
