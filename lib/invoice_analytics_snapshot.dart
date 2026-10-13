/// A single, testable invoice-analytics snapshot built from canonical invoice rows.
///
/// Invoice Analytics includes all invoice statuses; only the separate
/// outstanding-credit customer panel is restricted to invoices that still have
/// a balance and a valid customer phone number.
class InvoiceAnalyticsSnapshot {
  final List<Map<String, dynamic>> invoices;
  final List<Map<String, dynamic>> outstandingCreditInvoices;
  final double totalInvoiced;
  final double totalPaid;
  final double totalPending;
  final int paidCount;
  final int partialCount;
  final int unpaidCount;

  const InvoiceAnalyticsSnapshot({
    required this.invoices,
    required this.outstandingCreditInvoices,
    required this.totalInvoiced,
    required this.totalPaid,
    required this.totalPending,
    required this.paidCount,
    required this.partialCount,
    required this.unpaidCount,
  });

  static double _amount(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  factory InvoiceAnalyticsSnapshot.fromRows(
    List<Map<String, dynamic>> rows, {
    required bool Function(String phone) isValidCustomerPhone,
  }) {
    final invoices = <Map<String, dynamic>>[];
    final outstandingCreditInvoices = <Map<String, dynamic>>[];
    var totalInvoiced = 0.0;
    var totalPaid = 0.0;
    var totalPending = 0.0;
    var paidCount = 0;
    var partialCount = 0;
    var unpaidCount = 0;

    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw);
      final total = _amount(
        row['total_amount'] ??
            row['total'] ??
            row['amount'] ??
            row['invoice_total'] ??
            row['grand_total'],
      ).clamp(0.0, double.infinity).toDouble();
      final paid = _amount(
        row['paid_amount'] ??
            row['amount_paid'] ??
            row['paid'] ??
            row['received_amount'],
      ).clamp(0.0, total).toDouble();
      final pending = (total - paid).clamp(0.0, double.infinity).toDouble();
      final status = total > 0 && paid >= total - 0.01
          ? 'PAID'
          : (paid > 0 ? 'PARTIAL' : 'UNPAID');

      final invoice = <String, dynamic>{
        ...row,
        'total_amount': total,
        'paid_amount': paid,
        'pending_amount': pending,
        'payment_status': status,
      };

      // Do not discard paid rows: they are essential to invoice analytics,
      // payment-status filters, collected totals and the historical invoice list.
      invoices.add(invoice);
      totalInvoiced += total;
      totalPaid += paid;
      totalPending += pending;

      switch (status) {
        case 'PAID':
          paidCount++;
          break;
        case 'PARTIAL':
          partialCount++;
          break;
        default:
          unpaidCount++;
          break;
      }

      final phone = (invoice['customer_phone'] ??
              invoice['phone'] ??
              invoice['mobile'] ??
              '')
          .toString()
          .trim();
      if (pending > 0.01 && isValidCustomerPhone(phone)) {
        outstandingCreditInvoices.add(invoice);
      }
    }

    return InvoiceAnalyticsSnapshot(
      invoices: invoices,
      outstandingCreditInvoices: outstandingCreditInvoices,
      totalInvoiced: totalInvoiced,
      totalPaid: totalPaid,
      totalPending: totalPending,
      paidCount: paidCount,
      partialCount: partialCount,
      unpaidCount: unpaidCount,
    );
  }
}
