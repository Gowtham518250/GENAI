// =============================================================================
// voice_billing_assistant.dart  —  V3 MULTI-LANGUAGE AI VOICE BILLING
// =============================================================================
// WHAT'S NEW vs V1:
//  • 10 Indian languages: English, Hindi, Tamil, Telugu, Kannada, Malayalam,
//    Marathi, Bengali, Gujarati, Punjabi
//  • Language-aware NLP parser: number words in each language
//  • Hinglish/mixed-language support (most real-world usage)
//  • Confidence score per parsed item (shows ⚠️ if low confidence)
//  • Inline item editing before confirming
//  • Auto-detect language from transcript
//  • Continuous listening mode (tap to stop vs auto-stop)
//  • Unit normalizer: "kilo" / "किलो" / "கிலோ" → "kg"
//  • Retry partial failures without re-recording
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'utils/free_translator_service.dart';

import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:google_fonts/google_fonts.dart';

import 'phonetic_normalizer.dart';
import 'voice_nlp_engine.dart';
import 'voice_feedback_learning_service.dart';
import 'language_detection_visualizer.dart';
import 'language_detector.dart';
import 'product_catalog_service.dart';
import 'production_voice_billing_service.dart';
import 'stt_accuracy_config.dart';

// ─── Language Config ──────────────────────────────────────────────────────────

class _LangConfig {
  final String code;       // BCP-47 locale for STT
  final String label;      // Display name
  final String flag;
  final Map<String, num> numberWords;  // Changed to num to support decimals (0.5, 1.5, etc)
  final List<String> unitWords;    // words meaning "kg / litre / piece"
  final List<String> priceWords;   // words meaning "rupees / price"
  final String separator;          // word that separates items in this language

  const _LangConfig({
    required this.code,
    required this.label,
    required this.flag,
    required this.numberWords,
    required this.unitWords,
    required this.priceWords,
    this.separator = ',',
  });
}

