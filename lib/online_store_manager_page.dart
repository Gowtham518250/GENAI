import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'online_store_service.dart';
import 'secure_token_storage.dart';

class OnlineStoreManagerPage extends StatefulWidget {
  const OnlineStoreManagerPage({super.key});

  @override
  State<OnlineStoreManagerPage> createState() => _OnlineStoreManagerPageState();
}

class _OnlineStoreManagerPageState extends State<OnlineStoreManagerPage> {
  bool _isStoreActive = false;
  bool _isLoading = true;
  bool _isSaving = false;

  final TextEditingController _storeNameController = TextEditingController();
  final TextEditingController _minOrderController = TextEditingController();
  final TextEditingController _deliveryFeeController = TextEditingController();
  final TextEditingController _onlineSetupFeeController = TextEditingController();
  
  bool _offerDelivery = true;
  bool _offerPickup = true;
  bool _acceptCOD = true;
  bool _acceptOnline = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    if (mounted) setState(() => _isLoading = true);
    try {
      final online = await OnlineStoreService.getOnlineSettings();
      if (online['success'] != true) {
        throw StateError(online['error']?.toString() ?? 'Online settings are unavailable.');
      }
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;

      setState(() {
        // Backend is the source of truth. Local preferences are only a
        // fallback for legacy/offline sessions.
        _isStoreActive = online['is_online_store_enabled'] == true;
        _storeNameController.text =
            prefs.getString('shop_name') ?? 'My Kirana Store';
        _minOrderController.text =
            (double.tryParse(online['min_order']?.toString() ?? '0') ?? 0)
                .toStringAsFixed(0);
        _deliveryFeeController.text =
            (double.tryParse(online['delivery_fee']?.toString() ?? '0') ?? 0)
                .toStringAsFixed(0);
        _onlineSetupFeeController.text =
            (double.tryParse(online['online_setup_fee']?.toString() ?? '0') ?? 0)
                .toStringAsFixed(2);
        _offerDelivery = online['offer_delivery'] != false;
        _offerPickup = online['offer_pickup'] != false;
        _acceptCOD = online['accept_cod'] != false;
        _acceptOnline = false; // online collection is not yet supported by the backend
        _isLoading = false;
      });
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _isStoreActive = prefs.getBool('online_store_active') ?? false;
        _storeNameController.text =
            prefs.getString('shop_name') ?? 'My Kirana Store';
        _minOrderController.text =
            (prefs.getInt('online_min_order') ?? 100).toString();
        _deliveryFeeController.text =
            (prefs.getInt('online_delivery_fee') ?? 20).toString();
        _onlineSetupFeeController.text = '0.00';
        _offerDelivery = prefs.getBool('online_offer_delivery') ?? true;
        _offerPickup = prefs.getBool('online_offer_pickup') ?? true;
        _acceptCOD = prefs.getBool('online_accept_cod') ?? true;
        _acceptOnline = false; // prevent stale local settings from enabling an unsupported payment method
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not verify server settings. Showing saved device settings; changes may not sync.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);

    try {
      final minOrder = double.tryParse(_minOrderController.text.trim()) ?? -1;
      final deliveryFee = double.tryParse(_deliveryFeeController.text.trim()) ?? -1;
      final onlineFee = double.tryParse(_onlineSetupFeeController.text.trim()) ?? -1;

      if (minOrder < 0 || deliveryFee < 0 || onlineFee < 0) {
        throw StateError('Fees and minimum order must be valid non-negative numbers.');
      }

      // Submit the complete configuration once so publication status and
      // checkout settings are validated and persisted together.
      final settingsResult = await OnlineStoreService.saveOnlineSettings(
        isOnlineStoreEnabled: _isStoreActive,
        onlineSetupFee: onlineFee,
        minOrder: minOrder,
        deliveryFee: deliveryFee,
        offerDelivery: _offerDelivery,
        offerPickup: _offerPickup,
        acceptCod: _acceptCOD,
        acceptOnline: false,
      );
      if (settingsResult['success'] != true) {
        throw StateError(
          settingsResult['error']?.toString() ?? 'Unable to save online settings.',
        );
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('online_store_active', _isStoreActive);
      await prefs.setInt('online_min_order', minOrder.round());
      await prefs.setInt('online_delivery_fee', deliveryFee.round());
      await prefs.setBool('online_offer_delivery', _offerDelivery);
      await prefs.setBool('online_offer_pickup', _offerPickup);
      await prefs.setBool('online_accept_cod', _acceptCOD);
      await prefs.setBool('online_accept_online', _acceptOnline);

      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isStoreActive
                ? 'Online Shopping enabled and settings published to customers.'
                : 'Online Store disabled.',
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error saving settings: $e');
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to save: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text('Online Store Manager', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            TextButton.icon(
              onPressed: _saveSettings,
              icon: const Icon(Icons.save),
              label: Text('Save', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Master Switch
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              color: _isStoreActive ? Colors.green[50] : Colors.white,
              child: SwitchListTile(
                title: Text('Enable Online Store', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold)),
                subtitle: Text('Make this shop discoverable in the customer marketplace on app and web.'),
                value: _isStoreActive,
                activeColor: Colors.green,
                onChanged: (val) {
                  setState(() => _isStoreActive = val);
                  HapticFeedback.lightImpact();
                },
              ),
            ),
            const SizedBox(height: 24),
            
            if (_isStoreActive) ...[
              // Marketplace discovery replaces link-first ordering.
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFEEF2FF), Color(0xFFE0F2FE)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFC7D2FE)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.8),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.travel_explore_rounded, color: Color(0xFF4F46E5)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Marketplace discovery',
                            style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            'Customers no longer need a shared shop link. When Online Shopping is enabled, they can find your shop by name or find your products across the marketplace.',
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              color: Colors.black54,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Settings
              Text('Delivery & Pickup', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey[200]!)),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: Text('Offer Delivery', style: GoogleFonts.poppins()),
                      value: _offerDelivery,
                      onChanged: (v) => setState(() => _offerDelivery = v),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      title: Text('Offer Store Pickup', style: GoogleFonts.poppins()),
                      value: _offerPickup,
                      onChanged: (v) => setState(() => _offerPickup = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Fees & Limits
              Text('Order Constraints', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _minOrderController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Min Order (₹)',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _deliveryFeeController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Delivery Fee (₹)',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Online-only fee
              Text(
                'Online Order Fee',
                style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.indigo.shade100),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.indigo.withValues(alpha: 0.06),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.tune_rounded, color: Color(0xFF4F46E5)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Online setup / service fee',
                            style: GoogleFonts.poppins(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'ONLINE ONLY',
                            style: GoogleFonts.poppins(
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                              color: const Color(0xFF4338CA),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Charged once per online order. It does not change your in-store/POS product prices.',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: Colors.black54,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 13),
                    TextField(
                      controller: _onlineSetupFeeController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Fee per online order (₹)',
                        prefixText: '₹ ',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Payment Methods
              Text('Accepted Payments', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey[200]!)),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: Text('Cash on Delivery (COD)', style: GoogleFonts.poppins()),
                      value: _acceptCOD,
                      onChanged: (v) => setState(() => _acceptCOD = v),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      title: Text('Online Payments (UPI/Cards)', style: GoogleFonts.poppins()),
                      subtitle: const Text(
                        'Coming soon. Online payment collection is not configured yet; use COD for now.',
                      ),
                      value: false,
                      onChanged: null,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
