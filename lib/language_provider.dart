import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LanguageProvider extends ChangeNotifier {
  Locale _locale = const Locale('en');

  Locale get locale => _locale;

  LanguageProvider() {
    _loadSavedLanguage();
  }

  Future<void> _loadSavedLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final languageCode = prefs.getString('language_code') ?? 'en';
    _locale = Locale(languageCode);
    notifyListeners();
  }

  Future<void> setLanguage(String languageCode) async {
    _locale = Locale(languageCode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language_code', languageCode);
    notifyListeners();
  }

  // Keep the app-wide language selector aligned with the voice/payment
  // engines, which already support these ten Indian locales.
  static const List<Map<String, String>> languages = [
    {'code': 'en', 'name': 'English', 'nativeName': 'English'},
    {'code': 'te', 'name': 'Telugu', 'nativeName': 'తెలుగు'},
    {'code': 'hi', 'name': 'Hindi', 'nativeName': 'हिन्दी'},
    {'code': 'ta', 'name': 'Tamil', 'nativeName': 'தமிழ்'},
    {'code': 'kn', 'name': 'Kannada', 'nativeName': 'ಕನ್ನಡ'},
    {'code': 'ml', 'name': 'Malayalam', 'nativeName': 'മലയാളം'},
    {'code': 'mr', 'name': 'Marathi', 'nativeName': 'मराठी'},
    {'code': 'gu', 'name': 'Gujarati', 'nativeName': 'ગુજરાતી'},
    {'code': 'bn', 'name': 'Bengali', 'nativeName': 'বাংলা'},
    {'code': 'pa', 'name': 'Punjabi', 'nativeName': 'ਪੰਜਾਬੀ'},
  ];
}
