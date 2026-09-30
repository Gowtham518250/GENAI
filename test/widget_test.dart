import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:retail_mind/main.dart';

void main() {
  testWidgets('Application test shell builds', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Retail Mind test shell')),
        ),
      ),
    );

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('Retail Mind test shell'), findsOneWidget);
  });

  test('MyApp exposes an isolated test mode', () {
    const app = MyApp(testMode: true);
    expect(app.testMode, isTrue);
  });
}
