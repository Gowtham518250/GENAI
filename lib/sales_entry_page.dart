    // button could get a second call past the `if (isLoading) return false`
    // guard before the first call had set the flag, and since saleId is
    // generated fresh per call (microsecond timestamp), SaleService's
    // idempotency check — keyed by saleId — never saw them as duplicates.
    // Setting isLoading synchronously here, before any await, closes that
    // window: the second tap now sees isLoading == true immediately.
    setState(() {
      isLoading = true;
      message = 'Processing Transaction...';
    });

    // 🔧 FIX: Check local session validity (7-day timestamp check)
    // Note: ApiClient will handle auto-refresh on 401 errors automatically
    try {
      final tokenValid = await SessionManagementService.isTokenValid();
      if (!tokenValid) {
        if (kDebugMode) debugPrint('🔐 Session expired (older than 7 days)');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Session expired. Please login again.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
        // FIX: reset the flag we now set up-front (see comment above), or
        // the bill button stays permanently disabled after this bounce.
        if (mounted) setState(() => isLoading = false);
        return false;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Session check error: $e');
      // Continue anyway - ApiClient will handle token refresh on 401
    }

    final totals = calculateTotal() as Map<String, dynamic>;
    final grandTotal = totals['total'] ?? 0.0;

    if (!_validateSaleInputs(grandTotal)) {
      // FIX: reset isLoading here too — same reason as above.
      if (mounted) setState(() => isLoading = false);
      return false;
    }

    // First-sale celebration: detect if this is the first bill on this device/user.
    // (Helps D1→D7 retention; backend sync can happen later.)
    final bool isFirstSaleForThisShop = (await LocalStorageService.loadSales()).isEmpty;

    // Keep the internal transaction id separate from the customer-facing bill number.
    final saleId = 'SALE_${DateTime.now().microsecondsSinceEpoch}';
    final billNumber = await _allocateNextBillNumber();

    try {
      final items = _getProcessedItems();
      final result = await SaleService.submitSale(
        saleId: saleId,
        items: items,
        grandTotal: grandTotal,
        paidAmount: isBorrow ? 0.0 : _paidAmount, // Borrow: paidAmount = 0
        customerName: customerNameController.text.trim(),
        customerPhone: customerPhoneController.text.trim(),
        withTax: _withTax,
        totals: totals,
        paymentMethod: _isOnlinePayment ? 'Online' : 'Cash', // NEW: Pass payment type
        isBorrow: isBorrow, // NEW: Pass borrow flag to use correct endpoint
        invoiceNumber: billNumber,
      );

      // If it's a borrow sale, also create an invoice!
      if (isBorrow) {
        // The customer-facing bill number is the canonical invoice number.
        final String invoiceNumber = billNumber;
        
        // Build product list string for invoice
        final String productList = items.map((e) {
          final qtyRaw = e['qty'];
          final qty = qtyRaw is num ? qtyRaw : double.tryParse(qtyRaw?.toString() ?? '1') ?? 1;
          return '${e['product_name']} ($qty x ₹${e['price']})';
        }).join(', ');
        
        // Due date from borrow selection
        final String dueDate = _selectedDueDate != null 
          ? DateFormat('yyyy-MM-dd').format(_selectedDueDate!) 
          : DateFormat('yyyy-MM-dd').format(DateTime.now().add(const Duration(days: 7)));
        
        // Create invoice object
        final newInvoice = {
          'invoice_number': invoiceNumber,
          'product': productList,
          'customer_name': customerNameController.text.trim(),
          'customer_phone': customerPhoneController.text.trim(),
          'total_amount': grandTotal,
          'paid_amount': 0.0,
          'due_date': dueDate,
          'status': 'UNPAID',
          'payment_status': 'UNPAID',
          'is_local': result['status'] != 'SYNCED',
          'business_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'sale_id': saleId,
        };
        
        // Save a local mirror; SaleService already attempted backend sync
        // above using the same saleId.
        final localInvoices = await LocalStorageService.loadLocalInvoices();
        localInvoices.removeWhere((invoice) => invoice['invoice_number']?.toString() == invoiceNumber);
        localInvoices.add(newInvoice);
        await LocalStorageService.saveLocalInvoices(localInvoices);
        
        if (kDebugMode) debugPrint('✅ Borrow invoice mirror saved with canonical id $invoiceNumber');
      }

      if (result['success'] == true) {
        _hapticSuccess();
        // ✅ CRITICAL: Reset loading BEFORE clearing interface so buttons re-enable
        if (mounted) setState(() { isLoading = false; message = ''; });
        try {
          final localSales = await LocalStorageService.loadSales();
          for (int i = localSales.length - 1; i >= 0; i--) {
            final raw = localSales[i];
            if (raw is Map &&
                (raw['sale_id'] ?? raw['invoice_number'] ?? raw['id'])
                        ?.toString() ==
                    saleId) {
              localSales[i] = {
                ...Map<String, dynamic>.from(raw),
                'bill_number': billNumber,
                'invoice_display_number': billNumber,
              };
              break;
            }
          }
          await LocalStorageService.saveSales(localSales);
        } catch (_) {}

        _clearSaleInterface();
        final bool cloudConfirmed = result['cloudConfirmed'] == true;
        final int syncCount = (result['syncCount'] is num)
            ? (result['syncCount'] as num).toInt()
            : 0;
        if (mounted) {
          setState(() {
            message = cloudConfirmed
                ? 'Sale synced to cloud successfully ✅'
                : (syncCount > 0
                    ? '$syncCount items queued for sync.'
                    : 'Sale saved locally. Cloud sync pending.');
          });
        }
        
        // SHOW SUCCESS DIALOG WITH REAL BILL PDF
        if (mounted) {
          final String shopName = _shopNameForDynamicQr ?? 'Retail Shop';
          final prefs2 = await SharedPreferences.getInstance();
          final shopPhone2 = prefs2.getString('shop_phone') ?? '';
          final shopAddress2 = prefs2.getString('location') ?? '';
          final gstNumber2 = prefs2.getString('gst_number') ?? '';
          final customerName2 = customerNameController.text.trim();

          // 📄 Generate real PDF bill
          String billFilePath = '';
          try {
            billFilePath = await BillGeneratorService.generateAndSaveBill(
              invoiceId: billNumber,
              shopName: shopName,
              shopPhone: shopPhone2,
              shopAddress: shopAddress2,
              gstNumber: gstNumber2,
              customerName: customerName2,
              items: items,
              totalAmount: grandTotal,
              paidAmount: _paidAmount,
              withTax: _withTax,
            );
          } catch (e) {
            if (kDebugMode) debugPrint('⚠️ Bill PDF generation failed: $e');
          }

          final String qrData = billFilePath.isNotEmpty
              ? 'file://$billFilePath'
              : 'https://wa.me/?text=${Uri.encodeComponent("Bill for $saleId — ₹${grandTotal.toStringAsFixed(2)}")}';

          final String capturedBillPath = billFilePath;
          final String capturedCustomer = customerName2;

          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 60),
                    const SizedBox(height: 12),
                    Text('Sale Successful!', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold)),
                    if (isFirstSaleForThisShop) ...[
                      const SizedBox(height: 10),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.85, end: 1.0),
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeOutBack,
                        builder: (context, value, child) {
                          return Transform.scale(scale: value, child: child);
                        },
                        child: Column(
                          children: [
                            Icon(Icons.celebration_rounded, color: const Color(0xFF6366F1), size: 34),
                            const SizedBox(height: 6),
                            Text(
                              'Your shop is live!',
                              style: GoogleFonts.poppins(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                                color: const Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Great start — keep billing daily.',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Text(
                      'Bill No: ' + billNumber,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF111827),
                      ),