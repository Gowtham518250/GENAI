import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:retail_mind/crash_recovery_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'incomplete_transactions': jsonEncode([
        {
          'type': 'not_yet_supported',
          'data': {'operation_id': 'keep-this-record'},
          'timestamp': '2026-10-10T00:00:00Z',
        },
      ]),
    });
  });

  test('retains recovery entries that could not be recovered', () async {
    await CrashRecoveryService.instance.recoverIncompleteTransactionsForTesting();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('incomplete_transactions');
    expect(raw, isNotNull);

    final entries = jsonDecode(raw!) as List<dynamic>;
    expect(entries, hasLength(1));
    expect(entries.single['type'], 'not_yet_supported');
    expect(entries.single['data']['operation_id'], 'keep-this-record');
  });

  test('removes the recovery key only when there is nothing left to retry', () async {
    SharedPreferences.setMockInitialValues({'incomplete_transactions': '[]'});

    await CrashRecoveryService.instance.recoverIncompleteTransactionsForTesting();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('incomplete_transactions'), isNull);
  });
}
