import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Global Retail Mind appearance controller.
///
/// Modes:
/// - auto: light during the day and dark at night
/// - light: always light
/// - dark: always dark
///
/// Auto mode is the default so the app naturally changes its palette without
/// requiring the owner to touch a setting every day.
enum RetailThemeMode { auto, light, dark }

class AppThemeController extends ChangeNotifier {
  static const _preferenceKey = 'retail_mind_theme_mode';
  static const _dayStartHour = 7;
  static const _nightStartHour = 19;

  RetailThemeMode _mode = RetailThemeMode.auto;
  Timer? _clockTimer;

  AppThemeController() {
    unawaited(_load());
    _startClock();
  }

  RetailThemeMode get mode => _mode;

  /// Whether the current effective palette is dark.
  bool get isDark {
    switch (_mode) {
      case RetailThemeMode.dark:
        return true;
      case RetailThemeMode.light:
        return false;
      case RetailThemeMode.auto:
        final hour = DateTime.now().hour;
        return hour >= _nightStartHour || hour < _dayStartHour;
    }
  }

  ThemeMode get themeMode => isDark ? ThemeMode.dark : ThemeMode.light;

  String get modeLabel {
    switch (_mode) {
      case RetailThemeMode.auto:
        return 'Auto • Day / Night';
      case RetailThemeMode.light:
        return 'Light';
      case RetailThemeMode.dark:
        return 'Dark';
    }
  }

  IconData get modeIcon {
    switch (_mode) {
      case RetailThemeMode.auto:
        return Icons.wb_twilight_rounded;
      case RetailThemeMode.light:
        return Icons.light_mode_rounded;
      case RetailThemeMode.dark:
        return Icons.dark_mode_rounded;
    }
  }

  bool get isAuto => _mode == RetailThemeMode.auto;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_preferenceKey);

      switch (raw) {
        case 'light':
          _mode = RetailThemeMode.light;
          break;
        case 'dark':
          _mode = RetailThemeMode.dark;
          break;
        default:
          _mode = RetailThemeMode.auto;
      }

      notifyListeners();
    } catch (_) {
      // Keep the safe default: automatic day/night mode.
    }
  }

  void _startClock() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_mode == RetailThemeMode.auto) {
        notifyListeners();
      }
    });
  }

  Future<void> setMode(RetailThemeMode mode) async {
    if (_mode == mode) return;

    _mode = mode;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_preferenceKey, mode.name);
    } catch (_) {
      // Theme still changes for the current session even if persistence fails.
    }
  }

  Future<void> setAuto() => setMode(RetailThemeMode.auto);

  Future<void> setDark(bool enabled) =>
      setMode(enabled ? RetailThemeMode.dark : RetailThemeMode.light);

  Future<void> toggleManual() => setDark(!isDark);

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }
}