const _languages = <_LangConfig>[
  _LangConfig(
    code: 'en-IN', label: 'English', flag: '🇮🇳',
    numberWords: {
      'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
      'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10,
      'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14, 'fifteen': 15,
      'sixteen': 16, 'seventeen': 17, 'eighteen': 18, 'nineteen': 19,
      'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50, 'sixty': 60,
      'seventy': 70, 'eighty': 80, 'ninety': 90, 'hundred': 100, 'thousand': 1000,
      'half': 0.5, 'quarter': 0.25, 'third': 0.33, 'one-point-five': 1.5,
    },
    unitWords: ['kg', 'kilo', 'kilogram', 'kilograms', 'gm', 'gram', 'grams', 'litre', 
                'liter', 'ltr', 'ml', 'millilitre', 'milliliter', 'piece', 'pieces', 'pcs', 
                'pc', 'packet', 'pkt', 'pack', 'packs', 'dozen', 'doz', 'box', 'boxes',
                'bottle', 'bottles', 'btl', 'jar', 'tin', 'bag', 'sachet', 'pouch', 'tube'],
    priceWords: ['rupees', 'rupee', 'rs', 'bucks', 'price', 'cost', 'per', 'each'],
  ),
  _LangConfig(
    code: 'hi-IN', label: 'हिंदी', flag: '🕉️',
    numberWords: {
      'शून्य': 0, 'एक': 1, 'दो': 2, 'तीन': 3, 'चार': 4, 'पाँच': 5, 'पांच': 5,
      'छह': 6, 'छः': 6, 'सात': 7, 'आठ': 8, 'नौ': 9, 'दस': 10,
      'ग्यारह': 11, 'बारह': 12, 'तेरह': 13, 'चौदह': 14, 'पन्द्रह': 15,
      'सोलह': 16, 'सत्रह': 17, 'अठारह': 18, 'उन्नीस': 19, 'बीस': 20,
      'तीस': 30, 'चालीस': 40, 'पचास': 50, 'साठ': 60, 'सत्तर': 70, 
      'अस्सी': 80, 'नब्बे': 90, 'सौ': 100, 'हजार': 1000,
      'आधा': 0.5, 'डेढ़': 1.5, 'सवा': 1.25, 'साढ़े': 2.5,
    },
    unitWords: ['किलो', 'किलोग्राम', 'ग्राम', 'लीटर', 'लिटर', 'मिली', 'मिलीलीटर',
                'पीस', 'पीस', 'पैकेट', 'पाकीट', 'डब्बा', 'बोतल', 'जार', 'बैग', 'साचे',
                'पाउच', 'ट्यूब', 'दर्जन', 'डिब्बा', 'kg', 'gm'],
    priceWords: ['रुपये', 'रुपए', 'रूपए', 'का', 'की', 'के', 'दाम', 'कीमत'],
    separator: 'और|तथा|एवं',
  ),
  _LangConfig(
    code: 'ta-IN', label: 'தமிழ்', flag: '🌺',
    numberWords: {
      'பூஜ்ஜியம்': 0, 'ஒன்று': 1, 'இரண்டு': 2, 'மூன்று': 3, 'நான்கு': 4, 'ஐந்து': 5,
      'ஆறு': 6, 'ஏழு': 7, 'எட்டு': 8, 'ஒன்பது': 9, 'பத்து': 10,
      'பதினொன்று': 11, 'பனிரண்டு': 12, 'பதிமூன்று': 13, 'பதிநான்கு': 14, 'பதிநைந்து': 15,
      'பதினாறு': 16, 'பதினேழு': 17, 'பதினெட்டு': 18, 'பத்தொன்பது': 19,
      'இருபது': 20, 'முப்பது': 30, 'நாற்பது': 40, 'ஐம்பது': 50,
      'அரைக்கிலோ': 0.5, 'ஒன்றரை': 1.5,
    },
    unitWords: ['கிலோ', 'கிராம்', 'லிட்டர்', 'மி.லி', 'பாக்கெட்', 'பீஸ்', 'பீசு', 'ப்ரின்ச்',
                'பெட்டி', 'பாட்டில்', 'சாசை', 'பௌச்', 'டூப்', 'டசன்', 'kg', 'gm'],
    priceWords: ['ரூபாய்', 'ரூ', 'விலை', 'விலையுள்ள', 'தொகை'],
    separator: ',|மற்றும்|மற்றுமா',
  ),
  _LangConfig(
    code: 'te-IN', label: 'తెలుగు', flag: '🌸',
    numberWords: {
      'సున్న': 0, 'ఒకటి': 1, 'రెండు': 2, 'మూడు': 3, 'నాలుగు': 4, 'ఐదు': 5,
      'ఆరు': 6, 'ఏడు': 7, 'ఎనిమిది': 8, 'తొమ్మిది': 9, 'పది': 10,
      'పదకొండు': 11, 'పన్నెండు': 12, 'పదమూడు': 13, 'పదనాలుగు': 14, 'పదిహేను': 15,
      'పదహారు': 16, 'పదిఏడు': 17, 'పది ఎనిమిది': 18, 'పందొమ్మిది': 19,
      'ఇరవై': 20, 'ముప్పై': 30, 'నలభై': 40, 'యాభై': 50, 'అరకిలో': 0.5,
    },
    unitWords: ['కిలో', 'గ్రాము', 'లీటర్', 'మిల్లీలీటర్', 'ప్యాకెట్', 'పీస్', 'ముక్క',
                'పెట్టె', 'సీసా', 'జార్', 'బ్యాగ్', 'సాచె', 'పౌచ్', 'ట్యూబ్', 'డజను', 'kg'],
    priceWords: ['రూపాయలు', 'రూ', 'ధర', 'ఖర్చు', 'ఖరీదు'],
    separator: ',|మరియు|াదలా',
  ),
  _LangConfig(
    code: 'kn-IN', label: 'ಕನ್ನಡ', flag: '🌻',
    numberWords: {
      'ಶೂನ್ಯ': 0, 'ಒಂದು': 1, 'ಎರಡು': 2, 'ಮೂರು': 3, 'ನಾಲ್ಕು': 4, 'ಐದು': 5,
      'ಆರು': 6, 'ಏಳು': 7, 'ಎಂಟು': 8, 'ಒಂಬತ್ತು': 9, 'ಹತ್ತು': 10,
      'ಹನ್ನೊಂದು': 11, 'ಹನ್ನೆರಡು': 12, 'ಹದಿಮೂರು': 13, 'ಹದಿನಾಲ್ಕು': 14, 'ಹದಿಐದು': 15,
      'ಹದಿನಾರು': 16, 'ಹದಿನೇಳು': 17, 'ಹದಿನೆಂಟು': 18, 'ಹದಿಒಂಬತ್ತು': 19,
      'ಇಪ್ಪತ್ತು': 20, 'ಮೂವತ್ತು': 30, 'ನಲವತ್ತು': 40, 'ಐವತ್ತು': 50,
      'ಅರ್ಧ': 0.5, 'ೊಂದೂ': 1.5,
    },
    unitWords: ['ಕಿಲೋ', 'ಗ್ರಾಂ', 'ಲೀಟರ್', 'ಮಿಲಿ', 'ಮಿಲೀಲೀಟರ್', 'ಪ್ಯಾಕೆಟ್', 'ಪೀಸ್', 'ಭಾಗ',
                'ಪೆಟ್ಟೆ', 'ಸೀಸೆ', 'ಕಿಟ್ಟು', 'ತೀರೆ', 'ಚೀಲ', 'ಟ್ಯೂಬ್', 'ಡಜನ್', 'kg'],
    priceWords: ['ರೂಪಾಯಿ', 'ರೂ', 'ಬೆಲೆ', 'ಮೌಲ್ಯ', 'ವೆಚ್ಚ'],
    separator: ',|ಮತ್ತು|ಹಾಗೂ',
  ),
  _LangConfig(
    code: 'ml-IN', label: 'മലയാളം', flag: '🌴',
    numberWords: {
      'പൂജ്യം': 0, 'ഒന്ന്': 1, 'രണ്ട്': 2, 'മൂന്ന്': 3, 'നാല്': 4, 'അഞ്ച്': 5,
      'ആറ്': 6, 'ഏഴ്': 7, 'എട്ട്': 8, 'ഒൻപത്': 9, 'പത്ത്': 10,
      'പതിനൊന്ന്': 11, 'പന്ത്രണ്ട്': 12, 'പതിമൂന്ന്': 13, 'പതിനാല്': 14, 'പതിനഞ്ച്': 15,
      'പതിനാറ്': 16, 'പതിനൊരുപത്സമ്': 17, 'പതിനെട്ട്': 18, 'പത്തൊമ്പത്': 19,
      'ഇരുപത്': 20, 'മുപ്പത്': 30, 'നാൽപത്': 40, 'അൻപത്': 50,
      'അരകിലോ': 0.5, 'ഒന്നര': 1.5,
    },
    unitWords: ['കിലോ', 'ഗ്രാം', 'ലിറ്റർ', 'മിലി', 'ഫാകറ്റ്', 'പീസ്', 'പാകെജ്ജ്', 'പാച്ച്',
                'പെട്ടി', 'കുപ്പി', 'ജാർ', 'കഥ', 'ബാഗ്', 'സാഷേ', 'ടാൻബ്', 'ഡസൻ', 'kg'],
    priceWords: ['രൂപ', 'രൂ', 'വിലയാണ്', 'വില', 'കിംവദം'],
    separator: ',|കൂടാതെ|എന്നും',
  ),
  _LangConfig(
    code: 'mr-IN', label: 'मराठी', flag: '🏔️',
    numberWords: {
      'शून्य': 0, 'एक': 1, 'दोन': 2, 'तीन': 3, 'चार': 4, 'पाच': 5,
      'सहा': 6, 'सात': 7, 'आठ': 8, 'नऊ': 9, 'दहा': 10,
      'अकरा': 11, 'बारा': 12, 'तेरा': 13, 'चौदा': 14, 'पंधरा': 15,
      'सोळा': 16, 'सतरा': 17, 'अठरा': 18, 'एकोणीस': 19, 'वीस': 20,
      'तीस': 30, 'चाळीस': 40, 'पन्नास': 50, 'साठ': 60, 'सत्तर': 70, 
      'अस्सी': 80, 'नव्वद': 90, 'शे': 100, 'हजार': 1000,
      'अर्धा': 0.5, 'डेढ': 1.5, 'साडे': 2.5,
    },
    unitWords: ['किलो', 'किलोग्राम', 'ग्रॅम', 'ग्राम', 'लिटर', 'लीटर', 'मिली', 'पीस', 'पीसा',
                'पाकीट', 'डब्बा', 'बोतल', 'जार', 'बॉक्स', 'बॅग', 'सॅशे', 'पाउच', 'ट्यूब', 'डजन', 'kg'],
    priceWords: ['रुपये', 'रु', 'रु.', 'किंमत', 'दर', 'खर्च'],
    separator: 'आणि|तसेच|व',
  ),
  _LangConfig(
    code: 'bn-IN', label: 'বাংলা', flag: '🎋',
    numberWords: {
      'শূন্য': 0, 'এক': 1, 'দুই': 2, 'তিন': 3, 'চার': 4, 'পাঁচ': 5,
      'ছয়': 6, 'সাত': 7, 'আট': 8, 'নয়': 9, 'দশ': 10,
      'এগারো': 11, 'বারো': 12, 'তেরো': 13, 'চৌদ্দ': 14, 'পনের': 15,
      'ষোল': 16, 'সতের': 17, 'আঠারো': 18, 'উনিশ': 19, 'বিশ': 20,
      'ত্রিশ': 30, 'চল্লিশ': 40, 'পঞ্চাশ': 50, 'ষাট': 60, 'সত্তর': 70, 
      'আশি': 80, 'নব্বই': 90, 'শত': 100, 'হাজার': 1000,
      'অর্ধ': 0.5, 'দেড়': 1.5,
    },
    unitWords: ['কেজি', 'কিলোগ্রাম', 'গ্রাম', 'লিটার', 'মি.লি', 'পিস', 'প্যাকেট', 'প্যাক',
                'ডাব্বা', 'বোতল', 'জার', 'বাক্স', 'ব্যাগ', 'থলি', 'টিউব', 'ডজন', 'kg'],
    priceWords: ['টাকা', 'রুপি', 'দাম', 'মুল্য', 'খরচ'],
    separator: ',|এবং|অথবা',
  ),
  _LangConfig(
    code: 'gu-IN', label: 'ગુજરાતી', flag: '🦚',
    numberWords: {
      'શૂન્ય': 0, 'એક': 1, 'બે': 2, 'ત્રણ': 3, 'ચાર': 4, 'પાંચ': 5,
      'છ': 6, 'સાત': 7, 'આઠ': 8, 'નવ': 9, 'દસ': 10,
      'અગિયાર': 11, 'બાર': 12, 'તેર': 13, 'ચૌદ': 14, 'પંદર': 15,
      'સોળ': 16, 'સત્તર': 17, 'અઠાર': 18, 'ઉનીસ': 19, 'વીસ': 20,
      'ત્રીસ': 30, 'ચાલીસ': 40, 'પચાસ': 50, 'સાઠ': 60, 'સોતર': 70, 
      'અસ્સી': 80, 'નવ્વે': 90, 'સો': 100, 'હજાર': 1000,
      'અર્ધ': 0.5, 'દોઢ': 1.5,
    },
    unitWords: ['કિલો', 'કિલોગ્રામ', 'ગ્રામ', 'લિટર', 'મિલી', 'પીસ', 'પીસું', 'પેકેટ',
                'ડબ્બો', 'બોટલ', 'ભાંડું', 'પેટી', 'બેગ', 'થેલું', 'ટ્યુબ', 'ડજન', 'kg'],
    priceWords: ['રૂપિયા', 'રૂ', 'રૂ.', 'ભાવ', 'દર', 'ખર્ચ'],
    separator: ',|અને|તથા',
  ),
  _LangConfig(
    code: 'pa-IN', label: 'ਪੰਜਾਬੀ', flag: '🌾',
    numberWords: {
      'ਸਿਫਰ': 0, 'ਇੱਕ': 1, 'ਦੋ': 2, 'ਤਿੰਨ': 3, 'ਚਾਰ': 4, 'ਪੰਜ': 5,
      'ਛੇ': 6, 'ਸੱਤ': 7, 'ਅੱਠ': 8, 'ਨੌਂ': 9, 'ਦਸ': 10,
      'ਗਿਆਰਾਂ': 11, 'ਬਾਰਾਂ': 12, 'ਤੇਰਾਂ': 13, 'ਚੌਦਾਂ': 14, 'ਪੰਦਰਾਂ': 15,
      'ਸੋਲਾਂ': 16, 'ਸਤਾਰਾਂ': 17, 'ਅਠਾਰਾਂ': 18, 'ਉਨੀਨੀ': 19, 'ਬੀਹ': 20,
      'ਤੀਹ': 30, 'ਚਾਲੀ': 40, 'ਅੱਸੀ': 50, 'ਸਾਠ': 60, 'ਸਤਾਹ': 70, 
      'ਅਸੀ': 80, 'ਨਬੇ': 90, 'ਸੌ': 100, 'ਹਜ਼ਾਰ': 1000,
      'ਅੱਧ': 0.5, 'ਡੇਢ': 1.5,
    },
    unitWords: ['ਕਿਲੋ', 'ਕਿਲੋਗ੍ਰਾਮ', 'ਗ੍ਰਾਮ', 'ਲਿਟਰ', 'ਮਿਲੀ', 'ਪੀਸ', 'ਪੀਸਾ', 'ਪੈਕੇਟ', 
                'ਡਿੱਬਾ', 'ਬੋਤਲ', 'ਜਾਰ', 'ਡੱਬਾ', 'ਬੈਗ', 'ਥੈਲਾ', 'ਟਿਊਬ', 'ਦਰਜਨ', 'kg'],
    priceWords: ['ਰੁਪਏ', 'ਰੁ', 'ਰੁ.', 'ਕੀਮਤ', 'ਦਰ', 'ਖਰਚ'],
    separator: ',|ਅਤੇ|ਤੇ',
  ),
];

