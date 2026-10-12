import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/bank_reconciliation.dart';

void main() {
  group('Bank statement transaction parsing', () {
    test('extracts incoming UPI credit, counterparty and received amount', () {
      final entries = BankStatementParser.parseText(
        'HDFC BANK STATEMENT\n'
        '07/04/26 UPI-RahulSharma-9876543210 Cr 1,500.00\n',
      );

      expect(entries, hasLength(1));
      expect(entries.first.direction, 'CREDIT');
      expect(entries.first.amount, 1500.0);
      expect(entries.first.receivedAmount, 1500.0);
      expect(entries.first.paidAmount, 0.0);
      expect(entries.first.counterparty.toLowerCase(), contains('rahul'));
      expect(entries.first.bankName, 'HDFC');
      expect(entries.first.date, DateTime(2026, 4, 7));
    });

    test('extracts outgoing UPI debit and the payee name', () {
      final entries = BankStatementParser.parseText(
        'ICICI BANK\n'
        '08/04/2026 UPI/DR/12345678/Swiggy/food@upi Dr 250.00\n',
      );

      expect(entries, hasLength(1));
      expect(entries.first.direction, 'DEBIT');
      expect(entries.first.amount, 250.0);
      expect(entries.first.receivedAmount, 0.0);
      expect(entries.first.paidAmount, 250.0);
      expect(entries.first.counterparty.toLowerCase(), contains('swiggy'));
      expect(entries.first.reference, '12345678');
      expect(entries.first.bankName, 'ICICI');
    });

    test('supports searching extracted rows using counterparty, reference and raw text', () {
      final entries = BankStatementParser.parseText(
        'SBI BANK\n'
        '07-04-2026 TO TRANSFER-UPI/CR/12345678/AnilKumar Cr 450.00\n'
        '08-04-2026 TO TRANSFER-UPI/DR/22345678/MarketShop Dr 120.00\n',
      );

      expect(entries, hasLength(2));
      expect(entries.where((entry) => entry.counterparty.toLowerCase().contains('anil')), hasLength(1));
      expect(entries.where((entry) => entry.rawLine.toLowerCase().contains('marketshop')), hasLength(1));
      expect(entries.fold<double>(0, (sum, entry) => sum + entry.receivedAmount), 450.0);
      expect(entries.fold<double>(0, (sum, entry) => sum + entry.paidAmount), 120.0);
    });

    test('does not guess ambiguous direction or malformed dates', () {
      final entries = BankStatementParser.parseText(
        'UPI STATEMENT\n'
        '09/04/2026 UPI/12345678/Rahul 300.00\n'
        '44/19/2026 UPI/CR/12345678/Rahul Cr 300.00\n',
      );

      expect(entries, isEmpty);
    });

    test('keeps amount positive and separates money flow using direction', () {
      final credit = BankEntry(
        date: DateTime(2026, 4, 7),
        amount: 5,
        reference: 'UTR12345678',
        rawLine: 'credit',
        direction: 'CREDIT',
      );
      final debit = BankEntry(
        date: DateTime(2026, 4, 7),
        amount: 2,
        reference: 'UTR87654321',
        rawLine: 'debit',
        direction: 'DEBIT',
      );

      expect(credit.receivedAmount, 5.0);
      expect(credit.paidAmount, 0.0);
      expect(debit.receivedAmount, 0.0);
      expect(debit.paidAmount, 2.0);
    });

    test('joins PDF table cells split across lines and keeps credit/debit separate', () {
      final entries = BankStatementParser.parseText(
        'HDFC BANK STATEMENT\\n'
        'Transaction Date Value Date Description Amount Balance\\n'
        '07/04/26\\n'
        '07/04/26\\n'
        'UPI-RahulSharma-9876543210\\n'
        'Cr\\n'
        '1,500.00\\n'
        '20,000.00\\n'
        '08/04/26\\n'
        '08/04/26\\n'
        'UPI/DR/12345678/Swiggy/food@upi Dr\\n'
        '250.00\\n'
        '19,750.00\\n',
      );

      expect(entries, hasLength(2));
      expect(entries.first.direction, 'DEBIT');
      expect(entries.first.amount, 250.0);
      expect(entries.last.direction, 'CREDIT');
      expect(entries.last.amount, 1500.0);
      expect(entries.last.counterparty.toLowerCase(), contains('rahul'));
    });

    test('answers credited amount and phone questions from local statement rows', () {
      final rows = [
        {
          'date': '2026-04-07T00:00:00',
          'amount': 1500.0,
          'direction': 'CREDIT',
          'counterparty': 'Rahul Sharma',
          'description': 'UPI-RahulSharma-9876543210',
          'rawLine': '07/04/26 UPI-RahulSharma-9876543210 Cr 1,500.00',
          'reference': 'UTR12345678',
          'bankName': 'HDFC',
        },
        {
          'date': '2026-04-08T00:00:00',
          'amount': 250.0,
          'direction': 'DEBIT',
          'counterparty': 'Swiggy',
          'description': 'UPI/DR/12345678/Swiggy/food@upi',
          'rawLine': '08/04/2026 UPI/DR/12345678/Swiggy/food@upi Dr 250.00',
          'reference': '12345678',
          'bankName': 'ICICI',
        },
      ];

      final credit = BankStatementQueryHelper.answerQuestion(
        'How much was credited by Rahul?',
        rows,
      );
      expect(credit, isNotNull);
      expect(credit!['answer'], contains('₹1500.00'));
      expect(credit['transactions_found'], 1);

      final details = BankStatementQueryHelper.answerQuestion(
        'Show details paid to Swiggy',
        rows,
      );
      expect(details, isNotNull);
      expect(details!['answer'], contains('PAID ₹250.00'));
      expect(details['results'], hasLength(1));

      final unrelated = BankStatementQueryHelper.answerQuestion(
        'What were my total shop sales?',
        rows,
      );
      expect(unrelated, isNull);
    });
  });
}
