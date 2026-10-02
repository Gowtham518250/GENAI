import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../security_service.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../local_storage_service.dart';
import '../../screens/owner/online_store_hub_page.dart';

class ShopModulesSection extends StatefulWidget {
  final VoidCallback onModuleClosed;

  const ShopModulesSection({
    Key? key,
    required this.onModuleClosed,
  }) : super(key: key);

  @override
  State<ShopModulesSection> createState() => _ShopModulesSectionState();
}

class _ShopModulesSectionState extends State<ShopModulesSection> {
  int _inventoryCount = 0;
  int _invoicesCount = 0;
  int _attendanceCount = 0;

  @override
  void initState() {
    super.initState();
    _loadOriginalData();
  }

  Future<void> _loadOriginalData() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      try {
        final prods = await LocalStorageService.loadBackendProducts();
        _inventoryCount = prods.length;
      } catch (_) {}

      try {
        final email = prefs.getString('email') ?? 'default';
        final rawSales = prefs.getString('all_sales_$email') ??
            prefs.getString('all_sales') ??
            '[]';
        final List<dynamic> sales = json.decode(rawSales);
        _invoicesCount = sales.where((s) {
          final status =
              s['payment_status']?.toString().toUpperCase() ?? 'PAID';
          return status == 'UNPAID' || status == 'PARTIAL';
        }).length;
      } catch (_) {}

