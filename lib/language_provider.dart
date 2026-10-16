import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LanguageProvider extends ChangeNotifier {
  Locale _locale = const Locale('en');

  Locale get locale => _locale;

  int _selectionVersion = 0;
  late final Future<void> initialized;

  LanguageProvider() {
    initialized = _loadSavedLanguage();
  }

  static String _preferenceKeyFor(SharedPreferences prefs) {
    final role = (prefs.getString('user_role') ??
            prefs.getString('user_type') ??
            prefs.getString('role') ??
            '')
        .trim()
        .toUpperCase();

    // Customer sessions sometimes keep their ID in customer_id while owner
    // sessions use user_id/userId. Include the role to prevent collisions.
    final rawId = role == 'CUSTOMER'
        ? (prefs.get('customer_id') ?? prefs.get('user_id') ?? prefs.get('userId'))
        : (prefs.get('user_id') ?? prefs.get('userId'));
    final userId = int.tryParse(rawId?.toString() ?? '') ?? 0;
    if (userId > 0 && role.isNotEmpty) {
      return 'language_code_${role}_$userId';
    }
    // Before login there is no account identity yet, so keep a device-level
    // preference; it is copied into the account scope on the next app launch.
    return 'language_code';
  }

  static bool _isSupported(String languageCode) =>
      languages.any((language) => language['code'] == languageCode);

  Future<void> _loadSavedLanguage() async {
    final selectionVersionAtStart = _selectionVersion;
    final prefs = await SharedPreferences.getInstance();
    // If a user chooses a language while startup is loading preferences, the
    // explicit choice wins instead of being overwritten by this async read.
    if (selectionVersionAtStart != _selectionVersion) return;
    final key = _preferenceKeyFor(prefs);
    final saved = prefs.getString(key) ?? prefs.getString('language_code') ?? 'en';
    final languageCode = _isSupported(saved) ? saved : 'en';
    _locale = Locale(languageCode);

    if (key != 'language_code' && prefs.getString(key) == null) {
      await prefs.setString(key, languageCode);
    }
    notifyListeners();
  }

  Future<void> setLanguage(String languageCode) async {
    _selectionVersion++;
    final safeCode = _isSupported(languageCode) ? languageCode : 'en';
    _locale = Locale(safeCode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language_code', safeCode);
    final scopedKey = _preferenceKeyFor(prefs);
    if (scopedKey != 'language_code') {
      await prefs.setString(scopedKey, safeCode);
    }
    notifyListeners();
  }

  /// Copy the currently selected device/login language to the newly
  /// authenticated account after login or registration has saved its role/ID.
  /// This prevents the next account on a shared device inheriting the previous
  /// account's language choice.
  static Future<void> persistCurrentLanguageForAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final scopedKey = _preferenceKeyFor(prefs);
    if (scopedKey == 'language_code') return;

    final selected = prefs.getString('language_code') ?? 'en';
    final safeCode = _isSupported(selected) ? selected : 'en';
    await prefs.setString(scopedKey, safeCode);
  }

  /// Locale registry shared by the UI and voice stack.
  /// The UI can safely load any of these locales; untranslated keys fall back
  /// to the English getter defaults in AppLocalizations.
  static const List<Map<String, String>> languages = [
    {'code': 'en', 'name': 'English', 'nativeName': 'English'},
    {'code': 'te', 'name': 'Telugu', 'nativeName': 'తెలుగు'},
    {'code': 'hi', 'name': 'Hindi', 'nativeName': 'हिन्दी'},
    {'code': 'ta', 'name': 'Tamil', 'nativeName': 'தமிழ்'},
    {'code': 'kn', 'name': 'Kannada', 'nativeName': 'ಕನ್ನಡ'},
    {'code': 'ml', 'name': 'Malayalam', 'nativeName': 'മലയാളം'},
    {'code': 'mr', 'name': 'Marathi', 'nativeName': 'मराठी'},
    {'code': 'gu', 'name': 'Gujarati', 'nativeName': 'ગુજરાતી'},
    {'code': 'pa', 'name': 'Punjabi', 'nativeName': 'ਪੰਜਾਬੀ'},
    {'code': 'bn', 'name': 'Bengali', 'nativeName': 'বাংলা'},
  ];
}