// ─── NLP Parser ───────────────────────────────────────────────────────────────

class ParsedItem {
  final String name;
  final double qty;
  final String unit;
  final double price;
  final double confidence;
  final bool catalogMatched;
  final String priceSource;
  final String? barcode;
  final double? gst;
  final String? priceWarning;
  bool isConfirmed;

  ParsedItem({
    required this.name,
    required this.qty,
    required this.unit,
    required this.price,
    required this.confidence,
    this.catalogMatched = false,
    this.priceSource = 'missing',
    this.barcode,
    this.gst,
    this.priceWarning,
    bool? isConfirmed,
  }) : isConfirmed = isConfirmed ?? (confidence >= 0.6 || catalogMatched);

  Map<String, dynamic> toMap() => {
    'name': name,
    'product_name': name,
    'qty': qty,
    'quantity': qty,
    'unit': unit,
    'price': price,
    'total': qty * price,
    'confidence': confidence,
    'catalog_matched': catalogMatched,
    'price_source': priceSource,
    'price_missing': price <= 0,
    if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
    if (gst != null) 'gst': gst,
    if (priceWarning != null && priceWarning!.isNotEmpty)
      'price_warning': priceWarning,
  };
}

class MultiLangVoiceParser {
  /// Normalise unit aliases to canonical short forms
  static const _unitAliases = <String, String>{
    'kilo': 'kg', 'kilogram': 'kg', 'kilograms': 'kg',
    'किलो': 'kg', 'किलोग्राम': 'kg',
    'கிலோ': 'kg', 'కిలో': 'kg', 'ಕಿಲೋ': 'kg', 'കിലോ': 'kg',
    'kেজি': 'kg', 'ਕਿਲੋ': 'kg',
    'gram': 'g', 'grams': 'g', 'gm': 'g',
    'ग्राम': 'g', 'ग्रॅम': 'g',
    'liter': 'L', 'litre': 'L', 'ltr': 'L',
    'लीटर': 'L', 'लिटर': 'L', ' லிட்டர்': 'L',
    'milliliter': 'mL', 'millilitre': 'mL', 'ml': 'mL',
    'packet': 'pkt', 'pack': 'pkt', 'packs': 'pkt',
    'पैकेट': 'pkt', 'पाकीट': 'pkt',
    'piece': 'pc', 'pieces': 'pc', 'pcs': 'pc',
    'bottle': 'btl', 'bottles': 'btl',
    'box': 'box', 'dozen': 'doz',
  };

  static String _normalizeUnit(String u) {
    final lower = u.toLowerCase().trim();
    
    // Exact match (first priority)
    if (_unitAliases.containsKey(lower)) return _unitAliases[lower]!;
    if (_unitAliases.containsKey(u)) return _unitAliases[u]!;
    
    // Fuzzy match (handle phonetic/typo variations)
    double bestScore = 0.6;  // Threshold for fuzzy match
    String bestMatch = u;
    
    for (String alias in _unitAliases.keys) {
      double score = _calculateBigramSimilarity(lower, alias);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = _unitAliases[alias]!;
      }
    }
    