      try {
        final keys = prefs.getKeys();
        final workerKey = keys.firstWhere(
          (k) => k.startsWith('workers_'),
          orElse: () => 'workers_default',
        );
        final workersJson = prefs.getString(workerKey) ?? '[]';
        final List<dynamic> workers = json.decode(workersJson);
        _attendanceCount = workers.length;
      } catch (_) {}

      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _showShopModulesSheet(BuildContext context) {
    final navContext = context;
    final items = <_ModuleAction>[
      _ModuleAction(
        color: const Color(0xFF4F46E5),
        icon: Icons.inventory_2_rounded,
        label: 'Inventory',
        onTap: () => Navigator.pushNamed(navContext, '/inventory'),
      ),
      _ModuleAction(
        color: const Color(0xFF10B981),
        icon: Icons.fact_check_rounded,
        label: 'Attendance',
        onTap: () => Navigator.pushNamed(navContext, '/attendance'),
      ),
      _ModuleAction(
        color: const Color(0xFFF59E0B),
        icon: Icons.groups_rounded,
        label: 'Customers',
        onTap: () => Navigator.pushNamed(navContext, '/customers'),
      ),
      _ModuleAction(
        color: const Color(0xFF2563EB),
        icon: Icons.receipt_long_rounded,
        label: 'Invoices',
        onTap: () => Navigator.pushNamed(navContext, '/invoices'),
      ),
      _ModuleAction(
        color: const Color(0xFF7C3AED),
        icon: Icons.badge_rounded,
        label: 'Workers',
        onTap: () async {
          if (await SecurityService.verifyMasterPin(navContext)) {
            if (!navContext.mounted) return;
            Navigator.pushNamed(navContext, '/worker-management');
          }
        },
      ),
      _ModuleAction(
        color: const Color(0xFF0D9488),
        icon: Icons.account_balance_wallet_rounded,
        label: 'Khata',
        onTap: () => Navigator.pushNamed(navContext, '/khata'),
      ),
      _ModuleAction(
        color: const Color(0xFFE11D48),
        icon: Icons.money_off_rounded,
        label: 'Expenses',
        onTap: () => Navigator.pushNamed(navContext, '/expense'),
      ),
      _ModuleAction(
        color: const Color(0xFF059669),
        icon: Icons.account_balance_rounded,
        label: 'Bank Recon',
        onTap: () => Navigator.pushNamed(navContext, '/bank-statement-parser'),
      ),
      _ModuleAction(
        color: const Color(0xFF7C3AED),
        icon: Icons.auto_awesome_rounded,
        label: 'Retail Growth',
        subtitle: 'AI & analytics',
        onTap: () => Navigator.pushNamed(navContext, '/retail-growth'),
      ),
      _ModuleAction(
        color: const Color(0xFF2563EB),
        icon: Icons.storefront_rounded,
        label: 'Online Store',
        subtitle: 'Marketplace & orders',
        onTap: () => Navigator.push(
          navContext,
          MaterialPageRoute(builder: (_) => const OnlineStoreHubPage()),
        ),
      ),
    ];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      builder: (ctx) => _ModulesSheet(
        items: items,
        onClosed: widget.onModuleClosed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE7EAF0)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFF7C3AED).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.widgets_rounded,
                  color: Color(0xFF7C3AED),
                  size: 16,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Shop Modules',
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF1F2937),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _showShopModulesSheet(context),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF4F46E5),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'View all',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 3),
                    const Icon(Icons.arrow_forward_rounded, size: 12),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              _buildOwnerQuickTile(
                color: const Color(0xFF4F46E5),
                icon: Icons.inventory_2_rounded,
                label: 'Inventory',
                subtitle: '$_inventoryCount items',
                onTap: () => Navigator.pushNamed(context, '/inventory')
                    .then((_) => widget.onModuleClosed()),
              ),
              const SizedBox(width: 6),
              _buildOwnerQuickTile(
                color: const Color(0xFF10B981),
                icon: Icons.receipt_long_rounded,
                label: 'Invoices',
                subtitle: '$_invoicesCount pending',
                onTap: () => Navigator.pushNamed(context, '/invoices')
                    .then((_) => widget.onModuleClosed()),
              ),
              const SizedBox(width: 6),
              _buildOwnerQuickTile(
                color: const Color(0xFFF59E0B),
                icon: Icons.how_to_reg_rounded,
                label: 'Attendance',
                subtitle: '$_attendanceCount staff',
                onTap: () => Navigator.pushNamed(context, '/attendance')
                    .then((_) => widget.onModuleClosed()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOwnerQuickTile({
    required Color color,
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.97, end: 1),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, scale, child) => Transform.scale(
          scale: scale,
          child: child,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(13),
            child: Ink(
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: color.withValues(alpha: 0.14),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.09),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, color: color, size: 15),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF1F2937),
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 8,
                      color: const Color(0xFF6B7280),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModuleAction {
  final Color color;
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _ModuleAction({
    required this.color,
    required this.icon,
    required this.label,
    this.subtitle,
    required this.onTap,
  });
}

class _ModulesSheet extends StatefulWidget {
  final List<_ModuleAction> items;
  final VoidCallback onClosed;

  const _ModulesSheet({
    required this.items,
    required this.onClosed,
  });

  @override
  State<_ModulesSheet> createState() => _ModulesSheetState();
}

class _ModulesSheetState extends State<_ModulesSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 14),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD1D5DB),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 11),
            Row(
              children: [
                const Icon(
                  Icons.widgets_rounded,
                  size: 18,
                  color: Color(0xFF4F46E5),
                ),
                const SizedBox(width: 8),
                Text(
                  'Shop modules',
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF111827),
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, size: 20),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.items.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 8,
                childAspectRatio: 0.92,
              ),
              itemBuilder: (context, index) {
                final item = widget.items[index];
                final start = (index / widget.items.length) * 0.55;
                final end = (start + 0.45).clamp(0.0, 1.0);
                final curved = CurvedAnimation(
                  parent: _controller,
                  curve: Interval(start, end, curve: Curves.easeOutCubic),
                );
                return AnimatedBuilder(
                  animation: curved,
                  builder: (context, child) {
                    final opacity = curved.value;
                    final dy = 12 * (1 - curved.value);
                    return Opacity(
                      opacity: opacity,
                      child: Transform.translate(
                        offset: Offset(0, dy),
                        child: child,
                      ),
                    );
                  },
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        Navigator.pop(context);
                        await Future<void>.delayed(
                          const Duration(milliseconds: 90),
                        );
                        if (!context.mounted) return;
                        item.onTap();
                        widget.onClosed();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: item.color.withValues(alpha: 0.09),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                item.icon,
                                color: item.color,
                                size: 21,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              item.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.poppins(
                                fontSize: 8.8,
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFF374151),
                                height: 1.1,
                              ),
                            ),
                            if (item.subtitle != null) ...[
                              const SizedBox(height: 1),
                              Text(
                                item.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.poppins(
                                  fontSize: 7,
                                  color: const Color(0xFF9CA3AF),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
