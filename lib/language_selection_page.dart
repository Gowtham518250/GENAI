import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'language_provider.dart';

typedef LanguageSelectionContinue = Future<void> Function(
  String languageCode,
  BuildContext pageContext,
);

class LanguageSelectionPage extends StatefulWidget {
  const LanguageSelectionPage({
    super.key,
    required this.onContinue,
  });

  final LanguageSelectionContinue onContinue;

  @override
  State<LanguageSelectionPage> createState() => _LanguageSelectionPageState();
}

class _LanguageSelectionPageState extends State<LanguageSelectionPage> {
  String _selectedCode = 'en';
  bool _seededFromProvider = false;
  bool _saving = false;

  static const Map<String, Map<String, String>> _copy = {
    'en': {
      'title': 'Choose your language',
      'subtitle': 'Use Retail Mind in the language that feels easiest to you.',
      'hint': 'You can change this later in Settings.',
      'continue': 'Continue',
      'preview': 'Your app language',
    },
    'te': {
      'title': 'మీ భాషను ఎంచుకోండి',
      'subtitle': 'మీకు సులభంగా అనిపించే భాషలో రిటైల్ మైండ్‌ను ఉపయోగించండి.',
      'hint': 'దీనిని తర్వాత సెట్టింగ్స్‌లో మార్చవచ్చు.',
      'continue': 'కొనసాగించండి',
      'preview': 'మీ యాప్ భాష',
    },
    'hi': {
      'title': 'अपनी भाषा चुनें',
      'subtitle': 'रिटेल माइंड को अपनी पसंद की भाषा में इस्तेमाल करें।',
      'hint': 'आप इसे बाद में सेटिंग्स में बदल सकते हैं।',
      'continue': 'जारी रखें',
      'preview': 'आपकी ऐप भाषा',
    },
    'ta': {
      'title': 'உங்கள் மொழியைத் தேர்ந்தெடுக்கவும்',
      'subtitle': 'உங்களுக்கு எளிதான மொழியில் Retail Mind-ஐப் பயன்படுத்துங்கள்.',
      'hint': 'இதை பின்னர் அமைப்புகளில் மாற்றலாம்.',
      'continue': 'தொடரவும்',
      'preview': 'உங்கள் செயலி மொழி',
    },
    'kn': {
      'title': 'ನಿಮ್ಮ ಭಾಷೆಯನ್ನು ಆಯ್ಕೆಮಾಡಿ',
      'subtitle': 'ನಿಮಗೆ ಸುಲಭವಾದ ಭಾಷೆಯಲ್ಲಿ Retail Mind ಬಳಸಿ.',
      'hint': 'ನಂತರ ಸೆಟ್ಟಿಂಗ್‌ಗಳಲ್ಲಿ ಇದನ್ನು ಬದಲಾಯಿಸಬಹುದು.',
      'continue': 'ಮುಂದುವರಿಸಿ',
      'preview': 'ನಿಮ್ಮ ಆ್ಯಪ್ ಭಾಷೆ',
    },
    'ml': {
      'title': 'നിങ്ങളുടെ ഭാഷ തിരഞ്ഞെടുക്കുക',
      'subtitle': 'നിങ്ങൾക്ക് എളുപ്പമുള്ള ഭാഷയിൽ Retail Mind ഉപയോഗിക്കുക.',
      'hint': 'പിന്നീട് ക്രമീകരണങ്ങളിൽ ഇത് മാറ്റാം.',
      'continue': 'തുടരുക',
      'preview': 'നിങ്ങളുടെ ആപ്പ് ഭാഷ',
    },
    'mr': {
      'title': 'तुमची भाषा निवडा',
      'subtitle': 'तुम्हाला सोपी वाटणाऱ्या भाषेत Retail Mind वापरा.',
      'hint': 'हे तुम्ही नंतर सेटिंग्जमध्ये बदलू शकता.',
      'continue': 'पुढे चला',
      'preview': 'तुमच्या अॅपची भाषा',
    },
    'gu': {
      'title': 'તમારી ભાષા પસંદ કરો',
      'subtitle': 'તમને સરળ લાગે તેવી ભાષામાં Retail Mind વાપરો.',
      'hint': 'તમે આ પછી સેટિંગ્સમાં બદલી શકો છો.',
      'continue': 'આગળ વધો',
      'preview': 'તમારી એપની ભાષા',
    },
    'pa': {
      'title': 'ਆਪਣੀ ਭਾਸ਼ਾ ਚੁਣੋ',
      'subtitle': 'Retail Mind ਨੂੰ ਆਪਣੀ ਪਸੰਦ ਦੀ ਭਾਸ਼ਾ ਵਿੱਚ ਵਰਤੋ।',
      'hint': 'ਤੁਸੀਂ ਇਸਨੂੰ ਬਾਅਦ ਵਿੱਚ ਸੈਟਿੰਗਾਂ ਵਿੱਚ ਬਦਲ ਸਕਦੇ ਹੋ।',
      'continue': 'ਜਾਰੀ ਰੱਖੋ',
      'preview': 'ਤੁਹਾਡੀ ਐਪ ਦੀ ਭਾਸ਼ਾ',
    },
    'bn': {
      'title': 'আপনার ভাষা বেছে নিন',
      'subtitle': 'আপনার সুবিধার ভাষায় Retail Mind ব্যবহার করুন।',
      'hint': 'পরে সেটিংস থেকে এটি পরিবর্তন করতে পারবেন।',
      'continue': 'চালিয়ে যান',
      'preview': 'আপনার অ্যাপের ভাষা',
    },
  };

