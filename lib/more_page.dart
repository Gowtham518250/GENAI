import 'live_translated_text.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A mobile-first hub for less frequently used Retail Mind modules.
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  static const Color _ink = Color(0xFF172554);
  static const Color _muted = Color(0xFF64748B);
  static const Color _primary = Color(0xFF4F46E5);

  static const List<_MoreAction> _actions = [
    _MoreAction(title: 'Shop profile', subtitle: 'Business details', icon: Icons.storefront_rounded, color: Color(0xFF4F46E5), route: '/shop-profile'),
    _MoreAction(title: 'Purchase orders', subtitle: 'Supplier orders and receiving', icon: Icons.local_shipping_rounded, color: Color(0xFFF59E0B), route: '/purchase-orders'),
    _MoreAction(title: 'Online store', subtitle: 'Manage your storefront', icon: Icons.shopping_bag_rounded, color: Color(0xFF0D9488), route: '/online-store'),
    _MoreAction(title: 'Store settings', subtitle: 'Shopping preferences', icon: Icons.tune_rounded, color: Color(0xFF7C3AED), route: '/online-shopping-config'),
    _MoreAction(title: 'Staff & workers', subtitle: 'Team management', icon: Icons.groups_rounded, color: Color(0xFF2563EB), route: '/worker-management'),
    _MoreAction(title: 'Attendance', subtitle: 'Sessions and hours', icon: Icons.fact_check_rounded, color: Color(0xFF059669), route: '/attendance'),
    _MoreAction(title: 'Inventory', subtitle: 'Products and stock', icon: Icons.inventory_2_rounded, color: Color(0xFF0891B2), route: '/inventory'),
    _MoreAction(title: 'Reports & analytics', subtitle: 'Business performance', icon: Icons.analytics_rounded, color: Color(0xFFDB2777), route: '/analytics'),
    _MoreAction(title: 'Transactions', subtitle: 'Recent activity', icon: Icons.receipt_long_rounded, color: Color(0xFF475569), route: '/recent-transactions'),
    _MoreAction(title: 'Help & support', subtitle: 'Guides and assistance', icon: Icons.support_agent_rounded, color: Color(0xFFEA580C), route: '/chatbot-help'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FC),
      appBar: AppBar(
        title: LiveTranslatedText('More', style: GoogleFonts.poppins(color: _ink, fontSize: 20, fontWeight: FontWeight.w800)),
        backgroundColor: Colors.white,
        foregroundColor: _ink,
        surfaceTintColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 760 ? 3 : 2;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF4338CA), Color(0xFF6366F1), Color(0xFF3B82F6)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [BoxShadow(color: _primary.withValues(alpha: 0.18), blurRadius: 20, offset: const Offset(0, 8))],
                  ),
                  child: Row(
                    children: [
                      Container(width: 54, height: 54, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(17), border: Border.all(color: Colors.white.withValues(alpha: 0.24))), child: const Icon(Icons.store_rounded, color: Colors.white, size: 29)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LiveTranslatedText('Your shop workspace', style: GoogleFonts.poppins(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            LiveTranslatedText('Settings, team tools, reports and more in one place.', style: GoogleFonts.poppins(color: Colors.white.withValues(alpha: 0.86), fontSize: 11, height: 1.4)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Row(children: [
                  Container(width: 4, height: 22, decoration: BoxDecoration(color: _primary, borderRadius: BorderRadius.circular(4))),
                  const SizedBox(width: 10),
                  LiveTranslatedText('Manage your shop', style: GoogleFonts.poppins(color: _ink, fontSize: 16, fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 13),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _actions.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns, crossAxisSpacing: 11, mainAxisSpacing: 11, childAspectRatio: constraints.maxWidth >= 760 ? 1.7 : 1.35),
                  itemBuilder: (context, index) {
                    final action = _actions[index];
                    return _MoreActionCard(action: action, onTap: () => Navigator.pushNamed(context, action.route));
                  },
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE5EAF3))),
                  child: Row(
                    children: [
                      const Icon(Icons.cloud_sync_rounded, color: _primary, size: 22),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LiveTranslatedText('Offline-first workspace', style: GoogleFonts.poppins(color: _ink, fontSize: 12, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 3),
                            LiveTranslatedText('Keep working during connection drops. Pending changes sync through the app’s existing queue.', style: GoogleFonts.poppins(color: _muted, fontSize: 10.5, height: 1.4)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MoreAction {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String route;

  const _MoreAction({required this.title, required this.subtitle, required this.icon, required this.color, required this.route});
}

class _MoreActionCard extends StatelessWidget {
  final _MoreAction action;
  final VoidCallback onTap;

  const _MoreActionCard({super.key, required this.action, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE5EAF3)),
            boxShadow: [BoxShadow(color: const Color(0xFF172554).withValues(alpha: 0.025), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: action.color.withValues(alpha: 0.11), borderRadius: BorderRadius.circular(12)), child: Icon(action.icon, color: action.color, size: 21)),
                const Spacer(),
                const Icon(Icons.arrow_outward_rounded, color: Color(0xFF94A3B8), size: 17),
              ]),
              const SizedBox(height: 10),
              LiveTranslatedText(action.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(color: const Color(0xFF172554), fontSize: 12, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              LiveTranslatedText(action.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(color: const Color(0xFF64748B), fontSize: 10, height: 1.3)),
            ],
          ),
        ),
      ),
    );
  }
}
