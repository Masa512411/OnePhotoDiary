import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AppThemeMode { system, light, dark }

class SettingsState {
  final AppThemeMode themeMode;

  const SettingsState({this.themeMode = AppThemeMode.system});

  SettingsState copyWith({AppThemeMode? themeMode}) =>
      SettingsState(themeMode: themeMode ?? this.themeMode);

  ThemeMode get flutterThemeMode {
    switch (themeMode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }
}

class SettingsNotifier extends Notifier<SettingsState> {
  static const _themeModeKey = 'settings_theme_mode';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  SettingsState build() {
    _load();
    return const SettingsState();
  }

  Future<void> _load() async {
    final value = await _storage.read(key: _themeModeKey);
    if (value == null) return;
    final mode = AppThemeMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AppThemeMode.system,
    );
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    await _storage.write(key: _themeModeKey, value: mode.name);
    state = state.copyWith(themeMode: mode);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, SettingsState>(
  () => SettingsNotifier(),
);
