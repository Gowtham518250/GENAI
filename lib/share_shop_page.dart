import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'screens/owner/online_store_hub_page.dart';

/// Backwards-compatible fallback for older navigation references.
/// The product no longer uses link-first "Share Shop" ordering.
class ShareShopPage extends StatelessWidget {
  const ShareShopPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(
          'Online Store',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w800),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFEEF2FF), Color(0xFFE0F2FE)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFC7D2FE)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.storefront_rounded,
                  color: Color(0xFF4F46E5),
                  size: 38,
                ),
                const SizedBox(height: 14),
                Text(
                  'Your shop is discoverable through the marketplace',
                  style: GoogleFonts.poppins(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Customers can search for your shop by name or discover your products across the marketplace. You do not need to send a shop link to every customer.',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    height: 1.5,
                    color: const Color(0xFF4B5563),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _ActionCard(
            icon: Icons.settings_rounded,
            title: 'Manage Online Store',
            subtitle: 'Enable or disable online shopping and configure your online order fee.',
            onTap: () => Navigator.pushNamed(context, '/online-store-manager'),
          ),
          const SizedBox(height: 12),
          _ActionCard(
            icon: Icons.receipt_long_rounded,
            title: 'View Online Orders',
            subtitle: 'See pending, accepted, dispatched and delivered orders.',
            onTap: () => Navigator.pushNamed(context, '/online-orders'),
          ),
          const SizedBox(height: 12),
          _ActionCard(
            icon: Icons.store_mall_directory_rounded,
            title: 'Open Store Hub',
            subtitle: 'Manage inventory, storefront settings and the customer experience.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const OnlineStoreHubPage()),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF4F46E5).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: const Color(0xFF4F46E5)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        height: 1.4,
                        color: const Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: Color(0xFF9CA3AF),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
