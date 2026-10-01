import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class OnlineAnalyticsCard extends StatelessWidget {
  final int pendingOrders;
  final int totalOrders;
  final double totalRevenue;
  final int totalPaidCount;
  final int todayOrderCount;
  final double todayRevenue;
  final int todayPaidCount;
  final VoidCallback onTap;

  const OnlineAnalyticsCard({
    super.key,
    required this.pendingOrders,
    required this.totalOrders,
    required this.totalRevenue,
    required this.totalPaidCount,
    required this.todayOrderCount,
    required this.todayRevenue,
    required this.todayPaidCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF5B3DF5), Color(0xFF7058F7), Color(0xFF4A6CF7)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF5B3DF5).withValues(alpha: 0.24),
                blurRadius: 26,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                    ),
                    child: const Icon(
                      Icons.storefront_rounded,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Online Store Overview',
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '' + totalOrders.toString() + ' orders across your online store',
                          style: GoogleFonts.poppins(
                            color: Colors.white.withValues(alpha: 0.68),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _statusPill(),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _metric(Icons.shopping_bag_rounded, 'Total orders', '' + totalOrders.toString() + ''),
                  _metric(Icons.schedule_rounded, 'Pending', '' + pendingOrders.toString() + ''),
                  _metric(Icons.payments_rounded, 'Revenue', '₹' + totalRevenue.toStringAsFixed(0) + ''),
                  _metric(Icons.verified_rounded, 'Paid', '' + totalPaidCount.toString() + ''),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.today_rounded, size: 16, color: Colors.white),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Today: ' + todayOrderCount.toString() + ' orders · ₹' + todayRevenue.toStringAsFixed(0) + ' revenue · ' + todayPaidCount.toString() + ' paid',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_forward_rounded, size: 17, color: Colors.white70),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusPill() {
    final label = pendingOrders > 0 ? '' + pendingOrders.toString() + ' pending' : 'All caught up';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: pendingOrders > 0
                  ? const Color(0xFFFDE68A)
                  : const Color(0xFF86EFAC),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String label, String value) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 7),
        padding: const EdgeInsets.fromLTRB(10, 10, 8, 9),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.white70, size: 15),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                color: Colors.white70,
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}