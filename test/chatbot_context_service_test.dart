import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:retail_mind/ai_features_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'shop_name': 'Test Kirana',
      'user_type': 'OWNER',
    });
  });

  test('chatbot greeting is built locally using saved shop context', () async {
    final greeting = await ChatbotContextService.getPersonalizedGreeting();

    expect(greeting, contains('Test Kirana'));
    expect(greeting, contains('Retail Mind'));
  });

  test('chatbot system prompt is built locally without a context API request', () async {
    final prompt = await ChatbotContextService.getChatbotSystemPrompt();

    expect(prompt, contains('Test Kirana'));
    expect(prompt, contains('OWNER'));
    expect(prompt, contains('authenticated Retail Mind query service'));
  });
}