    // Return fuzzy match if found, otherwise return original
    return bestScore > 0.6 ? bestMatch : u;
  }

  /// Replace language-specific number words with digits globally across ALL supported languages
  static String _replaceNumberWords(String text) {
    String result = text;
    for (final lang in _languages) {
      lang.numberWords.forEach((word, value) {
        result = result.replaceAll(word, ' $value ');
      });
    }
    return result;
  }

  // Price/currency words that must NEVER become product names
  static final _priceKeywordsV1 = RegExp(
    r'^(rupees?|rupee|rs|inr|rupe|rupaiye|rupaiya|paisa|paise|bucks|price|cost|amount|total|rate|charge|rupay)$',
    caseSensitive: false,
  );

  // Stop-words that should never be standalone product names
  static final _stopWordsV1 = RegExp(
    r'^(in|an|a|the|at|on|is|it|to|of|or|and|as|by|so|up|do|ka|ki|ke|ko|me|se|ho|hai)$',
    caseSensitive: false,
  );

  static final _fillerWords = RegExp(r'\b(i|want|need|give|me|some|of|add|please|can|get|also|with|for|rs|rupees|rupee|bucks|actually|aur|marrum|mariyu|mattu|price|cost|total|amount|rupeesand|add to bill|bill mein add karo|bill me add karo|add kar|add karo|paisa|paise)\b', caseSensitive: false);

  static String _removeFillerWords(String text) {
    return text.replaceAll(_fillerWords, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Parse a single segment like "2 kg sugar 60" or "दो किलो आटा साठ"
  static Future<ParsedItem?> _parseSegment(String segment, _LangConfig lang, {List<Map<String, dynamic>>? knownProducts}) async {
    String text = _removeFillerWords(_replaceNumberWords(segment.trim().toLowerCase()));

    // Patterns tried in order of specificity (higher index = lower confidence):
    // [qty] [unit?] [name] [price]
    final patterns = [
      // 0: "2 kg sugar 60"  /  "2 sugar 60"
      RegExp(
        r'(\d+\.?\d*)\s*(\w+)?\s+([a-z\u0900-\u097f\u0b80-\u0bff\u0c00-\u0c7f\u0c80-\u0cff\u0d00-\u0d7f\u0980-\u09ff\u0a80-\u0aff\u0a00-\u0a7f]+(?:\s+[a-z\u0900-\u097f\u0b80-\u0bff]+)?)\s+(\d+\.?\d*)',
        caseSensitive: false,
      ),
      // 1: "sugar 2 60" (name first)
      RegExp(
        r'([a-z\u0900-\u097f\u0b80-\u0bff\u0c00-\u0c7f\u0c80-\u0cff\u0d00-\u0d7f\u0980-\u09ff\u0a80-\u0aff\u0a00-\u0a7f]+)\s+(\d+\.?\d*)\s+(\d+\.?\d*)',
        caseSensitive: false,
      ),
      // 2: "2 kg sugar" / "2 sugar" (no price)
      RegExp(
        r'(\d+\.?\d*)\s*(\w+)?\s+([a-z\u0900-\u097f\u0b80-\u0bff\u0c00-\u0c7f\u0c80-\u0cff\u0d00-\u0d7f\u0980-\u09ff\u0a80-\u0aff\u0a00-\u0a7f]+(?:\s+[a-z\u0900-\u097f\u0b80-\u0bff]+)?)',
        caseSensitive: false,
      ),
      // 3: "sugar 60" or "sugar 2" (name + one number)
      RegExp(
        r'([a-z\u0900-\u097f\u0b80-\u0bff\u0c00-\u0c7f\u0c80-\u0cff\u0d00-\u0d7f\u0980-\u09ff\u0a80-\u0aff\u0a00-\u0a7f]+)\s+(\d+\.?\d*)',
        caseSensitive: false,
      ),
      // 4: "sugar" (just name)
      RegExp(
        r'([a-z\u0900-\u097f\u0b80-\u0bff\u0c00-\u0c7f\u0c80-\u0cff\u0d00-\u0d7f\u0980-\u09ff\u0a80-\u0aff\u0a00-\u0a7f]+)',
        caseSensitive: false,
      ),
    ];

    for (int pi = 0; pi < patterns.length; pi++) {
      final match = patterns[pi].firstMatch(text);
      if (match == null) continue;

      String name, rawUnit;
      double qty, price;

      if (pi == 0) {
        qty      = double.tryParse(match.group(1) ?? '1') ?? 1;
        rawUnit  = match.group(2) ?? '';
        name     = match.group(3) ?? '';
        price    = double.tryParse(match.group(4) ?? '0') ?? 0;
      } else if (pi == 1) {
        name     = match.group(1) ?? '';
        qty      = double.tryParse(match.group(2) ?? '1') ?? 1;
        price    = double.tryParse(match.group(3) ?? '0') ?? 0;
        rawUnit  = '';
      } else if (pi == 2) {
        double val = double.tryParse(match.group(1) ?? '1') ?? 1;
        rawUnit  = match.group(2) ?? '';
        name     = match.group(3) ?? '';
        // Don't auto-determine price based on value - let product database decide
        qty = val; price = 0.0;
      } else if (pi == 3) {
        name     = match.group(1) ?? '';
        // Don't auto-determine price based on value - let product database decide
        double val = double.tryParse(match.group(2) ?? '1') ?? 1;
        qty = val; price = 0.0;
        rawUnit  = '';
      } else {
        name     = match.group(1) ?? '';
        qty      = 1.0;
        price    = 0.0;
        rawUnit  = '';
      }

      name = name.trim();

      // GUARD: Reject pure price/currency keywords as product names
      if (_priceKeywordsV1.hasMatch(name)) continue;

      // GUARD: Reject single stop-words (in, an, a, the) as product names
      if (_stopWordsV1.hasMatch(name)) continue;

      if (name.length < 2) continue;

      // Check if rawUnit is actually part of the name (not a unit word)
      // We check globally across all languages to support mixed/Hinglish speech seamlessly
      final isUnit = _languages.any((l) => l.unitWords.any((u) => u.toLowerCase() == rawUnit.toLowerCase()))
                  || _unitAliases.containsKey(rawUnit.toLowerCase());
      if (!isUnit && rawUnit.isNotEmpty) {
        // rawUnit is probably a second word of the product name
        name = '$rawUnit $name'.trim();
        rawUnit = '';
      }

      final unit = rawUnit.isEmpty ? 'pc' : _normalizeUnit(rawUnit);
      
      // ✨ AUTO-SUGGESTION: Always try to match against known products to get correct price
      Map<String, dynamic>? suggestion;
      if (knownProducts != null && knownProducts.isNotEmpty) {
        suggestion = await _suggestProductMatch(name, knownProducts, lang.code);
        if (suggestion != null) {
          // Use suggested product name and price
          name = _toTitleCase(suggestion['name']?.toString() ?? suggestion['product_name']?.toString() ?? name);
          // Always use database price, even if a price was detected from speech
          price = double.tryParse(suggestion['price']?.toString() ?? '0') ?? 0;
        }
      }

      final confidence = _computeConfidence(name, qty, price, pi);

      // 🔧 FIX: Debug logging for quantity parsing
      if (kDebugMode) {
        debugPrint('🔍 [VoiceBilling] Parsed: name="$name", qty=$qty, price=$price, confidence=$confidence');
      }

      return ParsedItem(
        name: _toTitleCase(name),
        qty: qty,
        unit: unit,
        price: price,
        confidence: confidence,
      );
    }
    return null;
  }

  static double _computeConfidence(String name, double qty, double price, int patternIndex) {
    double score = 1.0;
    
    // CRITICAL: Price validation (most important signal)
    if (price == 0) score -= 0.15;     // No price spoken — still add to cart for manual entry
    if (price < 0) score -= 1.0;       // Negative price (IMPOSSIBLE)
    if (price < 5 && price > 0) score -= 0.25; // Suspiciously low price (< ₹5)
    if (price > 100000) score -= 0.35; // Unrealistic price (> ₹100k)
    
    // CRITICAL: Name/quantity validation
    if (name.length < 2) score -= 0.25;  // Too short product name
    if (qty > 100) score -= 0.45;        // Very high quantity - MAJOR RED FLAG
    if (qty > 500) score -= 0.65;        // Absurdly high quantity (> 500 units)
    if (qty < 0.1) score -= 0.25;        // Invalid quantity (< 0.1)
    if (qty <= 0) score -= 0.5;          // Non-positive quantity (CRITICAL)
    
    // MEDIUM: Pattern analysis
    if (qty == 1.0 && name.length > 15) score -= 0.10; // Long name with qty=1 (likely parse error)
    if (name.contains(RegExp(r'\d'))) score -= 0.15;   // Numbers in product name (parse error)
    
    // MEDIUM: Unusual combinations
    if (name.split(' ').length > 4) score -= 0.10;     // Too many words in name
    
    // BOOST: Reasonable values (only if price > 0)
    if (price > 5 && price <= 5000) score += 0.25;     // Very reasonable price range
    if (qty >= 0.25 && qty <= 100) score += 0.15;      // Very reasonable quantity
    if (name.length >= 3 && name.length <= 20) score += 0.10;  // Good name length
    
    // BOOST: Natural language signals
    if (RegExp(r'^[a-z\u0900-\u097f\u0b80-\u0bff\u0c00-\u0c7f]+$').hasMatch(name)) score += 0.05; // Letters only = good
    
    // DEDUCT: Pattern fallback confidence (later patterns = lower confidence)
    score -= (0.10 * patternIndex);  // Increased penalty for lower-confidence patterns
    
    return score.clamp(0.0, 1.0);
  }

  static String _toTitleCase(String s) {
    if (s.isEmpty) return s;
    return s.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
  }

  /// Main entry: parse full transcript with intelligent multi-item detection
  static Future<List<ParsedItem>> parse(String transcript, _LangConfig lang, {List<Map<String, dynamic>>? knownProducts}) async {
    if (transcript.trim().isEmpty) return [];

    // ✅ PATCH: Normalize STT output before parsing — fixes ~40% of parse failures
    transcript = PhoneticNormalizer.normalize(transcript, lang.code);

    // First attempt: Split on commas, "and", "और", "மற்றும்" etc.
    final splitPattern = RegExp(r'[,।]|(?<!\d)\.(?!\d)|\band\b|\bplus\b|\baur\b|और|\binkaa\b|\bmariyum\b|\bmattu\b|మరియు|ಮತ್ತು|ਅਤੇ|\bnext\b|\bitem\b', caseSensitive: false);
    final segments = transcript.split(splitPattern).where((s) => s.trim().isNotEmpty).toList();

    final items = <ParsedItem>[];
    for (final seg in segments) {
      final item = await _parseSegment(seg, lang, knownProducts: knownProducts);
      if (item != null) items.add(item);
    }

    // If we got good items, return them
    if (items.isNotEmpty) return items;

    // Second attempt: Smart segmentation for continuous speech like "three tomato 200 onion 300 rice 500"
    return await _parseMultipleItemsContinuous(transcript, lang, knownProducts: knownProducts);
  }

  /// Auto-suggest product name and price from known catalog
  static Future<Map<String, dynamic>?> _suggestProductMatch(String voiceInput, List<Map<String, dynamic>>? knownProducts, String langCode) async {
    if (knownProducts == null || knownProducts.isEmpty || voiceInput.isEmpty) return null;

    voiceInput = voiceInput.toLowerCase().trim();
    
    // Attempt real-time translation if not English
    String translatedInput = voiceInput;
    if (langCode != 'en-IN') {
      try {
        final codePart = langCode.split('-').first;
        translatedInput = await FreeTranslatorService.translate(voiceInput, from: codePart, to: 'en');
        translatedInput = translatedInput.toLowerCase().trim();
      } catch (e) {
        print("Translation failed during suggest");
      }
    }

    double bestScore = 0.0;
    Map<String, dynamic>? bestMatch;

    for (final product in knownProducts) {
      final prodName = (product['name'] ?? product['product_name'] ?? '').toString().toLowerCase().trim();
      if (prodName.isEmpty) continue;

      // Check exact substrings with original input
      if (prodName.contains(voiceInput) || voiceInput.contains(prodName)) {
        bestScore = 1.0;
        bestMatch = product;
        break;
      }
      
      // Check exact substrings with translated input
      if (prodName.contains(translatedInput) || translatedInput.contains(prodName)) {
        bestScore = 1.0;
        bestMatch = product;
        break;
      }

      // Advanced Levenshtein Fuzzy matching (on translated input for English catalogs)
      final similarityTrans = _calculateLevenshteinSimilarity(translatedInput, prodName);
      final similarityOrig = _calculateLevenshteinSimilarity(voiceInput, prodName);
      final similarity = similarityTrans > similarityOrig ? similarityTrans : similarityOrig;
      
      if (similarity > bestScore) {
        bestScore = similarity;
        bestMatch = product;
      }
    }

    if (bestScore > 0.5 && bestMatch != null && langCode != 'en-IN') {
      // Translate matched product back to the UI language so it appears native!
      final matchedName = (bestMatch['name'] ?? bestMatch['product_name'] ?? '').toString();
      try {
         final codePart = langCode.split('-').first;
         final localizedName = await FreeTranslatorService.translate(matchedName, from: 'en', to: codePart);
         // Mutate a copy so we return the translated name
         return {...bestMatch, 'name': localizedName, 'product_name': localizedName};
      } catch (e) {
         // Fallback
      }
    }

    return bestScore > 0.5 ? bestMatch : null;
  }
  
  static double _calculateLevenshteinSimilarity(String s1, String s2) {
    s1 = s1.toLowerCase().trim();
    s2 = s2.toLowerCase().trim();
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    
    // Levenshtein distance
    List<int> v0 = List<int>.filled(s2.length + 1, 0);
    List<int> v1 = List<int>.filled(s2.length + 1, 0);
    
    for (int i = 0; i <= s2.length; i++) v0[i] = i;
    
    for (int i = 0; i < s1.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < s2.length; j++) {
        int cost = (s1[i] == s2[j]) ? 0 : 1;
        v1[j + 1] = [v1[j] + 1, v0[j + 1] + 1, v0[j] + cost].reduce((a, b) => a < b ? a : b);
      }
      for (int j = 0; j <= s2.length; j++) v0[j] = v1[j];
    }
    
    int maxLen = s1.length > s2.length ? s1.length : s2.length;
    return 1.0 - (v0[s2.length] / maxLen);
  }


  /// Calculate similarity between two strings using bigram coefficient (Dice)
  static double _calculateBigramSimilarity(String s1, String s2) {
    String a = s1.toLowerCase().trim();
    String b = s2.toLowerCase().trim();
    
    if (a == b) return 1.0;
    if (a.length < 2 || b.length < 2) return 0.0;

    // Expanded regional variant matching (HIGHEST PRIORITY)
    Map<String, Set<String>> variants = {
      // Vegetables
      'टमाटर': {'तमातर', 'टमेटर', 'तमेटर', 'टमटर', 'टमाटो', 'टमेटो', 'tamatar', 'टमेटा'},
      'प्याज': {'प्यांज', 'प्याजा', 'प्यांजा', 'प्याज़', 'pyaaz'},
      'आलू': {'आलु', 'aloo'},
      'गाजर': {'गाजेर', 'गाजर', 'गजर', 'gajar'},
      'बीन्स': {'बींस', 'बीन्स', 'बीन', 'beans'},
      'पालक': {'पालिक', 'पालक', 'पालेक', 'palak'},
      'मटर': {'मटर', 'मतर', 'matar', 'मटर्स'},
      
      // Grains/Pantry items
      'चावल': {'चावल', 'चाबल', 'चाउल', 'chawal', 'rice', 'चावली'},
      'दाल': {'दालि', 'दाली', 'दालो', 'दाल', 'daal', 'धाली'},
      'नमक': {'नमकी', 'नमक', 'सॉल्ट', 'namak', 'salt'},
      'चीनी': {'चीनो', 'चीनी', 'सुगर', 'chini', 'sugar', 'चीने'},
      'मैदा': {'मेदा', 'मैदा', 'फ्लोर', 'maida'},
      'आटा': {'आटा', 'आता', 'अता', 'अत्ता', 'आटे', 'atta', 'flour'},  // ADDED अता variant
      
      // Dairy/Others
      'दही': {'दहीं', 'दही', 'योगर्ट', 'curd', 'दाही'},
      'दूध': {'दुध', 'दूध', 'milk', 'दूद', 'दुद्ध'},
      'घी': {'घी', 'घि', 'ghee', 'गी'},
      'मक्खन': {'मक्खन', 'मखन', 'butter'},
    };
    
    for (String key in variants.keys) {
      if (a == key && variants[key]!.contains(b)) return 0.95;  // EXACT key match in variants
      if (b == key && variants[key]!.contains(a)) return 0.95;
      // Cross-check: if a is in some variant set and b is the key
      for (String variantKey in variants.keys) {
        if (variants[variantKey]!.contains(a) && b == variantKey) return 0.90;
        if (variants[variantKey]!.contains(b) && a == variantKey) return 0.90;
      }
    }

    // Levenshtein distance (phonetic similarity)
    int distance = _levenshteinDistance(a, b);
    int maxLen = a.length > b.length ? a.length : b.length;
    double levenSim = 1.0 - (distance / maxLen);
    
    // Boost for small length differences (same word, different transliteration)
    if ((a.length - b.length).abs() <= 1) levenSim += 0.25;  // INCREASED from 0.15/0.18
    if ((a.length - b.length).abs() == 0) levenSim += 0.20;  // INCREASED from 0.10/0.12

    // Bigram matching (Jaccard similarity)
    Set<String> getBigrams(String str) {
      final bigrams = <String>{};
      for (int i = 0; i < str.length - 1; i++) {
        bigrams.add(str.substring(i, i + 2));
      }
      return bigrams;
    }
    
    final b1 = getBigrams(a);
    final b2 = getBigrams(b);
    if (b1.isEmpty || b2.isEmpty) {
      return levenSim.clamp(0.0, 1.0);
    }

    final intersection = b1.intersection(b2).length;
    double bigramJaccard = (2.0 * intersection) / (b1.length + b2.length);
    
    // Weight Levenshtein higher for transliteration variations
    double finalScore = (levenSim * 0.70) + (bigramJaccard * 0.30);  // INCREASED Levenshtein weight from 0.65
    
    return finalScore.clamp(0.0, 1.0);
  }
  
  static int _levenshteinDistance(String a, String b) {
    List<List<int>> dp = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
    
    for (int i = 0; i <= a.length; i++) dp[i][0] = i;
    for (int j = 0; j <= b.length; j++) dp[0][j] = j;
    
    for (int i = 1; i <= a.length; i++) {
      for (int j = 1; j <= b.length; j++) {
        int cost = a[i - 1] == b[j - 1] ? 0 : 1;
        int mind = [dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost].reduce((x, y) => x < y ? x : y);
        dp[i][j] = mind;
      }
    }
    
    return dp[a.length][b.length];
  }

  /// Intelligently parse continuous speech with multiple items
  /// Looks for patterns: [quantity] [product_name] [price] [quantity] [product_name] [price] ...
  static Future<List<ParsedItem>> _parseMultipleItemsContinuous(String transcript, _LangConfig lang, {List<Map<String, dynamic>>? knownProducts}) async {
    if (transcript.trim().isEmpty) return [];

    String normalized = _replaceNumberWords(transcript.trim().toLowerCase());
    final items = <ParsedItem>[];

    // Find all numbers (potential prices and quantities)
    final numbersPattern = RegExp(r'\d+\.?\d*');
    final numberMatches = numbersPattern.allMatches(normalized).toList();

    if (numberMatches.isEmpty) return [];

    // Strategy: Look for PRICE patterns (numbers >= 10 or last numbers that look like prices)
    // Work backwards from each price to find product+unit+qty
    Set<String> usedSegments = {};
    
    for (int i = numberMatches.length - 1; i >= 0; i--) {
      final numberMatch = numberMatches[i];
      final number = double.tryParse(numberMatch.group(0) ?? '0') ?? 0;
      
      // Skip very small numbers (likely quantities, not prices)
      if (number < 5 && i < numberMatches.length - 1) continue;
      
      // Get segment from previous price (or start) to this number
      int segmentStart = 0;
      for (int j = i - 1; j >= 0; j--) {
        final prevNum = double.tryParse(numberMatches[j].group(0) ?? '0') ?? 0;
        if (prevNum >= 5) { // Previous number is a price
          segmentStart = numberMatches[j].end;
          break;
        }
      }
      
      String segment = normalized.substring(segmentStart, numberMatch.start).trim();
      if (segment.isEmpty || segment.length < 2) continue;
      
      // Avoid duplicate segments
      if (usedSegments.contains(segment)) continue;
      usedSegments.add(segment);
      
      // Try to parse this segment as "[qty] [unit] [name]" with price=$number
      String itemText = '$segment $number';
      final item = await _parseSegment(itemText, lang, knownProducts: knownProducts);
      
      if (item != null && item.name.isNotEmpty && item.price > 0) {
        // Same product at the same price is one line item. Merge quantity.
        final existingIdx = items.indexWhere(
          (e) =>
              e.name.trim().toLowerCase() == item.name.trim().toLowerCase() &&
              (e.price - item.price).abs() < 0.01,
        );

        if (existingIdx >= 0) {
          final existing = items[existingIdx];
          items[existingIdx] = ParsedItem(
            name: existing.name,
            qty: existing.qty + item.qty,
            unit: item.unit.isNotEmpty ? item.unit : existing.unit,
            price: item.price,
            confidence: item.confidence,
            isConfirmed: existing.isConfirmed || item.isConfirmed,
          );
        } else {
          items.add(item);
        }
      }
    }
    
    // If intelligent parsing found items, return in order
    if (items.isNotEmpty) {
      items.sort((a, b) => a.name.compareTo(b.name)); // Stable sort
      return items;
    }

    // Fallback: parse entire transcript as single item
    final fallbackItem = await _parseSegment(transcript, lang, knownProducts: knownProducts);
    return fallbackItem != null ? [fallbackItem] : [];
  }

  /// Public API for testing: Get all language configs
  static Map<String, _LangConfig> get langConfigs {
    final Map<String, _LangConfig> configs = {};
    for (final lang in _languages) {
      configs[lang.code] = lang;
    }
    return configs;
  }

  /// Public API for testing: Calculate bigram similarity between two strings
  static double calculateBigramSimilarity(String s1, String s2) {
    return _calculateBigramSimilarity(s1, s2);
  }

  /// Public API for testing: Normalize unit aliases
  static String normalizeUnit(String u) {
    return _normalizeUnit(u);
  }

  /// Public API for testing: Compute confidence score
  static double computeConfidence(String name, double qty, double price, int patternIndex) {
    return _computeConfidence(name, qty, price, patternIndex);
  }
}

