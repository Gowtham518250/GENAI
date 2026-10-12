import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/features/ai_query/models/ai_query_response.dart';
import 'package:retail_mind/features/ai_query/widgets/ai_answer_card.dart';
import 'package:retail_mind/features/ai_query/widgets/dashboard_ai_card.dart';
import 'package:retail_mind/features/ai_query/widgets/query_input.dart';
import 'package:retail_mind/features/ai_query/widgets/result_card.dart';
import 'package:retail_mind/features/ai_query/widgets/suggestion_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:retail_mind/features/ai_query/services/ai_query_service.dart';
import 'package:retail_mind/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AIQueryResponse Model Tests', () {
    test('parses full backend response with all fields', () {
      final json = {
        'query_engine_version': '2026-09-29-date-aware-sales-v2',
        'query': 'How many sales did I make today?',
        'generated_sql': 'SELECT COUNT(*) as sales_count FROM sales WHERE user_id = :user_id',
        'generated_model_response': 'You made 18 sales today.',
        'retrieved_table_information': ['sales', 'invoices'],
        'sql': 'SELECT COUNT(*) as sales_count FROM sales WHERE user_id = :user_id',
        'results': [
          {'sales_count': 18}
        ],
      };

      final response = AIQueryResponse.fromJson(json);

      expect(response.isSuccess, isTrue);
      expect(response.queryEngineVersion, '2026-09-29-date-aware-sales-v2');
      expect(response.query, 'How many sales did I make today?');
      expect(response.generatedModelResponse, 'You made 18 sales today.');
      expect(response.displayAnswer, 'You made 18 sales today.');
      expect(response.effectiveSql, 'SELECT COUNT(*) as sales_count FROM sales WHERE user_id = :user_id');
      expect(response.hasSql, isTrue);
      expect(response.hasResults, isTrue);
      expect(response.isSingleKpi, isTrue);
      expect(response.results.length, 1);
      expect(response.results.first['sales_count'], 18);
    });

    test('parses response with fallback fields and nulls safely', () {
      final json = {
        'query': 'What is my revenue?',
        'answer': 'Your revenue is ₹12,450',
        'data': [
          {'total_sales_amount': 12450}
        ],
      };

      final response = AIQueryResponse.fromJson(json);

      expect(response.isSuccess, isTrue);
      expect(response.displayAnswer, 'Your revenue is ₹12,450');
      expect(response.hasResults, isTrue);
      expect(response.isSingleKpi, isTrue);
      expect(response.hasSql, isFalse);
    });

    test('prefers the grounded answer over raw SQL for display and TTS', () {
      final response = AIQueryResponse.fromJson({
        'query': "Tell me today's total profit",
        'answer': "Today's recorded net profit is ₹1,250.00.",
        'generated_model_response':
            'TABLE: sales\\n\\nSQL:\\nSELECT product_name, SUM(total) FROM sales WHERE product_name ILIKE \'%fish%\';',
        'generated_sql':
            'SELECT product_name, SUM(total) FROM sales WHERE product_name ILIKE \'%fish%\';',
        'results': [
          {'net_profit': 1250.0}
        ],
      });

      expect(response.displayAnswer, "Today's recorded net profit is ₹1,250.00.");
      expect(response.displayAnswer, isNot(contains('SELECT')));
      expect(response.displayAnswer, isNot(contains('fish')));
      expect(response.effectiveSql, contains('SELECT'));
    });

    test('synthesizes answer when generated_model_response is empty', () {
      final json = {
        'query': 'Total sales',
        'results': [
          {'sales_count': 42}
        ],
      };

      final response = AIQueryResponse.fromJson(json);

      expect(response.isSuccess, isTrue);
      expect(response.displayAnswer, contains('sales count: 42'));
    });

    test('constructs error response properly', () {
      final errorResponse = AIQueryResponse.error(
        'No internet connection. Please check your connection.',
        query: 'sales today',
      );

      expect(errorResponse.isSuccess, isFalse);
      expect(errorResponse.errorMessage, 'No internet connection. Please check your connection.');
      expect(errorResponse.displayAnswer, 'No internet connection. Please check your connection.');
      expect(errorResponse.hasResults, isFalse);
    });
  });


  group('Business and product endpoint separation', () {
    test('business questions and product discovery use separate endpoints', () {
      expect(ApiClient.askQueryEndpoint, '/askquery');
      expect(
        ApiClient.askQueryProductDiscoveryEndpoint,
        '/askquery/product-discovery',
      );
      expect(
        ApiClient.askQueryEndpoint,
        isNot(ApiClient.askQueryProductDiscoveryEndpoint),
      );
    });

    test('parses online offers and nearby shops as structured discovery data', () {
      final response = AIQueryResponse.fromJson({
        'query': 'I need ghee',
        'answer': 'I found online listings for ghee.',
        'product_discovery': {
          'product_query': 'ghee',
          'location_available': true,
          'online_offers': [
            {'title': 'Ghee 1L', 'source': 'Seller A', 'price': 599.0}
          ],
          'nearby_shops': [
            {'name': 'Nearby Grocery', 'distance_km': 0.8, 'price': null}
          ],
        },
        'results': [],
      });

      expect(response.isSuccess, isTrue);
      expect(response.productDiscovery?['product_query'], 'ghee');
      expect((response.productDiscovery?['online_offers'] as List).length, 1);
      expect((response.productDiscovery?['nearby_shops'] as List).first['name'], 'Nearby Grocery');
      expect(response.results, isEmpty);
    });
  });


  group('ResultCard & Data Formatting Tests', () {
    testWidgets('renders KPI Card for single metric result', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ResultCard(
              results: [
                {'total_sales_amount': 12450}
              ],
              queryContext: 'Today',
            ),
          ),
        ),
      );

      expect(find.text('TOTAL SALES AMOUNT'), findsOneWidget);
      expect(find.text('₹12,450'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('renders DataTable for multi-row results', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ResultCard(
              results: [
                {'customer_name': 'Alice', 'total_amount': 5000},
                {'customer_name': 'Bob', 'total_amount': 3500},
              ],
            ),
          ),
        ),
      );

      expect(find.text('Result Details'), findsOneWidget);
      expect(find.text('2 rows'), findsOneWidget);
      expect(find.text('Customer Name'), findsOneWidget);
      expect(find.text('Total Amount'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('₹5,000'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('₹3,500'), findsOneWidget);
    });
  });

  group('Query History Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('saves and retrieves query history up to 20 items deduplicated', () async {
      await AiQueryService.saveQueryToHistory('Sales today');
      await AiQueryService.saveQueryToHistory('Top customers');
      await AiQueryService.saveQueryToHistory('Sales today'); // Re-insert to promote to top

      final history = await AiQueryService.getQueryHistory();

      expect(history.length, 2);
      expect(history.first, 'Sales today');
      expect(history[1], 'Top customers');

      // Test removal
      await AiQueryService.removeHistoryItem('Top customers');
      final updatedHistory = await AiQueryService.getQueryHistory();
      expect(updatedHistory.length, 1);
      expect(updatedHistory.first, 'Sales today');

      // Test clear
      await AiQueryService.clearQueryHistory();
      final clearedHistory = await AiQueryService.getQueryHistory();
      expect(clearedHistory, isEmpty);
    });
  });

  group('Widget Tests', () {
    testWidgets('SuggestedQuestionsBar renders chips and triggers callback', (tester) async {
      String? selectedQuery;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SuggestedQuestionsBar(
              onSuggestionSelected: (q) => selectedQuery = q,
            ),
          ),
        ),
      );

      expect(find.text('Suggested Questions'), findsOneWidget);
      expect(find.text('Sales today'), findsOneWidget);
      expect(find.text('Revenue today'), findsOneWidget);

      await tester.tap(find.text('Sales today'));
      await tester.pump();

      expect(selectedQuery, 'How many sales did I make today?');
    });

    testWidgets('QueryInputCard submits text and handles clear', (tester) async {
      final controller = TextEditingController();
      String? submittedText;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QueryInputCard(
              controller: controller,
              onSubmit: (t) => submittedText = t,
            ),
          ),
        ),
      );

      // Enter text
      await tester.enterText(find.byType(TextField), 'Show my sales');
      await tester.pump();

      // Submit via button
      await tester.tap(find.text('Ask'));
      await tester.pump();

      expect(submittedText, 'Show my sales');

      // Clear button
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();

      expect(controller.text, isEmpty);
    });

    testWidgets('AIAnswerCard renders answer and toggles technical details', (tester) async {
      final response = AIQueryResponse(
        query: 'What is my total sales today?',
        generatedModelResponse: 'Your total sales today is ₹12,450.',
        sql: 'SELECT SUM(total) FROM sales WHERE user_id = :user_id',
        queryEngineVersion: '2026-09-29-date-aware-sales-v2',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AIAnswerCard(response: response),
            ),
          ),
        ),
      );

      expect(find.text('"What is my total sales today?"'), findsOneWidget);
      expect(find.text('Your total sales today is ₹12,450.'), findsOneWidget);

      // SQL hidden initially
      expect(find.text('Show Technical Details'), findsOneWidget);
      expect(find.text('GENERATED SQL QUERY'), findsNothing);

      // Tap to expand
      await tester.tap(find.text('Show Technical Details'));
      await tester.pumpAndSettle();

      expect(find.text('GENERATED SQL QUERY'), findsOneWidget);
      expect(find.text('SELECT SUM(total) FROM sales WHERE user_id = :user_id'), findsOneWidget);
      expect(find.text('2026-09-29-date-aware-sales-v2'), findsOneWidget);
    });

    testWidgets('DashboardAiQueryCard renders and triggers callback', (tester) async {
      bool tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardAiQueryCard(
              onTap: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text('Ask Retail Mind'), findsOneWidget);
      expect(find.text('Ask AI'), findsOneWidget);

      await tester.tap(find.text('Ask AI'));
      await tester.pump();

      expect(tapped, isTrue);
    });
  });
}
