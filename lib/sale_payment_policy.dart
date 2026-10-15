/// Resolves payment state for a sale submitted from the POS.
///
/// A regular cash sale is paid in full when no separate partial receipt was
/// entered. Explicit partial receipts remain partial. Borrow invoices are
/// recorded through the credit workflow and must not be treated as collected.
class SalePaymentPolicy {
  static double resolvePaidAmount({
    required double totalAmount,
    required double enteredPaidAmount,
    required bool isBorrow,
    required bool isCashPayment,
    required bool paymentConfirmed,
  }) {
    if (!totalAmount.isFinite || totalAmount <= 0) return 0.0;
    final total = double.parse(totalAmount.toStringAsFixed(2));
    if (isBorrow) return 0.0;

    // The POS requires confirmation before submitting an online payment. Never
    // fabricate a receipt if that confirmation is missing.
    if (!isCashPayment && !paymentConfirmed) return 0.0;

    final entered = enteredPaidAmount.isFinite
        ? enteredPaidAmount.clamp(0.0, total).toDouble()
        : 0.0;
    if (entered > 0) return entered;

    // In cash mode, zero means no separate partial receipt was entered: the
    // ordinary checkout represents a completed, fully paid sale.
    // A confirmed online checkout with no amount recorded is likewise full.
    return total;
  }
}
