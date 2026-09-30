/// Shared multilingual voice-billing normalization.
///
/// Speech recognition can return native Indic script, English words, or
/// Romanized Indian speech. This layer only normalizes deterministic tokens;
/// product selection still happens against the shop's own catalog.
class MultilingualVoiceLexicon {
  static const Map<String, Map<String, String>> _numbers = {
    'te': {
      'సున్నా': '0', 'ఒకటి': '1', 'ఒక్కటి': '1', 'రెండు': '2', 'మూడు': '3',
      'నాలుగు': '4', 'ఐదు': '5', 'ఆరు': '6', 'ఏడు': '7', 'ఎనిమిది': '8',
      'తొమ్మిది': '9', 'పది': '10', 'పదకొండు': '11', 'పన్నెండు': '12',
      'ఇరవై': '20', 'ముప్పై': '30', 'నలభై': '40', 'యాభై': '50',
      'వంద': '100', 'వెయ్యి': '1000', 'అర': '0.5',
    },
    'hi': {
      'शून्य': '0', 'एक': '1', 'दो': '2', 'तीन': '3', 'चार': '4',
      'पांच': '5', 'पाँच': '5', 'छह': '6', 'छः': '6', 'सात': '7',
      'आठ': '8', 'नौ': '9', 'दस': '10', 'ग्यारह': '11', 'बारह': '12',
      'बीस': '20', 'तीस': '30', 'चालीस': '40', 'पचास': '50',
      'सौ': '100', 'हज़ार': '1000', 'हजार': '1000', 'आधा': '0.5',
    },
    'ta': {
      'பூஜ்ஜியம்': '0', 'ஒன்று': '1', 'இரண்டு': '2', 'மூன்று': '3',
      'நான்கு': '4', 'ஐந்து': '5', 'ஆறு': '6', 'ஏழு': '7', 'எட்டு': '8',
      'ஒன்பது': '9', 'பத்து': '10', 'இருபது': '20', 'முப்பது': '30',
      'நாற்பது': '40', 'ஐம்பது': '50', 'நூறு': '100', 'ஆயிரம்': '1000',
      'அரை': '0.5',
    },
    'kn': {
      'ಸೊನ್ನೆ': '0', 'ಒಂದು': '1', 'ಎರಡು': '2', 'ಮೂರು': '3', 'ನಾಲ್ಕು': '4',
      'ಐದು': '5', 'ಆರು': '6', 'ಏಳು': '7', 'ಎಂಟು': '8', 'ಒಂಬತ್ತು': '9',
      'ಹತ್ತು': '10', 'ಇಪ್ಪತ್ತು': '20', 'ಮೂವತ್ತು': '30', 'ನಲವತ್ತು': '40',
      'ಐವತ್ತು': '50', 'ನೂರು': '100', 'ಸಾವಿರ': '1000', 'ಅರ್ಧ': '0.5',
    },
    'ml': {
      'പൂജ്യം': '0', 'ഒന്ന്': '1', 'രണ്ട്': '2', 'മൂന്ന്': '3', 'നാല്': '4',
      'അഞ്ച്': '5', 'ആറ്': '6', 'ഏഴ്': '7', 'എട്ട്': '8', 'ഒമ്പത്': '9',
      'പത്ത്': '10', 'ഇരുപത്': '20', 'മുപ്പത്': '30', 'നാൽപ്പത്': '40',
      'അമ്പത്': '50', 'നൂറ്': '100', 'ആയിരം': '1000', 'പകുതി': '0.5',
    },
    'mr': {
      'शून्य': '0', 'एक': '1', 'दोन': '2', 'तीन': '3', 'चार': '4', 'पाच': '5',
      'सहा': '6', 'सात': '7', 'आठ': '8', 'नऊ': '9', 'दहा': '10',
      'वीस': '20', 'तीस': '30', 'चाळीस': '40', 'पन्नास': '50',
      'शंभर': '100', 'हजार': '1000', 'अर्धा': '0.5',
    },
  };

  static String normalizeNumbers(String input, {String locale = 'en-US'}) {
    var out = input.toLowerCase();
    final lang = locale.split(RegExp(r'[-_]')).first;
    final entries = <MapEntry<String, String>>[
      ...?_numbers[lang]?.entries.toList(),
    ]..sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final item in entries) {
      out = out.replaceAll(
        RegExp('(?<!\\S)\${RegExp.escape(item.key)}(?!\\S)'),
        item.value,
      );
    }

    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> productAliases(Map<String, dynamic> product) {
    final values = <String>[];
    for (final key in const ['aliases', 'voice_aliases', 'synonyms', 'voiceAliases']) {
      final raw = product[key];
      if (raw is List) {
        values.addAll(raw.map((e) => e.toString()));
      } else if (raw is String && raw.trim().isNotEmpty) {
        values.addAll(raw.split(RegExp(r'[,|;]')));
      }
    }
    return values
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
  }
}
