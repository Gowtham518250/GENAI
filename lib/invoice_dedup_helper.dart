/// Identity-based reconciliation for invoice mirrors and restored sales.
///
/// A single bill may exist in Hive as an invoice, a local sale, and a cloud
/// restore. Those records can expose different ID fields, so reconciliation
/// must use all stable aliases (and connected components), never amount/content
/// fingerprints. Distinct sales with identical content remain distinct.
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
      if (value.isNotEmpty) tokens.add('transaction:$value');
    }

    for (final field in _backendIdFields) {
      final value = _normalized(row[field]);
      if (value.isEmpty) continue;

      // Numeric IDs live in the backend-ID namespace. This prevents a bill
      // number like "12" accidentally matching database invoice id 12.
      final isNumericId = value.isNotEmpty && value.codeUnits.every((code) => code >= 48 && code <= 57);
      if (isNumericId) {
        tokens.add('backend:$value');
      } else {
        // Older clients sometimes store the bill number in invoice_id/id.
        // Keep the field alias as well as a transaction alias for those rows.
        tokens
          ..add('backend:$value')
          ..add('transaction:$value');
      }
    }

    return tokens;
  }

  /// True when two rows share at least one stable business identity alias.
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

    // Legacy rows sometimes say PAID without storing paid_amount. Treat that
    // as a fully settled invoice when its total is available.
    if (total > 0 &&
        paid <= 0 &&
        (paymentStatus == 'PAID' || invoiceStatus == 'PAID')) {
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
    var hasTotal = false;
    var anyPaymentState = false;

    for (final row in ordered) {
      final total = _rowTotal(row);
      if (total > 0 || !hasTotal) {
        newestTotal = total;
        hasTotal = true;
      }
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

      // Rows are timestamp-ordered; only useful values overwrite prior ones.
      // This retains identifiers/line items absent from the newest copy.
      for (final entry in row.entries) {
        final value = entry.value;
        if (value == null) continue;
        if (value is String && value.trim().isEmpty) continue;
        merged[entry.key] = value;
      }
    }

    if (hasTotal && newestTotal > 0) {
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

  /// Canonicalize duplicates through all aliases, including bridge rows that
  /// connect an old local sale ID to a backend invoice ID and invoice number.
  static List<Map<String, dynamic>> canonicalizeInvoices(
    List<dynamic> rawRows,
  ) {
    final rows = rawRows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    if (rows.length < 2) {
      return rows.map(_mergeGroup).toList();
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

    // Resolve roots after all unions. A later row may bridge two groups that
    // were previously separate, so groups must be assembled only after union.
    final groups = <int, List<Map<String, dynamic>>>{};
    for (var i = 0; i < rows.length; i++) {
      groups.putIfAbsent(root(i), () => <Map<String, dynamic>[]).add(rows[i]);
    }

    return groups.values.map(_mergeGroup).toList();
  }
}
).hasMatch(value)) {
        tokens.add('backend:$value');
      } else {
        // Older clients sometimes store the bill number in invoice_id/id.
        // Keep the field alias as well as a transaction alias for those rows.
        tokens
          ..add('backend:$value')
          ..add('transaction:$value');
      }
    }

    return tokens;
  }

  /// True when two rows share at least one stable business identity alias.
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
      if (value >= 0) return value;
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

    // Legacy rows sometimes say PAID without storing paid_amount. Treat that
    // as a fully settled invoice when its total is available.
    if (total > 0 &&
        paid <= 0 &&
        (paymentStatus == 'PAID' || invoiceStatus == 'PAID')) {
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
    var hasTotal = false;
    var anyPaymentState = false;

    for (final row in ordered) {
      final total = _rowTotal(row);
      if (total > 0 || !hasTotal) {
        newestTotal = total;
        hasTotal = true;
      }
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

      // Rows are timestamp-ordered; only useful values overwrite prior ones.
      // This retains identifiers/line items absent from the newest copy.
      for (final entry in row.entries) {
        final value = entry.value;
        if (value == null) continue;
        if (value is String && value.trim().isEmpty) continue;
        merged[entry.key] = value;
      }
    }

    if (hasTotal && newestTotal > 0) {
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

  /// Canonicalize duplicates through all aliases, including bridge rows that
  /// connect an old local sale ID to a backend invoice ID and invoice number.
  static List<Map<String, dynamic>> canonicalizeInvoices(
    List<dynamic> rawRows,
  ) {
    final rows = rawRows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    if (rows.length < 2) {
      return rows.map(_mergeGroup).toList();
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

    // Resolve roots after all unions. A later row may bridge two groups that
    // were previously separate, so groups must be assembled only after union.
    final groups = <int, List<Map<String, dynamic>>>{};
    for (var i = 0; i < rows.length; i++) {
      groups.putIfAbsent(root(i), () => <Map<String, dynamic>[]).add(rows[i]);
    }

    return groups.values.map(_mergeGroup).toList();
  }
}
