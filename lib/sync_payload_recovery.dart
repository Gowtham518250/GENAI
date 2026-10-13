/// Rebuilds a legacy queued sale from its locally persisted financial record.
///
/// This is only a recovery path for older queue entries that contain a stable
/// sale/invoice ID but no embedded invoice payload. It never invents a date,
/// amount, quantity, or product name; ambiguous records stay queued for review.
Map<String, dynamic>? buildInvoicePayloadFromLocalSale(
  Map<String, dynamic> queueData,
  List<dynamic> localSales,
) {
  String textValue(dynamic value) => value?.toString().trim() ?? '';

  double? numberValue(dynamic value) {
    if (value is num) {
      final result = value.toDouble();
      return result.isFinite ? result : null;
    }
    final result = double.tryParse(textValue(value));
    return result != null && result.isFinite ? result : null;
  }

  final identifiers = <String>{
    for (final value in <dynamic>[
      queueData['sale_id'],
      queueData['invoice_number'],
      queueData['offline_id'],
      queueData['id'],
    ])
      if (textValue(value).isNotEmpty) textValue(value).toLowerCase(),
  };
  if (identifiers.isEmpty) return null;

  Map<String, dynamic>? localSale;
  for (final raw in localSales) {
    if (raw is! Map) continue;
    final record = Map<String, dynamic>.from(raw);
    final localIdentifiers = <String>{
      for (final value in <dynamic>[
        record['sale_id'],
        record['invoice_number'],
        record['offline_id'],
        record['bill_number'],
        record['invoice_display_number'],
        record['id'],
      ])
        if (textValue(value).isNotEmpty) textValue(value).toLowerCase(),
    };
    if (identifiers.intersection(localIdentifiers).isNotEmpty) {
      localSale = record;
      break;
    }
  }
  if (localSale == null) return null;

  final rawItems = localSale['line_items'] ?? localSale['items'];
  if (rawItems is! List || rawItems.isEmpty) return null;

  final lineItems = <Map<String, dynamic>>[];
  double sumOfLines = 0;
  for (final rawItem in rawItems) {
    if (rawItem is! Map) return null;
    final item = Map<String, dynamic>.from(rawItem);
    final name = textValue(
      item['product_name'] ??
          item['description'] ??
          item['product'] ??
          item['item'] ??
          item['name'] ??
          item['title'],
    );
    final quantity = numberValue(item['quantity'] ?? item['qty']);
    final unitPrice = numberValue(item['unit_price'] ?? item['price']);
    final suppliedLineTotal = numberValue(
      item['line_total'] ?? item['total_with_tax'] ?? item['total'],
    );
    if (name.isEmpty ||
        quantity == null ||
        quantity <= 0 ||
        unitPrice == null ||
        unitPrice < 0) {
      return null;
    }

    final lineTotal = suppliedLineTotal ?? (quantity * unitPrice);
    if (!lineTotal.isFinite || lineTotal < 0) return null;
    sumOfLines += lineTotal;

    final productId = int.tryParse(
      textValue(item['product_id'] ?? item['id']),
    );
    lineItems.add(<String, dynamic>{
      'product_id': productId != null && productId > 0 ? productId : null,
      'product_name': name,
      'quantity': quantity,
      'unit_price': unitPrice,
      'line_total': lineTotal,
      'discount_amount': numberValue(item['discount_amount']) ?? 0,
      if (textValue(item['discount_reason']).isNotEmpty)
        'discount_reason': textValue(item['discount_reason']),
      if (textValue(item['discount_source']).isNotEmpty)
        'discount_source': textValue(item['discount_source']),
    });
  }

  final invoiceNumber = textValue(
    queueData['invoice_number'] ??
        localSale['invoice_number'] ??
        localSale['bill_number'] ??
        localSale['sale_id'],
  );
  final offlineId = textValue(
    queueData['offline_id'] ??
        localSale['offline_id'] ??
        localSale['sale_id'] ??
        invoiceNumber,
  );
  if (invoiceNumber.isEmpty || offlineId.isEmpty) return null;

  // Prefer a stored business date. Never silently use today's date for an
  // older queued sale because that would corrupt daily/monthly sales reports.
  final dateRaw = textValue(
    localSale['business_date'] ??
        localSale['invoice_date'] ??
        localSale['sale_date'] ??
        localSale['date'] ??
        localSale['created_at'] ??
        localSale['sale_timestamp'] ??
        queueData['invoice_date'],
  );
  final parsedDate = DateTime.tryParse(dateRaw);
  if (parsedDate == null) return null;
  final invoiceDate = parsedDate.toIso8601String().substring(0, 10);

  final totalAmount = numberValue(
    queueData['total_amount'] ??
        queueData['total'] ??
        localSale['total_amount'] ??
        localSale['grand_total'] ??
        localSale['total'] ??
        sumOfLines,
  );
  final paidAmount = numberValue(
        queueData['paid_amount'] ??
            queueData['amount_paid'] ??
            localSale['paid_amount'] ??
            localSale['amount_paid'],
      ) ??
      0;
  final tax = numberValue(queueData['tax'] ?? localSale['tax']) ?? 0;
  if (totalAmount == null ||
      totalAmount < 0 ||
      paidAmount < 0 ||
      paidAmount > totalAmount + 0.01 ||
      tax < 0) {
    return null;
  }

  final paymentStatus = paidAmount >= totalAmount - 0.01
      ? 'PAID'
      : paidAmount > 0.01
          ? 'PARTIAL'
          : 'UNPAID';

  final customerName = textValue(
    queueData['customer_name'] ?? localSale['customer_name'],
  );
  final customerPhone = textValue(
    queueData['customer_phone'] ?? localSale['customer_phone'],
  );
  final paymentMethod = textValue(
    queueData['payment_method'] ?? localSale['payment_method'],
  );
  final notes = textValue(queueData['notes'] ?? localSale['notes']);
  final timestamp = textValue(
    localSale['sale_timestamp'] ?? localSale['created_at'],
  );

  return <String, dynamic>{
    'invoice_number': invoiceNumber,
    'offline_id': offlineId,
    'customer_name': customerName.isNotEmpty ? customerName : 'Cash Customer',
    if (customerPhone.isNotEmpty) 'customer_phone': customerPhone,
    'total_amount': totalAmount,
    'paid_amount': paidAmount,
    'tax': tax,
    'payment_status': paymentStatus,
    if (paymentMethod.isNotEmpty) 'payment_method': paymentMethod,
    'invoice_date': invoiceDate,
    'sale_timestamp': timestamp.isNotEmpty
        ? timestamp
        : '${invoiceDate}T00:00:00Z',
    if (notes.isNotEmpty) 'notes': notes,
    'line_items': lineItems,
  };
}
