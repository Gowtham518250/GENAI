import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../online_order_service.dart';
import '../../online_store_service.dart';

/// Premium owner hub for online shopping.
class OnlineStoreHubPage extends StatefulWidget {
  const OnlineStoreHubPage({super.key});

  @override
  State<OnlineStoreHubPage> createState() => _OnlineStoreHubPageState();
}

class _OnlineStoreHubPageState extends State<OnlineStoreHubPage> {
  bool _loading = true;
  bool _online = false;
  Map<String, dynamic> _metrics = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final shopId =
          (prefs.getInt('user_id') ?? prefs.getInt('userId') ?? 0).toString();

      final values = await Future.wait<dynamic>([
        OnlineStoreService.getOnlineSettings(),
        OnlineOrderService.getAnalytics(shopId),
      ]);

      if (!mounted) return;

      final onlineSettings = Map<String, dynamic>.from(values[0] as Map);
      setState(() {
        _online = onlineSettings['is_online_store_enabled'] == true;
        _metrics = Map<String, dynamic>.from(values[1] as Map);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _metrics = const {});
      }
      debugPrint('Online store hub refresh failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int _int(String key) => (_metrics[key] as num?)?.toInt() ?? 0;

  double _double(String key) => (_metrics[key] as num?)?.toDouble() ?? 0.0;

  @override
  Widget build(BuildContext context) {
    final totalOrders = _int('totalCount');
    final pending = _int('pending');
    final totalPaid = _int('totalPaidCount');
    final totalRevenue = _double('totalRevenue');
    final todayOrders = _int('todayCount');
    final todayRevenue = _double('todayRevenue');
    final todayPaid = _int('todayPaidCount');

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      appBar: AppBar(
        title: Text(
          'Online Store',
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.w800,
            color: const Color(0xFF111827),
          ),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            tooltip: 'Refresh online store data',
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: RefreshIndicator(
        color: const Color(0xFF5B3DF5),
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            _buildHero(
              totalOrders: totalOrders,
              pending: pending,
              todayOrders: todayOrders,
            ),
            const SizedBox(height: 16),
            _buildPerformanceCard(
              totalOrders: totalOrders,
              pending: pending,
              totalPaid: totalPaid,
              totalRevenue: totalRevenue,
              todayOrders: todayOrders,
              todayRevenue: todayRevenue,
              todayPaid: todayPaid,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Store management',
                    style: GoogleFonts.poppins(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF111827),
                    ),
                  ),
                ),
                Text(
                  'Owner tools',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _HubTile(
              icon: Icons.inventory_2_rounded,
              color: const Color(0xFF4F46E5),
              title: 'Manage Inventory',
              subtitle: 'Add, edit, and organize products for the customer storefront.',
              badge: 'PRODUCTS',
              route: '/inventory',
            ),
            _HubTile(
              icon: Icons.tune_rounded,
              color: const Color(0xFF7C3AED),
              title: 'Store Setup',
              subtitle: 'Online visibility, marketplace settings and online-only fee.',
              badge: 'SETTINGS',
              route: '/online-store-manager',
            ),
            _HubTile(
              icon: Icons.receipt_long_rounded,
              color: const Color(0xFFF59E0B),
              title: 'Online Orders',
              subtitle: 'Accept, dispatch, reject and verify customer deliveries.',
              badge: pending > 0 ? '$pending PENDING' : 'UP TO DATE',
              route: '/online-orders',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHero({
    required int totalOrders,
    required int pending,
    required int todayOrders,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF141A45), Color(0xFF4438CA), Color(0xFF5B3DF5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4338CA).withValues(alpha: 0.20),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
                child: const Icon(
                  Icons.storefront_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _online
                      ? 'Your online store is live'
                      : 'Your online store is offline',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _statusChip(),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _online
                ? 'Customers can discover your shop and place online orders.'
                : 'Turn on Online Shopping from Store Setup to start receiving orders.',
            style: GoogleFonts.poppins(
              color: Colors.white70,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _heroMiniMetric(
                Icons.shopping_bag_rounded,
                'Total',
                '$totalOrders',
              ),
              _heroMiniMetric(
                Icons.pending_actions_rounded,
                'Pending',
                '$pending',
              ),
              _heroMiniMetric(
                Icons.today_rounded,
                'Today',
                '$todayOrders',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusChip() {
    final color = _online
        ? const Color(0xFF86EFAC)
        : const Color(0xFFFDE68A);
    final label = _online ? 'LIVE' : 'OFFLINE';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroMiniMetric(IconData icon, String label, String value) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.10),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white70, size: 15),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.poppins(
                      color: Colors.white60,
                      fontSize: 9,
                    ),
                  ),
                  Text(
                    value,
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPerformanceCard({
    required int totalOrders,
    required int pending,
    required int totalPaid,
    required double totalRevenue,
    required int todayOrders,
    required double todayRevenue,
    required int todayPaid,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.045),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Store performance',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Same live data used by Online Orders',
                      style: GoogleFonts.poppins(
                        fontSize: 10.5,
                        color: const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _metricCard(
                Icons.shopping_bag_rounded,
                'Total orders',
                '$totalOrders',
                const Color(0xFF4F46E5),
              ),
              _metricCard(
                Icons.schedule_rounded,
                'Pending',
                '$pending',
                const Color(0xFFF59E0B),
              ),
              _metricCard(
                Icons.payments_rounded,
                'Revenue',
                '₹' + totalRevenue.toStringAsFixed(0),
                const Color(0xFF0F766E),
              ),
              _metricCard(
                Icons.verified_rounded,
                'Paid',
                '$totalPaid',
                const Color(0xFF16A34A),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.today_rounded,
                  size: 17,
                  color: Color(0xFF64748B),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Today: ' +
                        todayOrders.toString() +
                        ' orders · ₹' +
                        todayRevenue.toStringAsFixed(0) +
                        ' revenue · ' +
                        todayPaid.toString() +
                        ' paid',
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF475569),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricCard(
    IconData icon,
    String label,
    String value,
    Color color,
  ) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 7),
        padding: const EdgeInsets.fromLTRB(10, 11, 8, 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: color.withValues(alpha: 0.13),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 9.5,
                color: const Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 15,
                color: const Color(0xFF111827),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String badge;
  final String? route;
  final VoidCallback? onTap;

  const _HubTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.badge,
    this.route,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        child: InkWell(
          borderRadius: BorderRadius.circular(19),
          onTap: onTap ??
              (route != null
                  ? () => Navigator.pushNamed(context, route!)
                  : null),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 15, 14, 15),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.055),
                  blurRadius: 16,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: color, size: 23),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: GoogleFonts.poppins(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFF172033),
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              badge,
                              style: GoogleFonts.poppins(
                                color: color,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          color: const Color(0xFF64748B),
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 15,
                  color: color.withValues(alpha: 0.75),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