// ─── Widget ───────────────────────────────────────────────────────────────────

class VoiceBillingAssistant extends StatefulWidget {
  final Function(List<Map<String, dynamic>>) onOrderParsed;
  final List<Map<String, dynamic>>? knownProducts;
  final bool autoStart;
  final String? initialText;
  final String? initialLocale;

  const VoiceBillingAssistant({
    super.key, 
    required this.onOrderParsed,
    this.knownProducts,
    this.autoStart = false,
    this.initialText,
    this.initialLocale,
  });

  @override
  State<VoiceBillingAssistant> createState() => _VoiceBillingAssistantState();
}

class _VoiceBillingAssistantState extends State<VoiceBillingAssistant>
    with TickerProviderStateMixin {
  late stt.SpeechToText _speech;
  bool _isListening = false;
  bool _isProcessing = false;
  String _transcript = '';
  String _hint = '';

  final _catalog = ProductCatalogService();
  
  _LangConfig _selectedLang = _languages[0]; // default English
  List<ParsedItem> ParsedItems = [];
  List<ParsedItem> _committedItems = [];
  List<ParsedItem> _lastPreviewItems = [];
  String _lastFinalTranscript = '';
  String _lastCommittedText = '';
  bool _shouldRestartListening = false;

  late AnimationController _pulseCtrl;
  late AnimationController _waveCtrl;
  late Animation<double> _pulseAnim;

  late TextEditingController _transcriptCtrl;

  // Editable controllers for inline editing
  final _editControllers = <int, Map<String, TextEditingController>>{};
  void _clearEditControllers() { for (final m in _editControllers.values) { m.values.forEach((c) => c.dispose()); } _editControllers.clear(); }

  bool _hasInitializedStt = false;
  bool _catalogReady = false;
  bool _finalResultHandled = false;
  Future<void>? _catalogLoadFuture;
  List<String> _parseWarnings = [];

  _LangConfig _languageForCode(String? code) {
    if (code == null || code.trim().isEmpty) return _languages.first;
    for (final lang in _languages) {
      if (lang.code == code) return lang;
    }
    final prefix = code.split('-').first.toLowerCase();
    for (final lang in _languages) {
      if (lang.code.startsWith('${prefix}-')) return lang;
    }
    return _languages.first;
  }

  Future<void> _initializeCatalog() async {
    try {
      await _catalog.load(widget.knownProducts ?? const []);
      _catalogReady = true;
    } catch (e) {
      _catalogReady = false;
      if (kDebugMode) debugPrint('🎙️ [VoiceBilling] Catalog initialization failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _transcriptCtrl = TextEditingController();
    _selectedLang = _languageForCode(widget.initialLocale);

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _pulseAnim = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _catalogLoadFuture = _initializeCatalog();

    if (widget.initialText != null && widget.initialText!.trim().isNotEmpty) {
      _transcript = widget.initialText!.trim();
      _transcriptCtrl.text = _transcript;
    }

    _updateHint();

    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await _catalogLoadFuture;
        if (mounted) {
          await _toggleListening();
        }
      });
    }
  }

  @override
  void dispose() {
    _transcriptCtrl.dispose();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    for (final m in _editControllers.values) {
      m.values.forEach((c) => c.dispose());
    }
    super.dispose();
  }

  void _updateHint() {
    final hints = {
      'en-IN': '"2 kg Sugar 60, 1 Oil 150, 3 Biscuit 20"',
      'hi-IN': '"दो किलो आटा साठ, एक तेल डेढ़ सौ"',
      'ta-IN': '"2 கிலோ சர்க்கரை 60, 1 எண்ணெய் 150"',
      'te-IN': '"2 కిలో పంచదార 60, 1 నూనె 150"',
      'kn-IN': '"2 ಕಿಲೋ ಸಕ್ಕರೆ 60, 1 ಎಣ್ಣೆ 150"',
      'ml-IN': '"2 കിലോ പഞ്ചസാര 60, 1 എണ്ണ 150"',
      'mr-IN': '"दोन किलो साखर साठ, एक तेल दीडशे"',
      'bn-IN': '"2 কেজি চিনি 60, 1 তেল 150"',
      'gu-IN': '"2 કિલો ખાંડ 60, 1 તેલ 150"',
      'pa-IN': '"2 ਕਿਲੋ ਖੰਡ 60, 1 ਤੇਲ 150"',
    };
    setState(() {
      _hint = hints[_selectedLang.code] ?? hints['en-IN']!;
    });
  }

  Future<void> _toggleListening() async {
    if (_isProcessing) return;

    if (_isListening) {
      _shouldRestartListening = false;
      await _speech.stop();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      if (mounted && !_finalResultHandled && _transcript.trim().isNotEmpty) {
        final textToProcess = _transcript.trim();
        _finalResultHandled = true;
        await _doProcess(textToProcess, commit: true);
      }

      if (mounted) {
        setState(() => _isListening = false);
      }
      return;
    }

    _shouldRestartListening = false;
    await (_catalogLoadFuture ?? Future<void>.value());

    if (!_catalogReady && mounted) {
      _showSnack('Product catalog is still loading. Please try again.', isError: true);
      return;
    }

    if (!_hasInitializedStt) {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (!mounted) return;

            if (!_finalResultHandled && _transcript.trim().isNotEmpty && !_isProcessing) {
              final textToProcess = _transcript.trim();
              _finalResultHandled = true;
              _doProcess(textToProcess, commit: true);
            }

            if (mounted) {
              setState(() => _isListening = false);
            }
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() => _isListening = false);
          _showSnack(
            'Voice recognition error. Please try again.',
            isError: true,
          );
          if (kDebugMode) {
            debugPrint('🎙️ [VoiceBilling] STT error: $error');
          }
        },
      );

      if (!available) {
        _showSnack(
          'Microphone or speech recognition is unavailable on this device.',
          isError: true,
        );
        return;
      }

      _hasInitializedStt = true;
    }

    setState(() {
      _isListening = true;
      _finalResultHandled = false;
      _transcript = '';
      _lastFinalTranscript = '';
      _lastCommittedText = '';
      _transcriptCtrl.clear();
      _parseWarnings = [];
      ParsedItems = List.from(_committedItems);
    });

    final cfg = getConfig(_selectedLang.code);

    try {
      await _speech.listen(
        localeId: cfg.localeId,
        onResult: (result) {
          if (!mounted) return;

          final raw = result.recognizedWords.trim();
          final normalized = raw.isEmpty
              ? ''
              : PhoneticNormalizer.normalize(
                  raw,
                  _selectedLang.code,
                );

          setState(() {
            _transcript = normalized;
            _transcriptCtrl.text = normalized;
          });

          if (normalized.isNotEmpty) {
            _lastFinalTranscript = normalized;
          }

          if (result.finalResult && normalized.isNotEmpty && !_finalResultHandled) {
            _finalResultHandled = true;
            _doProcess(normalized, commit: true);
          }
        },
        listenFor: cfg.listenFor,
        pauseFor: cfg.pauseFor,
        partialResults: true,
        cancelOnError: true,
        listenMode: cfg.listenMode,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isListening = false);
        _showSnack('Could not start the microphone. Please try again.', isError: true);
      }
      if (kDebugMode) {
        debugPrint('🎙️ [VoiceBilling] listen failed: $e');
      }
    }
  }

  Future<void> _doProcess(String text, {bool commit = false}) async {
    if (text.trim().isEmpty) return;
    if (_isProcessing && !commit) return;

    if (mounted) {
      setState(() => _isProcessing = true);
    }

    await (_catalogLoadFuture ?? Future<void>.value());

    if (!_catalogReady) {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
      _showSnack('Product catalog could not be loaded. Please retry.', isError: true);
      return;
    }

    try {
      var clean = PhoneticNormalizer.normalize(
        text.trim(),
        _selectedLang.code,
      );

      if (commit) {
        clean = await VoiceFeedbackLearningService.applyLearnedCorrections(
          transcript: clean,
          languageCode: _selectedLang.code,
        );
      }

      final result = await ProductionVoiceBillingService.parse(
        transcript: clean,
        localeCode: _selectedLang.code,
        catalogService: _catalog,
        knownProducts: widget.knownProducts ?? const [],
      );

      final items = result.lines
          .map(
            (line) => ParsedItem(
              name: line.name,
              qty: line.quantity,
              unit: line.unit,
              price: line.price,
              confidence: line.confidence,
              catalogMatched: line.catalogMatched,
              priceSource: line.priceSource,
              barcode: line.barcode,
              gst: line.gst,
              priceWarning: line.priceWarning,
              isConfirmed: line.confidence >= 0.6 || line.catalogMatched,
            ),
          )
          .toList();

      _parseWarnings = result.warnings;
      _lastPreviewItems = List<ParsedItem>.from(items);
      _clearEditControllers();

      if (commit) {
        _committedItems = _mergeParsedItems(_committedItems, items);
        ParsedItems = List<ParsedItem>.from(_committedItems);
        _lastFinalTranscript = clean;
        _transcript = '';
        _transcriptCtrl.clear();

        if (_committedItems.isEmpty) {
          _showSnack(
            result.warnings.isNotEmpty
                ? result.warnings.first
                : 'I could not understand that bill.',
            isError: true,
          );
        } else {
          _showSnack(
            'Detected ${_committedItems.length} item${_committedItems.length == 1 ? '' : 's'}. Review before adding to the bill.',
          );
        }
      } else {
        ParsedItems = List<ParsedItem>.from(items);
      }

      if (mounted) {
        setState(() => _isProcessing = false);
      }
    } catch (e, stackTrace) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _parseWarnings = ['Voice processing failed. Please retry.'];
        });
        _showSnack('Voice processing failed. Please retry.', isError: true);
      }
      if (kDebugMode) {
        debugPrint('🎙️ [VoiceBilling] processing failed: $e');
        debugPrint(stackTrace.toString());
      }
    }
  }

  List<ParsedItem> _mergeParsedItems(
    List<ParsedItem> existingItems,
    List<ParsedItem> incomingItems,
  ) {
    final merged = <ParsedItem>[...existingItems];

    for (final item in incomingItems) {
      final idx = merged.indexWhere(
        (current) =>
            current.name.trim().toLowerCase() == item.name.trim().toLowerCase() &&
            current.unit.trim().toLowerCase() == item.unit.trim().toLowerCase() &&
            ((current.price <= 0 || item.price <= 0) ||
                (current.price - item.price).abs() < 0.01),
      );

      if (idx < 0) {
        merged.add(item);
        continue;
      }

      final current = merged[idx];
      merged[idx] = ParsedItem(
        name: current.name,
        qty: current.qty + item.qty,
        unit: current.unit.isNotEmpty ? current.unit : item.unit,
        price: item.price > 0 ? item.price : current.price,
        confidence: current.confidence > item.confidence
            ? current.confidence
            : item.confidence,
        catalogMatched: current.catalogMatched || item.catalogMatched,
        priceSource: item.price > 0 ? item.priceSource : current.priceSource,
        barcode: current.barcode ?? item.barcode,
        gst: current.gst ?? item.gst,
        priceWarning: current.priceWarning ?? item.priceWarning,
        isConfirmed: current.isConfirmed || item.isConfirmed,
      );
    }

    return merged;
  }

  /// Final billing safety gate.
  ///
  /// The NLP parser remains permissive for preview. Before anything reaches
  /// the actual bill we require:
  /// - positive quantity
  /// - either explicit cashier confirmation, a catalog match, or solid confidence
  /// - canonicalization through the store catalog whenever available
  /// Price may remain blank when the catalog has no price so the normal bill
  /// editor can request it explicitly before the sale is saved.
  List<ParsedItem> _finalizeBillingItems(List<ParsedItem> candidates) {
    final safe = <ParsedItem>[];
    var rejectedCount = 0;

    for (final item in candidates) {
      if (item.name.trim().isEmpty || item.qty <= 0) {
        rejectedCount++;
        continue;
      }

      final catalogMatch = _catalog.findBest(
        item.name,
        minScore: 0.62,
      );
      final catalogConfirmed = catalogMatch != null || item.catalogMatched;
      final confidenceConfirmed = item.confidence >= 0.55;

      if (!item.isConfirmed && !catalogConfirmed && !confidenceConfirmed) {
        rejectedCount++;
        continue;
      }

      safe.add(
        ParsedItem(
          name: catalogMatch?.canonicalName ?? item.name.trim(),
          qty: item.qty,
          unit: item.unit,
          price: item.price,
          confidence: item.confidence,
          catalogMatched: catalogConfirmed,
          priceSource: item.priceSource,
          barcode: item.barcode,
          gst: item.gst,
          priceWarning: item.priceWarning,
          isConfirmed: true,
        ),
      );
    }

    if (rejectedCount > 0 && kDebugMode) {
      debugPrint(
        '🎙️ [VOICE] Final billing gate rejected ${rejectedCount} low-confidence items',
      );
    }

    return safe;
  }

  void _confirmOrder() {
    for (int i = 0; i < ParsedItems.length; i++) {
      final m = _editControllers[i];
      if (m == null) continue;

      final newQty =
          double.tryParse(m['qty']!.text.trim()) ?? ParsedItems[i].qty;
      final newPrice =
          double.tryParse(m['price']!.text.trim()) ?? ParsedItems[i].price;
      final editedName = m['name']!.text.trim();
      final originalName = ParsedItems[i].name;

      if (editedName.isNotEmpty &&
          editedName.toLowerCase() != originalName.toLowerCase()) {
        VoiceFeedbackLearningService.recordCorrection(
          originalTranscript: originalName,
          correctedItemName: editedName,
          languageCode: _selectedLang.code,
          originalConfidence: ParsedItems[i].confidence,
        );
      }

      ParsedItems[i] = ParsedItem(
        name: editedName.isEmpty ? originalName : editedName,
        qty: newQty,
        unit: ParsedItems[i].unit,
        price: newPrice,
        confidence: ParsedItems[i].confidence,
        catalogMatched: ParsedItems[i].catalogMatched,
        priceSource: newPrice > 0 ? 'manual' : ParsedItems[i].priceSource,
        barcode: ParsedItems[i].barcode,
        gst: ParsedItems[i].gst,
        priceWarning: ParsedItems[i].priceWarning,
        isConfirmed: editedName.isNotEmpty && newQty > 0,
      );
    }

    final uniqueItems = _mergeParsedItems(const [], ParsedItems);
    final confirmed = _finalizeBillingItems(uniqueItems);

    if (confirmed.isEmpty) {
      _showSnack(
        _parseWarnings.isNotEmpty
            ? _parseWarnings.first
            : 'No valid items selected.',
        isError: true,
      );
      return;
    }

    final avgConfidence = confirmed.isEmpty
        ? 0.0
        : confirmed.map((e) => e.confidence).reduce((a, b) => a + b) /
            confirmed.length;

    VoiceFeedbackLearningService.recordAccuracyMetrics(
      languageCode: _selectedLang.code,
      usedCloudSTT: false,
      sttConfidence: avgConfidence,
      nlpConfidence: avgConfidence,
      itemsCorrect: confirmed.length,
      itemsTotal: ParsedItems.length,
    );

    widget.onOrderParsed(confirmed.map((e) => e.toMap()).toList());
    _showSnack(
      '✅ ${confirmed.length} item${confirmed.length == 1 ? '' : 's'} added to bill.',
    );

    if (mounted) {
      setState(() {
        ParsedItems = [];
        _committedItems = [];
        _lastPreviewItems = [];
        _parseWarnings = [];
        _transcript = '';
        _transcriptCtrl.clear();
        _clearEditControllers();
      });
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.deepOrange : const Color(0xFF00C853),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: _isListening
              ? const Color(0xFF6366F1).withValues(alpha: 0.42)
              : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF334155).withValues(alpha: 0.08),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          _buildLanguageSelector(),
          const Divider(color: Color(0xFF2A3A5C), height: 1),
          LanguageDetectionVisualizer(
            transcript: _transcript,
            selectedLocale: _selectedLang.code,
            parsedItems: ParsedItems.map((e) => e.toMap()).toList(),
            isListening: _isListening,
          ),
          _buildTranscriptBox(),
          _buildMicButton(),
          if (ParsedItems.isNotEmpty) ...[
            const Divider(color: Color(0xFF2A3A5C), height: 1),
            _buildParsedItems(),
            _buildConfirmBar(),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2FF),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: Color(0xFF4F46E5),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI Voice Billing',
                style: GoogleFonts.inter(
                  color: const Color(0xFF111827),
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Speak naturally. Review before billing.',
                style: GoogleFonts.inter(
                  color: const Color(0xFF64748B),
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Live indicator
          if (_isListening)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildBlinkDot(),
                  const SizedBox(width: 5),
                  Text(
                    'Listening',
                    style: GoogleFonts.inter(
                      color: const Color(0xFF4F46E5),
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBlinkDot() {
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color.lerp(
            const Color(0xFFFF3D71),
            Colors.transparent,
            _pulseCtrl.value,
          ),
        ),
      ),
    );
  }

  Widget _buildLanguageSelector() {
    return SizedBox(
      height: 42,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: _languages.length,
        itemBuilder: (_, i) {
          final lang = _languages[i];
          final selected = lang.code == _selectedLang.code;
          return GestureDetector(
            onTap: () {
              setState(() => _selectedLang = lang);
              _updateHint();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF1565C0)
                    : const Color(0xFF1B2838),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? const Color(0xFF42A5F5) : const Color(0xFF2A3A5C),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(lang.flag, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 5),
                  Text(lang.label,
                    style: GoogleFonts.rajdhani(
                      color: selected ? Colors.white : const Color(0xFF7986CB),
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    )),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTranscriptBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Icon(
                  Icons.record_voice_over_rounded,
                  size: 16,
                  color: Color(0xFF6366F1),
                ),
                const SizedBox(width: 7),
                Text(
                  'What I heard',
                  style: GoogleFonts.inter(
                    color: const Color(0xFF374151),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (!_isListening &&
                    _transcriptCtrl.text.isNotEmpty &&
                    !_isProcessing)
                  TextButton(
                    onPressed: () => _doProcess(_transcriptCtrl.text),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF4F46E5),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Process',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _transcriptCtrl,
              style: GoogleFonts.inter(
                color: const Color(0xFF111827),
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                hintText: _hint,
                hintStyle: GoogleFonts.inter(
                  color: const Color(0xFF94A3B8),
                  fontStyle: FontStyle.italic,
                  fontSize: 12,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              maxLines: null,
              onChanged: (val) {
                _transcript = val;
              },
              onSubmitted: (val) {
                _doProcess(val);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMicButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: GestureDetector(
          onTap: _isProcessing ? null : _toggleListening,
          child: AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, __) {
              final scale = _isListening ? _pulseAnim.value : 1.0;
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: _isListening
                          ? const [Color(0xFF7C3AED), Color(0xFF4F46E5)]
                          : const [Color(0xFF4F46E5), Color(0xFF6366F1)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _isListening
                            ? const Color(0xFF6366F1).withValues(alpha: 0.28)
                            : const Color(0xFF6366F1).withValues(alpha: 0.16),
                        blurRadius: _isListening ? 28 : 16,
                        spreadRadius: _isListening ? 4 : 0,
                      ),
                    ],
                  ),
                  child: Icon(
                    _isProcessing
                        ? Icons.hourglass_empty_rounded
                        : (_isListening ? Icons.stop_rounded : Icons.mic_rounded),
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildParsedItems() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_parseWarnings.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: Color(0xFFD97706),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Please verify',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: const Color(0xFF92400E),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ..._parseWarnings.take(3).map(
                  (warning) => Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '• $warning',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: const Color(0xFF92400E),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text('DETECTED ITEMS',
            style: GoogleFonts.rajdhani(
              color: const Color(0xFF42A5F5),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            )),
        ),
        ...ParsedItems.asMap().entries.map((e) => _buildItemCard(e.key, e.value)),
      ],
    );
  }

  Widget _buildItemCard(int idx, ParsedItem item) {
    _editControllers.putIfAbsent(idx, () => {
      'name':  TextEditingController(text: item.name),
      'qty':   TextEditingController(text: item.qty.toString()),
      'price': TextEditingController(text: item.price.toString()),
    });

    final conf = item.confidence;
    final confHigh = conf >= 0.85;
    final confMed  = conf >= 0.60 && conf < 0.85;
    final lowConf  = conf < 0.60;  // 🔧 FIX: Define lowConf variable
    // < 0.60 = low confidence (red)
    final borderColor = confHigh
        ? const Color(0xFF00C853).withValues(alpha: 0.7)   // 🟢 Green - exact match
        : confMed
            ? const Color(0xFFFFC107).withValues(alpha: 0.7)  // 🟡 Yellow - fuzzy match
            : const Color(0xFFFF3D00).withValues(alpha: 0.7); // 🔴 Red - needs check
    final bgTint = confHigh
        ? const Color(0xFF00C853).withValues(alpha: 0.04)
        : confMed
            ? const Color(0xFFFFC107).withValues(alpha: 0.04)
            : const Color(0xFFFF3D00).withValues(alpha: 0.06);
    final confLabel = confHigh ? '✓ ${(conf * 100).toInt()}%'
        : confMed ? '~ ${(conf * 100).toInt()}%'
        : '! ${(conf * 100).toInt()}%';
    final confLabelColor = confHigh ? const Color(0xFF00C853)
        : confMed ? const Color(0xFFFFC107)
        : const Color(0xFFFF3D00);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: Color.lerp(const Color(0xFF0F1F38), bgTint, 1.0),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: 1.5),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: GestureDetector(
            onTap: () => setState(() => item.isConfirmed = !item.isConfirmed),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: item.isConfirmed
                    ? const Color(0xFF10B981)
                    : const Color(0xFFF1F5F9),
                border: Border.all(
                  color: item.isConfirmed ? const Color(0xFF10B981) : const Color(0xFFCBD5E1),
                  width: 1.5,
                ),
              ),
              child: item.isConfirmed
                  ? const Icon(Icons.check, color: Colors.white, size: 16)
                  : null,
            ),
          ),
          title: TextField(
            controller: _editControllers[idx]!['name'],
            style: GoogleFonts.inter(color: const Color(0xFF111827), fontSize: 13, fontWeight: FontWeight.w800),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
            ),
          ),
          subtitle: Row(
            children: [
              _miniField('Qty', _editControllers[idx]!['qty']!),
              Text(' ${item.unit}  ·  ₹',
                style: GoogleFonts.rajdhani(color: const Color(0xFF546E7A), fontSize: 12)),
              _miniField('Price', _editControllers[idx]!['price']!),
              if (lowConf) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Low confidence — please verify',
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: const Color(0xFFFF6D00),
                    size: 14,
                  ),
                ),
              ],
              if (item.price <= 0) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Price not found. Enter it in the bill before saving.',
                  child: const Icon(
                    Icons.price_check_rounded,
                    color: Color(0xFFF59E0B),
                    size: 14,
                  ),
                ),
              ],
              if (item.priceWarning != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: item.priceWarning!,
                  child: const Icon(
                    Icons.report_problem_outlined,
                    color: Color(0xFFEF4444),
                    size: 14,
                  ),
                ),
              ],
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFF546E7A), size: 18),
            onPressed: () => setState(() => ParsedItems.removeAt(idx)),
          ),
        ),
      ),
    );
  }

  Widget _miniField(String hint, TextEditingController ctrl) {
    return SizedBox(
      width: 52,
      child: TextField(
        controller: ctrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: GoogleFonts.rajdhani(color: const Color(0xFF82B1FF), fontSize: 13, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.zero,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: GoogleFonts.rajdhani(color: const Color(0xFF37474F), fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildConfirmBar() {
    final total = ParsedItems
        .where((e) => e.isConfirmed)
        .fold<double>(0, (s, e) => s + e.qty * e.price);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${ParsedItems.where((e) => e.isConfirmed).length} selected',
                style: GoogleFonts.rajdhani(color: const Color(0xFF7986CB), fontSize: 12)),
              Text('₹${total.toStringAsFixed(2)}',
                style: GoogleFonts.rajdhani(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                )),
            ],
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              ParsedItems = [];
              _committedItems = [];
              _lastPreviewItems = [];
              _lastCommittedText = '';
              _transcript = '';
              _lastFinalTranscript = '';
              _transcriptCtrl.clear();
            }),
            child: Text('Clear', style: GoogleFonts.rajdhani(color: const Color(0xFF546E7A), fontSize: 14)),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _confirmOrder,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            ),
            child: Text(
            'Add to Bill',
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          ),
        ],
      ),
    );
  }
}