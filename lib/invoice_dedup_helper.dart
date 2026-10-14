/// Identity-based reconciliation for invoice mirrors and restored sales.
///
/// A bill can exist as a local sale, a local invoice and a cloud-restored row.
/// Use all stable identifiers and merge connected alias groups; never merge
/// separate transactions merely because their amounts or contents look alike.
class InvoiceDedupHelper {
  static const List<String> _transactionFields = <String>[
    'invoice_number',
    'number',
    'sale_id',
    'offline_id',
  ];

  static const List<String> _backendIdFields = <String>[
    'invoice_id',
    'backend_id',
    'invoiceId',
    'id',
  ];

  static double _number(dynamic value, [double fallback = 0]) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static String _normalized(dynamic value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text.isEmpty || text == 'null' || text == '0') return '';
    return text;
  }

  static Set<String> identityTokens(Map<String, dynamic> row) {
    final tokens = <String>{};

    for (final field in _transactionFields) {
      final value = _normalized(row[field]);
      if (value.isNotEmpty) tokens.add('transaction:' + value);
    }

    for (final field in _backendIdFields) {
      final value = _normalized(row[field]);
      if (value.isEmpty) continue;

      final isNumericId = value.codeUnits.every(
        (code) => code >= 48 && code <= 57,
      );
      if (isNumericId) {
        // Namespaces prevent invoice number "12" matching database id 12.
        tokens.add('backend:' + value);
      } else {
        // Legacy clients sometimes put the customer-facing bill number in id fields.
        tokens
          ..add('backend:' + value)
          ..add('transaction:' + value);
      }
    }

    return tokens;
  }

  static bool sameInvoice(
    Map<String, dynamic> left,
    Map<String, dynamic> right,
  ) {
    final leftTokens = identityTokens(left);
    if (leftTokens.isEmpty) return false;
    return leftTokens.intersection(identityTokens(right)).isNotEmpty;
  }

  static int _timestamp(dynamic value) {
    if (value is DateTime) return value.millisecondsSinceEpoch;
    if (value is num) return value.toInt();
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return 0;
    return DateTime.tryParse(text)?.millisecondsSinceEpoch ?? 0;
  }

  static int _rowTimestamp(Map<String, dynamic> row) {
    return _timestamp(
      row['updated_at'] ??
          row['last_updated'] ??
          row['modified_at'] ??
          row['created_at'] ??
          row['invoice_date'] ??
          row['date'],
    );
  }

  static double _rowTotal(Map<String, dynamic> row) {
    for (final field in const <String>[
      'total_amount',
      'totalAmount',
      'total',
      'invoice_total',
      'grand_total',
      'final_amount',
      'amount',
    ]) {
      final value = _number(row[field], -1);
      if (value > 0) return value;
    }
    return 0;
  }

  static double _rowPaid(Map<String, dynamic> row, double total) {
    var paid = 0.0;
    for (final field in const <String>[
      'paid_amount',
      'amount_paid',
      'paid',
      'received_amount',
    ]) {
      final value = row[field];
      if (value != null) {
        final parsed = _number(value, -1);
        if (parsed > paid) paid = parsed;
      }
    }

    final paymentStatus = (row['payment_status'] ?? '')
        .toString()
        .split('.')
        .last
        .trim()
        .toUpperCase();
    final invoiceStatus = (row['status'] ?? '')
        .toString()
        .split('.')
        .last
        .trim()
        .toUpperCase();

    if (total > 0 &&
        paid <= 0 &&
        (paymentStatus == 'PAID' || invoiceStatus == 'PAID')) {
      // Some legacy rows say PAID but did not persist paid_amount.
      paid = total;
    }
    return paid.clamp(0.0, total).toDouble();
  }

  static Map<String, dynamic> _mergeGroup(
    List<Map<String, dynamic>> group,
  ) {
    final ordered = List<Map<String, dynamic>>.from(group)
      ..sort((a, b) => _rowTimestamp(a).compareTo(_rowTimestamp(b)));

    final merged = <String, dynamic>{};
    var highestPaid = 0.0;
    var newestTotal = 0.0;
    var anyPaymentState = false;

    for (final row in ordered) {
      final total = _rowTotal(row);
      if (total > 0) newestTotal = total;

      final paid = _rowPaid(row, total);
      if (paid > highestPaid) highestPaid = paid;

      final payStatus = (row['payment_status'] ?? row['status'] ?? '')
          .toString()
          .split('.')
          .last
          .trim()
          .toUpperCase();
      if (payStatus == 'PAID' ||
          payStatus == 'PARTIAL' ||
          payStatus == 'UNPAID') {
        anyPaymentState = true;
      }

      // Later records win, but blank/null values cannot erase useful aliases
      // or line items that only exist in an older local representation.
      for (final entry in row.entries) {
        final value = entry.value;
        if (value == null) continue;
        if (value is String && value.trim().isEmpty) continue;
        merged[entry.key] = value;
      }
    }

    if (newestTotal > 0) {
      final total = newestTotal;
      final paid = highestPaid.clamp(0.0, total).toDouble();
      final status = paid >= total - 0.01
          ? 'PAID'
          : (paid > 0 ? 'PARTIAL' : 'UNPAID');

      merged['total_amount'] = total;
      merged['paid_amount'] = double.parse(paid.toStringAsFixed(2));
      merged['pending_amount'] =
          (total - paid).clamp(0.0, double.infinity).toDouble();

      if (anyPaymentState || paid > 0) {
        merged['payment_status'] = status;
      }
      if (status == 'PAID' || status == 'PARTIAL') {
        merged['status'] = status;
      } else {
        final oldStatus = (merged['status'] ?? '')
            .toString()
            .split('.')
            .last
            .trim()
            .toUpperCase();
        if (oldStatus == 'PAID' || oldStatus == 'PARTIAL') {
          merged['status'] = 'UNPAID';
        }
      }
    }

    return merged;
  }

  static bool _intersectsLinkFields(
    Map<String, dynamic> left,
    List<String> leftFields,
    Map<String, dynamic> right,
    List<String> rightFields,
  ) {
    final leftValues = leftFields
        .map((field) => _normalized(left[field]))
        .where((value) => value.isNotEmpty)
        .toSet();
    if (leftValues.isEmpty) return false;
    return rightFields
        .map((field) => _normalized(right[field]))
        .any((value) => value.isNotEmpty && leftValues.contains(value));
  }

  /// A sale belongs in invoice analytics only when a field explicitly links
  /// it to an invoice. Never compare generic sale.id to generic invoice.id:
  /// those IDs come from different tables and can collide by coincidence.
  static bool _isSaleMirrorOfInvoice(
    Map<String, dynamic> invoice,
    Map<String, dynamic> sale,
  ) {
    // Foreign keys that explicitly identify the invoice from a sales row.
    if (_intersectsLinkFields(
      sale,
      const ['invoice_id', 'invoiceId', 'backend_invoice_id'],
      invoice,
      const ['id', 'invoice_id', 'invoiceId', 'backend_id', 'server_id'],
    )) {
      return true;
    }

    // The customer-facing bill number is another safe cross-table link.
    if (_intersectsLinkFields(
      sale,
      const ['invoice_number', 'invoice_no', 'bill_number', 'bill_no'],
      invoice,
      const ['invoice_number', 'invoice_no', 'bill_number', 'bill_no', 'number'],
    )) {
      return true;
    }

    // Offline transaction keys are valid only when the invoice row stores the
    // same key as a sale/source reference, not merely as its own database ID.
    if (_intersectsLinkFields(
      sale,
      const ['sale_id', 'offline_id', 'local_sale_id', 'source_sale_id', 'id'],
      invoice,
      const ['sale_id', 'offline_id', 'local_sale_id', 'source_sale_id', 'original_sale_id'],
    )) {
      return true;
    }

    return false;
  }

  /// Invoice Analytics is an invoice ledger, not the general sales ledger.
  /// Standalone retail sales remain in Sales reporting. Only sales with an
  /// explicit invoice foreign key/number or shared offline-sale key are merged
  /// as mirrors of a real invoice.
  static List<Map<String, dynamic>> canonicalizeInvoiceLedger(
    List<dynamic> invoices,
    List<dynamic> sales,
  ) {
    final invoiceRows = invoices
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();

    final saleRows = sales
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();

    final saleMirrors = saleRows.where((sale) =>
        invoiceRows.any((invoice) => _isSaleMirrorOfInvoice(invoice, sale)));

    return canonicalizeInvoices(<dynamic>[
      ...invoiceRows,
      ...saleMirrors,
    ]);
  }

  static List<Map<String, dynamic>> canonicalizeInvoices(
    List<dynamic> rawRows,
  ) {
    final rows = rawRows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();

    if (rows.length < 2) {
      return rows.map((row) => _mergeGroup(<Map<String, dynamic>>[row])).toList();
    }

    final parents = List<int>.generate(rows.length, (index) => index);

    int root(int value) {
      var index = value;
      while (parents[index] != index) {
        parents[index] = parents[parents[index]];
        index = parents[index];
      }
      return index;
    }

    void union(int left, int right) {
      final a = root(left);
      final b = root(right);
      if (a != b) parents[b] = a;
    }

    final tokenOwner = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      for (final token in identityTokens(rows[i])) {
        final previous = tokenOwner[token];
        if (previous == null) {
          tokenOwner[token] = i;
        } else {
          union(i, previous);
        }
      }
    }

    // Build groups only after all unions: one bridge row may connect two groups.
    final groups = <int, List<Map<String, dynamic>>>{};
    for (var i = 0; i < rows.length; i++) {
      groups.putIfAbsent(root(i), () => <Map<String, dynamic>>[]).add(rows[i]);
    }

    return groups.values
        .map((group) => _mergeGroup(group))
        .toList();
  }
}
