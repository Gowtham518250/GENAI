import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/order_history_service.dart';
import '../../api_client.dart';
import '../../visual_widgets.dart';

/// 🔧 FLIPKART-LEVEL: Order History Page
/// Comprehensive order management with tracking and status updates
class OrderHistoryPage extends StatefulWidget {
  const OrderHistoryPage({super.key});

  @override
  State<OrderHistoryPage> createState() => _OrderHistoryPageState();
}

class _OrderHistoryPageState extends State<OrderHistoryPage> {
  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _filteredOrders = [];
  bool _isLoading = true;
  String _selectedFilter = 'ALL'; // ALL, PLACED, CONFIRMED, PROCESSING, SHIPPED, DELIVERED, CANCELLED, RETURNED
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    // Keep cached orders visible when offline, but reconcile with the
    // authenticated customer's server history whenever the backend is reachable.
    try {
      final prefs = await SharedPreferences.getInstance();
      final role = (prefs.getString('user_role') ??
              prefs.getString('user_type') ??
              prefs.getString('role') ??
              '')
          .trim()
          .toUpperCase();
      if (role == 'CUSTOMER') {
        final response = await ApiClient.getJson('/store/my-orders')
            .timeout(const Duration(seconds: 12));
        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          final rawOrders = body is Map ? body['orders'] : null;
          if (rawOrders is List) {
            final remoteOrders = rawOrders
                .whereType<Map>()
                .map((order) => Map<String, dynamic>.from(order))
                .toList();
            await OrderHistoryService.mergeRemoteOrders(remoteOrders);
          }
        } else if (kDebugMode) {
          debugPrint('Customer order refresh returned a non-success HTTP response.');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Customer order refresh unavailable; showing cached orders: $e');
    }

    final orders = await OrderHistoryService.getAllOrders();
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _applyCurrentFilters();
      _isLoading = false;
    });
  }

  void _applyCurrentFilters() {
    final query = _searchController.text.trim().toLowerCase();
    _filteredOrders = _orders.where((order) {
      final status = (order['status'] ?? 'PENDING').toString().toUpperCase();
      final matchesStatus = _selectedFilter == 'ALL' || status == _selectedFilter;
      final searchable = [
        order['order_id'],
        order['server_order_id'],
        order['shop_name'],
        order['customer_name'],
        order['customer_phone'],
      ].whereType<Object>().join(' ').toLowerCase();
      return matchesStatus && (query.isEmpty || searchable.contains(query));
    }).toList();
  }

  Future<void> _filterOrders() async {
    if (!mounted) return;
    setState(_applyCurrentFilters);
  }

  Future<void> _searchOrders(String query) async {
    if (!mounted) return;
    setState(_applyCurrentFilters);
  }

  Future<void> _cancelOrder(String orderId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cancel Order', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
        content: Text('Are you sure you want to cancel this order?', style: GoogleFonts.poppins()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('No', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Yes', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: const Color(0xFFEF4444))),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await OrderHistoryService.cancelOrder(orderId);
      if (success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Order cancelled successfully'), backgroundColor: Colors.green),
          );
        }
        await _loadOrders();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot cancel this order'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(
          'My Orders',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: const Color(0xFF1F2937)),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1F2937),
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 🔧 FLIPKART-LEVEL: Search bar
                _buildSearchBar(),
                // 🔧 FLIPKART-LEVEL: Filter chips
                _buildFilterChips(),
                // 🔧 FLIPKART-LEVEL: Orders list
                Expanded(
                  child: _filteredOrders.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _filteredOrders.length,
                          itemBuilder: (context, index) {
                            final order = _filteredOrders[index];
                            return _buildOrderCard(order);
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search orders by ID, name, or phone',
          hintStyle: GoogleFonts.poppins(color: const Color(0xFF9CA3AF)),
          prefixIcon: const Icon(Icons.search, color: Color(0xFF6B7280)),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: Color(0xFF6B7280)),
                  onPressed: () {
                    _searchController.clear();
                    _searchOrders('');
                  },
                )
              : null,
          filled: true,
          fillColor: const Color(0xFFF3F4F6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        onChanged: _searchOrders,
      ),
    );
  }

  Widget _buildFilterChips() {
    final filters = ['ALL', ...OrderHistoryService.orderStatuses];
    
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: filters.length,
        itemBuilder: (context, index) {
          final filter = filters[index];
          final isSelected = _selectedFilter == filter;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(filter),
              selected: isSelected,
              onSelected: (selected) {
                setState(() => _selectedFilter = filter);
                _filterOrders();
              },
              selectedColor: const Color(0xFF6366F1),
              checkmarkColor: Colors.white,
              labelStyle: GoogleFonts.poppins(
                fontSize: 13,
                color: isSelected ? Colors.white : const Color(0xFF4B5563),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long_outlined, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'No orders found',
            style: GoogleFonts.poppins(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF9CA3AF),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start shopping to see your orders here',
            style: GoogleFonts.poppins(
              fontSize: 14,
              color: const Color(0xFF9CA3AF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> order) {
    final orderId = order['order_id'] ?? 'Unknown';
    final status = order['status'] ?? 'PLACED';
    final total = order['total_amount'] ?? order['total'] ?? order['amount'] ?? 0;
    final createdAt = order['created_at'] ?? '';
    final items = order['items'] as List<dynamic>? ?? [];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassContainer(
        padding: const EdgeInsets.all(16),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      orderId,
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1F2937),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDate(createdAt),
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: const Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
              _buildStatusChip(status),
            ],
          ),
          const SizedBox(height: 12),
          // Items preview
          if (items.isNotEmpty)
            Text(
              '${items.length} item${items.length > 1 ? 's' : ''}',
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: const Color(0xFF6B7280),
              ),
            ),
          const SizedBox(height: 12),
          // Total and actions
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '₹${total.toString()}',
                style: GoogleFonts.poppins(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2937),
                ),
              ),
              Row(
                children: [
                  // Cancel button (only for cancellable orders)
                  if (_isCancellable(status))
                    OutlinedButton.icon(
                      onPressed: () => _cancelOrder(orderId),
                      icon: const Icon(Icons.cancel, size: 16),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFEF4444),
                        side: const BorderSide(color: Color(0xFFEF4444)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        textStyle: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color color;
    switch (status) {
      case 'DELIVERED':
        color = const Color(0xFF10B981);
        break;
      case 'CANCELLED':
      case 'RETURNED':
        color = const Color(0xFFEF4444);
        break;
      case 'SHIPPED':
      case 'OUT_FOR_DELIVERY':
        color = const Color(0xFF3B82F6);
        break;
      default:
        color = const Color(0xFFF59E0B);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: GoogleFonts.poppins(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  bool _isCancellable(String status) {
    return const ['PENDING', 'ACCEPTED'].contains(status.toUpperCase());
  }

  String _formatDate(String dateString) {
    try {
      final date = DateTime.parse(dateString);
      return '${date.day}/${date.month}/${date.year}';
    } catch (e) {
      return dateString;
    }
  }

  Widget _buildTimelineItem(Map<String, dynamic> item) {
    final status = item['status'] as String? ?? '';
    final timestamp = item['timestamp'] as String?;
    final completed = item['completed'] as bool? ?? false;

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeline indicator
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: completed ? const Color(0xFF10B981) : const Color(0xFFE5E7EB),
              shape: BoxShape.circle,
              border: Border.all(
                color: completed ? const Color(0xFF10B981) : const Color(0xFFE5E7EB),
                width: 2,
              ),
            ),
            child: completed
                ? const Icon(Icons.check, size: 14, color: Colors.white)
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 16),
          // Status and timestamp
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.replaceAll('_', ' '),
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: completed ? const Color(0xFF1F2937) : const Color(0xFF9CA3AF),
                  ),
                ),
                if (timestamp != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _formatDate(timestamp),
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      color: const Color(0xFF6B7280),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
