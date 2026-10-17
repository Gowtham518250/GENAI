import '../../../live_translated_text.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

/// Displays real online search offers and nearby map listings returned by the backend.
/// Local map results are not presented as confirmed inventory or shelf prices.
class ProductDiscoveryCard extends StatelessWidget {
  final Map<String, dynamic> data;
  /// When used in Purchase Orders, the cheapest returned listing is labelled as
  /// the best listed price, with pack-size/fees caveats shown by that screen.
  final bool purchaseAssistantMode;

  const ProductDiscoveryCard({
    super.key,
    required this.data,
    this.purchaseAssistantMode = false,
  });

  List<Map<String, dynamic>> _asMaps(dynamic value) {
    if (value is! List) return <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  String _price(dynamic value) {
    final parsed = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
    return parsed == null ? 'Price unavailable' : '₹' + parsed.toStringAsFixed(2);
  }

  Future<void> _openLink(BuildContext context, String? rawUrl) async {
    final uri = Uri.tryParse((rawUrl ?? '').trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LiveTranslatedText('A safe HTTPS link is not available for this result.')),
      );
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LiveTranslatedText('Could not open this listing.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LiveTranslatedText('Could not open this listing.')),
        );
      }
    }
  }

  Future<void> _callShop(BuildContext context, String? phone) async {
    final clean = (phone ?? '').trim();
    if (clean.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LiveTranslatedText('This shop has no public phone number in the listing.')),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: clean);
    try {
      final opened = await launchUrl(uri);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LiveTranslatedText('Could not open the phone app.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LiveTranslatedText('Could not open the phone app.')),
        );
      }
    }
  }

  Widget _sectionHeading({
    required IconData icon,
    required String title,
    required int count,
  }) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFFEFF2FF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: const Color(0xFF4F46E5), size: 19),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: LiveTranslatedText(
            title,
            style: GoogleFonts.inter(
              color: const Color(0xFF17264A),
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(20),
          ),
          child: LiveTranslatedText(
            count.toString(),
            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final offers = _asMaps(data['online_offers']);
    final shops = _asMaps(data['nearby_shops']);
    final locationAvailable = data['location_available'] == true;
    final productQuery = data['product_query']?.toString() ?? 'product';
    final note = data['price_comparison_note']?.toString() ?? '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFDDE5F5)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF203A68).withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shopping_bag_rounded, color: Color(0xFF4F46E5), size: 22),
              const SizedBox(width: 9),
              Expanded(
                child: LiveTranslatedText(
                  'Product results for ' + productQuery,
                  style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800, color: const Color(0xFF17264A)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LiveTranslatedText(
            'Online prices are ranked lowest first. Confirm the exact pack size before comparing.',
            style: GoogleFonts.inter(fontSize: 11.5, height: 1.45, color: const Color(0xFF64748B)),
          ),
          const SizedBox(height: 16),
          _sectionHeading(
            icon: Icons.price_check_rounded,
            title: 'Online price comparison',
            count: offers.length,
          ),
          const SizedBox(height: 9),
          if (offers.isEmpty)
            _emptyMessage('No priced online listings were returned. Try adding a brand or pack size.')
          else
            ...offers.take(10).toList().asMap().entries.map((entry) {
              final offer = entry.value;
              final title = offer['title']?.toString() ?? productQuery;
              final source = offer['source']?.toString() ?? 'Online retailer';
              final delivery = offer['delivery']?.toString() ?? '';
              final rating = offer['rating']?.toString();
              final reviews = offer['reviews']?.toString();
              final isCheapest = entry.key == 0;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: isCheapest ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: isCheapest ? const Color(0xFFBBF7D0) : const Color(0xFFE2E8F0),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 33,
                      height: 33,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: LiveTranslatedText(
                        (entry.key + 1).toString(),
                        style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: const Color(0xFF334155)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (isCheapest)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: LiveTranslatedText(
                                purchaseAssistantMode
                                    ? 'BEST LISTED PRICE · VERIFY PACK'
                                    : 'LOWEST LISTED PRICE',
                                style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w800, color: const Color(0xFF047857), letterSpacing: 0.3),
                              ),
                            ),
                          LiveTranslatedText(
                            title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: const Color(0xFF1E293B), height: 1.4),
                          ),
                          const SizedBox(height: 3),
                          LiveTranslatedText(source, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF64748B))),
                          if (rating != null && rating.isNotEmpty)
                            LiveTranslatedText(
                              'Rating ' + rating + (reviews != null && reviews.isNotEmpty ? ' (' + reviews + ' reviews)' : ''),
                              style: GoogleFonts.inter(fontSize: 10, color: const Color(0xFF64748B)),
                            ),
                          if (delivery.isNotEmpty)
                            LiveTranslatedText(delivery, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 10, color: const Color(0xFF64748B))),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        LiveTranslatedText(
                          _price(offer['price']),
                          style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w800, color: isCheapest ? const Color(0xFF047857) : const Color(0xFF17264A)),
                        ),
                        TextButton(
                          onPressed: () => _openLink(context, offer['url']?.toString()),
                          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 5), minimumSize: const Size(0, 32), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          child: const LiveTranslatedText('Open'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          const SizedBox(height: 10),
          Divider(color: Colors.grey.shade200),
          const SizedBox(height: 8),
          _sectionHeading(
            icon: Icons.storefront_rounded,
            title: 'Nearby shops',
            count: shops.length,
          ),
          const SizedBox(height: 6),
          LiveTranslatedText(
            locationAvailable
                ? 'Sorted by distance. Local stock and shelf prices are not confirmed by map listings.'
                : 'Location is unavailable. Allow location access and ask again to find shops near you.',
            style: GoogleFonts.inter(fontSize: 11, height: 1.45, color: const Color(0xFF64748B)),
          ),
          const SizedBox(height: 9),
          if (shops.isEmpty)
            _emptyMessage(
              locationAvailable
                  ? 'No nearby shops were returned for this search.'
                  : 'No nearby stores shown without your location.',
            )
          else
            ...shops.map((shop) {
              final name = shop['name']?.toString() ?? 'Local shop';
              final address = shop['address']?.toString() ?? '';
              final distance = double.tryParse(shop['distance_km']?.toString() ?? '');
              final rating = shop['rating']?.toString();
              final openState = shop['open_state']?.toString() ?? '';
              final phone = shop['phone']?.toString() ?? '';
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.store_rounded, size: 19, color: Color(0xFF4F46E5)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LiveTranslatedText(name, style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w800, color: const Color(0xFF1E293B))),
                        ),
                        if (distance != null)
                          LiveTranslatedText(
                            distance.toStringAsFixed(1) + ' km',
                            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: const Color(0xFF475569)),
                          ),
                      ],
                    ),
                    if (address.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      LiveTranslatedText(address, style: GoogleFonts.inter(fontSize: 11, height: 1.4, color: const Color(0xFF475569))),
                    ],
                    if (rating != null && rating.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: LiveTranslatedText('★ ' + rating + (openState.isNotEmpty ? '  •  ' + openState : ''),
                          style: GoogleFonts.inter(fontSize: 10.5, color: const Color(0xFF64748B))),
                      )
                    else if (openState.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: LiveTranslatedText(openState, style: GoogleFonts.inter(fontSize: 10.5, color: const Color(0xFF64748B))),
                      ),
                    const SizedBox(height: 8),
                    LiveTranslatedText(
                      productQuery + ' price / stock: call to confirm',
                      style: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.w700, color: const Color(0xFF92400E)),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _openLink(context, shop['maps_url']?.toString()),
                          icon: const Icon(Icons.directions_rounded, size: 15),
                          label: const LiveTranslatedText('Directions'),
                          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), visualDensity: VisualDensity.compact),
                        ),
                        if (phone.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () => _callShop(context, phone),
                            icon: const Icon(Icons.call_rounded, size: 15),
                            label: const LiveTranslatedText('Call shop'),
                            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), visualDensity: VisualDensity.compact),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline_rounded, size: 17, color: Color(0xFF92400E)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LiveTranslatedText(note, style: GoogleFonts.inter(fontSize: 10.5, height: 1.45, color: const Color(0xFF92400E))),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyMessage(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: LiveTranslatedText(
        text,
        style: GoogleFonts.inter(
          fontSize: 11.5,
          height: 1.4,
          color: const Color(0xFF64748B),
        ),
      ),
    );
  }
}
