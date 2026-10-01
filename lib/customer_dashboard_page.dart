import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'api_client.dart';
import 'role_selection_page.dart';
import 'shop_browser_page.dart';
import 'online_store_service.dart';

class CustomerDashboardPage extends StatefulWidget {
  final String phone;
  const CustomerDashboardPage({super.key, required this.phone});
  @override
  State<CustomerDashboardPage> createState() => _CustomerDashboardPageState();
}

class _CustomerDashboardPageState extends State<CustomerDashboardPage> {
  bool _loading = true;
  bool _loggingOut = false;
  List<dynamic> _orders = [];
  String _customerName = "Customer";

  @override
  void initState() {
    super.initState();
    _fetchOrders();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('customer_token') ?? '';
    if (token.isNotEmpty) {
      try {
        final payload = jsonDecode(utf8.decode(base64.decode(base64.normalize(token.split('.')[1]))));
        if (mounted) {
          setState(() => _customerName = payload['name'] ?? 'Shopper');
        }
      } catch (_) {}
    }
  }

  Future<void> _fetchOrders() async {
    try {
      final historyResponse = await ApiClient.getJson(ApiClient.myOrders);
      if (historyResponse.statusCode == 200) {
        final data = jsonDecode(historyResponse.body);
        if (mounted) {
          setState(() => _orders = data is List ? data : (data['orders'] ?? []));
        }
      }
    } catch (e) {
      debugPrint('Error: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _rateOrder(Map<String, dynamic> order) async {
    final rawId = order['id'] ?? order['order_id'];
    final orderId = int.tryParse(rawId.toString());
    if (orderId == null) return;

    int selected = 5;
    final commentController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('Rate this shop'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Your rating helps other customers compare shops.',
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final star = index + 1;
                    return IconButton(
                      onPressed: () => setDialogState(() => selected = star),
                      icon: Icon(
                        star <= selected
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: Colors.amber,
                        size: 32,
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: commentController,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Comment (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final apiResult = await OnlineStoreService.rateOrder(
                    orderId: orderId,
                    rating: selected,
                    comment: commentController.text,
                  );
                  if (!mounted) return;
                  if (apiResult['success'] == true) {
                    Navigator.pop(dialogContext, true);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Thanks — your rating was recorded.'),
                        backgroundColor: Color(0xFF059669),
                      ),
                    );
                    _fetchOrders();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          apiResult['message']?.toString() ??
                              'Unable to save the rating.',
                        ),
                      ),
                    );
                  }
                },
                child: const Text('Submit rating'),
              ),
            ],
          );
        },
      ),
    );

    if (result == null) {
      commentController.dispose();
    } else {
      commentController.dispose();
    }
  }

  Future<void> _logout() async {
    if (_loggingOut) return; // Prevent duplicate logout taps
    setState(() => _loggingOut = true);
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('customer_token');
    await prefs.remove('customer_phone');
    
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const RoleSelectionPage(email: '')), (route) => false);
  }

  Widget _buildBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)]),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: const Color(0xFF4F46E5).withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Welcome back,', style: GoogleFonts.poppins(color: Colors.white70, fontSize: 16)),
          Text(_customerName, style: GoogleFonts.poppins(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ShopBrowserPage())),
            icon: const Icon(Icons.shopping_bag_outlined, color: Color(0xFF4F46E5)),
            label: const Text('Discover & Order', style: TextStyle(color: Color(0xFF4F46E5), fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          ),
          const SizedBox(height: 10),
          Text(
            'Search any shop or product, compare prices, and use AI advice for cheaper or higher-rated options.',
            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildCategories() {
    final cats = [
      {'icon': Icons.local_grocery_store, 'label': 'Groceries', 'color': Colors.orange},
      {'icon': Icons.checkroom, 'label': 'Fashion', 'color': Colors.pink},
      {'icon': Icons.devices, 'label': 'Electronics', 'color': Colors.blue},
      {'icon': Icons.medical_services, 'label': 'Pharmacy', 'color': Colors.green},
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: cats.map((c) => Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: (c['color'] as Color).withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(c['icon'] as IconData, color: c['color'] as Color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(c['label'] as String, style: GoogleFonts.poppins(fontWeight: FontWeight.w500, fontSize: 12)),
        ],
      )).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('AI Shop Pro', style: GoogleFonts.poppins(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 22)),
        actions: [
          _loggingOut
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(icon: const Icon(Icons.logout, color: Colors.black54), onPressed: _logout),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF4F46E5)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBanner(),
                  const SizedBox(height: 32),
                  Text('Categories', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  _buildCategories(),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Recent Orders', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold)),
                      TextButton(onPressed: (){}, child: const Text('View All')),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _orders.isEmpty
                      ? Center(child: Text('No recent orders. Start shopping!', style: GoogleFonts.poppins(color: Colors.grey)))
                      : Column(
                          children: _orders.map((tx) {
                            return Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10)]),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(color: Colors.indigo.shade50, borderRadius: BorderRadius.circular(12)),
                                    child: const Icon(Icons.receipt_long, color: Colors.indigo),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Order #${tx['id'] ?? tx['order_id'] ?? '??'}', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
                                        Text(tx['created_at']?.toString() ?? 'Online Order', style: GoogleFonts.poppins(color: Colors.grey, fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        'Rs ${tx['total_amount'] ?? tx['amount'] ?? 0}',
                                        style: GoogleFonts.poppins(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 18,
                                          color: Colors.indigo,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        (tx['status'] ?? tx['order_status'] ?? '').toString(),
                                        style: GoogleFonts.poppins(
                                          color: Colors.grey.shade600,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              if ((tx['status'] ?? tx['order_status'] ?? '').toString().toUpperCase() == 'DELIVERED')
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton.icon(
                                    onPressed: () => _rateOrder(Map<String, dynamic>.from(tx)),
                                    icon: const Icon(Icons.star_outline_rounded, size: 17),
                                    label: const Text('Rate shop'),
                                  ),
                                ),
                            );
                          }).toList(),
                        ),
                ],
              ),
            ),
    );
  }
}

