/// Speech options offered in Ask Retail Mind.
///
/// The ISO-like `code` values are passed unchanged to the self-hosted
/// Indic speech service; that service maps them to IndicConformer and
/// IndicTrans2 language identifiers. The 22 scheduled Indian languages are
/// included, plus English for convenience.
class VoiceLanguageOption {
  final String name;
  final String nativeName;
  final String code;

  const VoiceLanguageOption({
    required this.name,
    required this.nativeName,
    required this.code,
  });
}

const List<VoiceLanguageOption> kVoiceLanguages = [
  VoiceLanguageOption(name: 'Telugu', nativeName: 'తెలుగు', code: 'te'),
  VoiceLanguageOption(name: 'Hindi', nativeName: 'हिन्दी', code: 'hi'),
  VoiceLanguageOption(name: 'Tamil', nativeName: 'தமிழ்', code: 'ta'),
  VoiceLanguageOption(name: 'Kannada', nativeName: 'ಕನ್ನಡ', code: 'kn'),
  VoiceLanguageOption(name: 'Malayalam', nativeName: 'മലയാളം', code: 'ml'),
  VoiceLanguageOption(name: 'Bengali', nativeName: 'বাংলা', code: 'bn'),
  VoiceLanguageOption(name: 'Marathi', nativeName: 'मराठी', code: 'mr'),
  VoiceLanguageOption(name: 'Gujarati', nativeName: 'ગુજરાતી', code: 'gu'),
  VoiceLanguageOption(name: 'Punjabi', nativeName: 'ਪੰਜਾਬੀ', code: 'pa'),
  VoiceLanguageOption(name: 'Odia', nativeName: 'ଓଡ଼ିଆ', code: 'or'),
  VoiceLanguageOption(name: 'Assamese', nativeName: 'অসমীয়া', code: 'as'),
  VoiceLanguageOption(name: 'Bodo', nativeName: 'बड़ो', code: 'br'),
  VoiceLanguageOption(name: 'Dogri', nativeName: 'डोगरी', code: 'doi'),
  VoiceLanguageOption(name: 'Kashmiri', nativeName: 'کٲشُر', code: 'ks'),
  VoiceLanguageOption(name: 'Konkani', nativeName: 'कोंकणी', code: 'kok'),
  VoiceLanguageOption(name: 'Maithili', nativeName: 'मैथिली', code: 'mai'),
  VoiceLanguageOption(name: 'Manipuri (Meitei)', nativeName: 'মৈতৈলোন্', code: 'mni'),
  VoiceLanguageOption(name: 'Nepali', nativeName: 'नेपाली', code: 'ne'),
  VoiceLanguageOption(name: 'Sanskrit', nativeName: 'संस्कृतम्', code: 'sa'),
  VoiceLanguageOption(name: 'Santali', nativeName: 'ᱥᱟᱱᱛᱟᱲᱤ', code: 'sat'),
  VoiceLanguageOption(name: 'Sindhi', nativeName: 'سنڌي', code: 'sd'),
  VoiceLanguageOption(name: 'Urdu', nativeName: 'اردو', code: 'ur'),
  VoiceLanguageOption(name: 'English', nativeName: 'English', code: 'en'),
];
