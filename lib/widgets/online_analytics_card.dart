import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Compact dashboard entry point for the online store.
/// Full analytics remain available after tapping this row.
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
    final hasPending = pendingOrders > 0;
    final statusColor =
        hasPending ? const Color(0xFFF59E0B) : const Color(0xFF16A34A);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A).withValues(alpha: 0.055),
                blurRadius: 16,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF5B3DF5), Color(0xFF4F6CF7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.storefront_rounded,
                  color: Colors.white,
                  size: 21,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Online Store',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              color: const Color(0xFF111827),
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.09),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                hasPending ? '$pendingOrders pending' : 'All caught up',
                                style: GoogleFonts.poppins(
                                  color: statusColor,
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      totalOrders.toString() + ' orders  •  ₹' +
                          totalRevenue.toStringAsFixed(0) +
                          ' revenue  •  ' + totalPaidCount.toString() + ' paid',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        color: const Color(0xFF64748B),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F6FF),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Open',
                      style: GoogleFonts.poppins(
                        color: const Color(0xFF4F46E5),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_forward_rounded, color: Color(0xFF4F46E5), size: 15),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}