  Map<String, String> get _labels => _copy[_selectedCode] ?? _copy['en']!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seededFromProvider) return;
    final language = context.read<LanguageProvider>().locale.languageCode;
    if (LanguageProvider.languages.any((item) => item['code'] == language)) {
      _selectedCode = language;
    }
    _seededFromProvider = true;
  }

  Future<void> _continue() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onContinue(_selectedCode, context);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _selectedCode == 'te'
                ? 'భాషను సేవ్ చేయలేకపోయాం. మళ్లీ ప్రయత్నించండి.'
                : _selectedCode == 'hi'
                    ? 'भाषा सेव नहीं हुई। कृपया फिर से कोशिश करें।'
                    : 'Could not save your language. Please try again.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final selectedLanguage = LanguageProvider.languages.firstWhere(
      (language) => language['code'] == _selectedCode,
      orElse: () => LanguageProvider.languages.first,
    );

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF5F7FF), Color(0xFFE9F4FF), Color(0xFFF8FAFC)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      height: 68,
                      width: 68,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.primary.withValues(alpha: 0.2),
                            blurRadius: 22,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.storefront_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      'RETAIL MIND',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2.0,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _labels['title']!,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF172033),
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _labels['subtitle']!,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: const Color(0xFF5A6578),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _labels['hint']!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF6B7280),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0xFFE1E7F0)),
                      ),
                      child: Column(
                        children: LanguageProvider.languages.map((language) {
                          final code = language['code']!;
                          final isSelected = _selectedCode == code;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              color: isSelected
                                  ? const Color(0xFFEEF2FF)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: _saving
                                    ? null
                                    : () async {
                                        setState(() => _selectedCode = code);
                                        await context
                                            .read<LanguageProvider>()
                                            .setLanguage(code);
                                      },
                                child: Container(
                                  constraints: const BoxConstraints(minHeight: 60),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isSelected
                                          ? theme.colorScheme.primary
                                          : const Color(0xFFE8ECF2),
                                      width: isSelected ? 1.6 : 1,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? theme.colorScheme.primary
                                                  .withValues(alpha: 0.1)
                                              : const Color(0xFFF4F6FA),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Icon(
                                          Icons.translate_rounded,
                                          size: 20,
                                          color: isSelected
                                              ? theme.colorScheme.primary
                                              : const Color(0xFF657086),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              language['nativeName']!,
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                color: const Color(0xFF182236),
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              language['name']!,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                color: const Color(0xFF697589),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isSelected)
                                        Icon(
                                          Icons.check_circle_rounded,
                                          color: theme.colorScheme.primary,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Icon(Icons.language_rounded,
                            color: Color(0xFF697589), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _labels['preview']! + ': ' +
                                (selectedLanguage['nativeName'] ?? ''),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF5A6578),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      height: 54,
                      child: FilledButton(
                        onPressed: _saving ? null : _continue,
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: _saving
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                _labels['continue']!,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Center(
                      child: Text(
                        width < 360
                            ? 'EN · TE · HI · TA · KN · ML · MR · GU · PA · BN'
                            : 'English · తెలుగు · हिन्दी · தமிழ் · ಕನ್ನಡ · മലയാളം · मराठी · ગુજરાતી · ਪੰਜਾਬੀ · বাংলা',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: const Color(0xFF8A94A6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
