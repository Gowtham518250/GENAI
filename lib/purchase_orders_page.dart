import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api_client.dart';
import 'local_storage_service.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';
import 'features/ai_query/widgets/product_discovery_card.dart';

class PurchaseOrdersPage extends StatefulWidget {
  const PurchaseOrdersPage({super.key});
  @override
  State<PurchaseOrdersPage> createState() => _PurchaseOrdersPageState();
}

class _PurchaseOrdersPageState extends State<PurchaseOrdersPage> {
  bool _loading = true;
  List<dynamic> _orders = [];
  bool _reorderLoading = false;
  List<Map<String, dynamic>> _reorderSuggestions = [];
  String _reorderNotice = 'Checking products against their reorder levels…';
  final TextEditingController _shoppingChatController = TextEditingController();
  final ScrollController _shoppingChatScrollController = ScrollController();
  final List<Map<String, dynamic>> _shoppingChatMessages = [];
  bool _shoppingSearchLoading = false;

  static const _bg = Color(0xFFF6F8FF);
  // Keep the existing purchase-order creation sheet dark; the main screen is light.
  static const _card = Color(0xFF16213E);
  static const _surface = Colors.white;
  static const _ink = Color(0xFF142044);
  static const _muted = Color(0xFF64748B);
  static const _primary = Color(0xFF5146F2);
  static const _border = Color(0xFFE1E8F5);

  @override
  void initState() {
    super.initState();
    _fetchOrders();
    _fetchReorderRecommendations();
  }

  Future<void> _fetchReorderRecommendations({bool lookupOnline = true}) async {
    if (mounted) setState(() => _reorderLoading = true);
    try {
      final res = await ApiClient.getJson(
        '/purchase-orders/reorder-recommendations?lookup_online=${lookupOnline ? 'true' : 'false'}&limit=12',
      ).timeout(const Duration(seconds: 55));
      final decoded = jsonDecode(res.body);
      if (res.statusCode == 200 && decoded is Map) {
        final rawItems = decoded['items'];
        final items = rawItems is List
            ? rawItems.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : <Map<String, dynamic>>[];
        if (!mounted) return;
        setState(() {
          _reorderSuggestions = items;
          _reorderNotice = (decoded['notice'] ?? '').toString();
        });
      } else {
        final detail = decoded is Map ? (decoded['detail'] ?? decoded['message'])?.toString() : null;
        if (mounted) setState(() => _reorderNotice = detail?.trim().isNotEmpty == true
            ? detail!.trim()
            : 'Could not load stock-reorder suggestions. Refresh to try again.');
      }
    } catch (e) {
      if (mounted) setState(() => _reorderNotice =
          'Stock suggestions are temporarily unavailable. Check the connection and refresh.');
      debugPrint('⚠️ Reorder recommendations unavailable: $e');
    } finally {
      if (mounted) setState(() => _reorderLoading = false);
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_fetchOrders(), _fetchReorderRecommendations()]);
  }

  double _number(dynamic value, [double fallback = 0]) =>
      value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '') ?? fallback;

  String _money(dynamic value) => '₹${_number(value).toStringAsFixed(2)}';

  Future<void> _openOffer(dynamic rawUrl) async {
    final url = Uri.tryParse(rawUrl?.toString() ?? '');
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The seller did not provide a usable product link.')),
      );
      return;
    }
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened && mounted) ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the seller link.')),
    );
  }

  @override
  void dispose() {
    _shoppingChatController.dispose();
    _shoppingChatScrollController.dispose();
    super.dispose();
  }

  Future<Position?> _requestPurchaseSearchLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 8));
    } catch (error) {
      debugPrint('Purchase product search location unavailable: $error');
      return null;
    }
  }

  void _scrollShoppingChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_shoppingChatScrollController.hasClients) return;
      _shoppingChatScrollController.animateTo(
        _shoppingChatScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  List<Map<String, dynamic>> _mapList(dynamic value) {
    if (value is! List) return <Map<String, dynamic>>[];
    return value.whereType<Map>().map((entry) => Map<String, dynamic>.from(entry)).toList();
  }

  Future<void> _sendPurchaseShoppingQuery({String? query}) async {
    final question = (query ?? _shoppingChatController.text).trim();
    if (question.isEmpty || _shoppingSearchLoading) return;

    _shoppingChatController.clear();
    setState(() {
      _shoppingSearchLoading = true;
      _shoppingChatMessages.add({'role': 'user', 'text': question});
    });
    _scrollShoppingChatToEnd();

    try {
      // This search is launched from Purchase Orders, not the Ask Retail Mind
      // chat. Location is requested only after the user submits a product query.
      final position = await _requestPurchaseSearchLocation();
      final fields = <String, String>{
        'query': question,
        'language_code': 'en',
        'radius_km': '10',
      };
      if (position != null) {
        fields['latitude'] = position.latitude.toStringAsFixed(6);
        fields['longitude'] = position.longitude.toStringAsFixed(6);
      }

      final response = await ApiClient.postForm(
        ApiClient.askQueryProductDiscoveryEndpoint,
        fields,
      ).timeout(const Duration(seconds: 55));

      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        if (decoded is! Map) {
          throw Exception('The product search returned an invalid response.');
        }
        final payload = Map<String, dynamic>.from(decoded);
        final rawDiscovery = payload['product_discovery'];
        if (rawDiscovery is! Map) {
          throw Exception('No product-comparison data was returned. Please try a product name and pack size.');
        }

        final discovery = Map<String, dynamic>.from(rawDiscovery);
        final offers = _mapList(discovery['online_offers']);
        offers.removeWhere((offer) {
          final value = offer['price'];
          final price = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
          return price == null || !price.isFinite || price <= 0;
        });
        offers.sort((a, b) {
          final ap = _number(a['price'], double.maxFinite);
          final bp = _number(b['price'], double.maxFinite);
          return ap.compareTo(bp);
        });
        discovery['online_offers'] = offers;

        var answer = (payload['answer'] ?? 'Here are the available product listings.').toString();
        if (offers.isNotEmpty) {
          final best = offers.first;
          final source = (best['source'] ?? 'online seller').toString();
          answer = 'Best listed price: ${_money(best['price'])} from $source. '
              'This is the lowest returned listing, not a guaranteed best-value deal; confirm the brand, exact pack size, delivery fees and checkout price. '
              '$answer';
        } else {
          answer = 'I could not find a priced online listing for this product. Try adding a brand or pack size. $answer';
        }

        if (mounted) {
          setState(() {
            _shoppingChatMessages.add({
              'role': 'assistant',
              'text': answer,
              'product_discovery': discovery,
            });
          });
        }
      } else {
        final detail = decoded is Map
            ? (decoded['detail'] ?? decoded['message'] ?? decoded['error'])?.toString()
            : null;
        throw Exception(
          detail != null && detail.trim().isNotEmpty
              ? detail.trim()
              : 'Online product search is temporarily unavailable. Please try again.',
        );
      }
    } on TimeoutException {
      if (mounted) {
        setState(() => _shoppingChatMessages.add({
          'role': 'assistant',
          'text': 'The product search took too long. Please try again.',
        }));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _shoppingChatMessages.add({
          'role': 'assistant',
          'text': error.toString().replaceFirst('Exception: ', ''),
        }));
      }
      debugPrint('Purchase-order product search failed: $error');
    } finally {
      if (mounted) setState(() => _shoppingSearchLoading = false);
      _scrollShoppingChatToEnd();
    }
  }

  Widget _buildPurchaseShoppingChat() {
    final hasMessages = _shoppingChatMessages.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF233B73).withValues(alpha: 0.07),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 20, 14, 20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFF0E9FF), Color(0xFFE8F6FF)],
              ),
              borderRadius: BorderRadius.vertical(top: Radius.circular(27)),
            ),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6557F5), Color(0xFF3D83F6)],
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: _primary.withValues(alpha: 0.22),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.shopping_cart_rounded, color: Colors.white, size: 29),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Purchase Shopping Assistant',
                        style: GoogleFonts.poppins(
                          color: _ink,
                          fontSize: 15.5,
                          height: 1.35,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Find products beyond your inventory',
                        style: GoogleFonts.poppins(
                          color: const Color(0xFF596986),
                          fontSize: 11.5,
                          height: 1.4,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Clear shopping chat',
                  visualDensity: VisualDensity.compact,
                  onPressed: _shoppingSearchLoading
                      ? null
                      : () => setState(() => _shoppingChatMessages.clear()),
                  icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFF71809D), size: 21),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Search any product, compare online prices, and discover nearby shops — even when it is not in your stock list.',
                  style: GoogleFonts.poppins(color: _muted, fontSize: 12, height: 1.6),
                ),
                if (!hasMessages) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 182,
                    width: double.infinity,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 198,
                          height: 158,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFE8E8FF), Color(0xFFEAF7FF)],
                            ),
                          ),
                        ),
                        const Icon(Icons.shopping_basket_rounded, size: 110, color: Color(0xFF5B55ED)),
                        Align(
                          alignment: const Alignment(-0.82, -0.48),
                          child: Container(
                            width: 45,
                            height: 45,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFEEF0),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.location_on_rounded, color: Color(0xFFF16B78), size: 25),
                          ),
                        ),
                        Align(
                          alignment: const Alignment(0.82, -0.4),
                          child: Container(
                            width: 45,
                            height: 45,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE1FAF4),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.sell_rounded, color: Color(0xFF10A88A), size: 24),
                          ),
                        ),
                        Align(
                          alignment: const Alignment(0.62, 0.83),
                          child: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFFDDE5FF), width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: _primary.withValues(alpha: 0.15),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: const Icon(Icons.search_rounded, size: 31, color: Color(0xFF437DF2)),
                          ),
                        ),
                        const Align(
                          alignment: Alignment(-0.82, 0.58),
                          child: Icon(Icons.auto_awesome_rounded, color: Color(0xFF9687FF), size: 18),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'What are you looking to buy?',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(color: _ink, fontSize: 19, height: 1.35, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'Search your inventory or discover new products online.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(color: _muted, fontSize: 11.5, height: 1.6),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 9,
                    children: [
                      _shoppingPromptChip('Find ghee'),
                      _shoppingPromptChip('Compare rice prices'),
                      _shoppingPromptChip('Search cooking oil'),
                    ],
                  ),
                ] else ...[
                  const SizedBox(height: 15),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 480),
                    child: ListView.builder(
                      controller: _shoppingChatScrollController,
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 2),
                      itemCount: _shoppingChatMessages.length + (_shoppingSearchLoading ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= _shoppingChatMessages.length) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3F5FF),
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: _primary),
                                  ),
                                  const SizedBox(width: 9),
                                  Flexible(
                                    child: Text(
                                      'Comparing online listings and nearby shops…',
                                      style: GoogleFonts.poppins(color: _muted, fontSize: 11),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        final message = _shoppingChatMessages[index];
                        final isUser = message['role'] == 'user';
                        final data = message['product_discovery'];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 13),
                          child: Column(
                            crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                            children: [
                              Container(
                                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                                decoration: BoxDecoration(
                                  gradient: isUser
                                      ? const LinearGradient(colors: [Color(0xFF6557F5), Color(0xFF3D83F6)])
                                      : null,
                                  color: isUser ? null : const Color(0xFFF3F5FB),
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(17),
                                    topRight: const Radius.circular(17),
                                    bottomLeft: Radius.circular(isUser ? 17 : 5),
                                    bottomRight: Radius.circular(isUser ? 5 : 17),
                                  ),
                                ),
                                child: Text(
                                  (message['text'] ?? '').toString(),
                                  style: GoogleFonts.poppins(
                                    color: isUser ? Colors.white : _ink,
                                    fontSize: 12,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                              if (!isUser && data is Map) ...[
                                const SizedBox(height: 9),
                                ProductDiscoveryCard(
                                  data: Map<String, dynamic>.from(data),
                                  purchaseAssistantMode: true,
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 19),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFF),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFFE3E8F5)),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF233B73).withValues(alpha: 0.05),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 13),
                      const Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFF7583A0), size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _shoppingChatController,
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendPurchaseShoppingQuery(),
                          style: GoogleFonts.poppins(color: _ink, fontSize: 12),
                          decoration: InputDecoration(
                            hintText: 'Ask for any product or supplier…',
                            hintStyle: GoogleFonts.poppins(color: const Color(0xFF8490A8), fontSize: 11),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        margin: const EdgeInsets.only(right: 5),
                        width: 45,
                        height: 45,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Color(0xFF6557F5), Color(0xFF3D83F6)]),
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: IconButton(
                          tooltip: 'Search products online',
                          onPressed: _shoppingSearchLoading ? null : () => _sendPurchaseShoppingQuery(),
                          color: Colors.white,
                          icon: const Icon(Icons.arrow_forward_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 13),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF2F4FC),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.tune_rounded, size: 15, color: Color(0xFF5D6B85)),
                          const SizedBox(width: 5),
                          Text(
                            'Online + nearby',
                            style: GoogleFonts.poppins(color: const Color(0xFF4A5874), fontSize: 9.5, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 9),
                    const Icon(Icons.verified_user_outlined, size: 16, color: Color(0xFF7986A0)),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        'Online prices may vary. Confirm stock and final price with the seller.',
                        style: GoogleFonts.poppins(color: _muted, fontSize: 9.2, height: 1.45),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _shoppingPromptChip(String label) {
    final width = ((MediaQuery.sizeOf(context).width - 92) / 3).clamp(72.0, 132.0).toDouble();
    final icon = label.contains('ghee')
        ? Icons.breakfast_dining_rounded
        : label.contains('rice')
            ? Icons.rice_bowl_rounded
            : Icons.water_drop_rounded;
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: _shoppingSearchLoading ? null : () => _sendPurchaseShoppingQuery(query: label),
          child: Container(
            constraints: const BoxConstraints(minHeight: 82),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFD5E3FF)),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 25,
                  color: label.contains('ghee')
                      ? const Color(0xFFDC9B20)
                      : label.contains('rice')
                          ? const Color(0xFFB87847)
                          : const Color(0xFFE7A525),
                ),
                const SizedBox(height: 7),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(color: _ink, fontSize: 9.5, height: 1.3, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReorderSuggestions() {
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(color: const Color(0xFF233B73).withValues(alpha: 0.04), blurRadius: 18, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: const Color(0xFFFFF4DF), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.inventory_2_outlined, color: Color(0xFFCF8B18)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text('Low-stock reorder suggestions',
              style: GoogleFonts.poppins(color: _ink, fontSize: 14, fontWeight: FontWeight.w800))),
          IconButton(
            tooltip: 'Refresh stock and online prices',
            onPressed: _reorderLoading ? null : () => _fetchReorderRecommendations(),
            icon: _reorderLoading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: _primary))
                : const Icon(Icons.refresh_rounded, color: _muted),
          ),
        ]),
        Text(
          'Items at or below your reorder threshold. Online listings are comparison hints, not confirmed wholesale quotes. Creating a PO here does not place an online order.',
          style: GoogleFonts.poppins(color: _muted, fontSize: 11, height: 1.55),
        ),
        if (_reorderLoading && _reorderSuggestions.isEmpty) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(color: _primary),
        ],
        if (!_reorderLoading && _reorderSuggestions.isEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFF8FAFD), borderRadius: BorderRadius.circular(13)),
            child: Text(
              _reorderNotice.contains('SERPAPI_API_KEY')
                  ? 'No low-stock items were returned, or online price search needs configuration. Check inventory thresholds and backend settings.'
                  : 'No products are currently at or below their configured reorder level.',
              style: GoogleFonts.poppins(color: _muted, fontSize: 11.5, height: 1.45),
            ),
          ),
        ],
        if (_reorderSuggestions.isNotEmpty) ...[
          const SizedBox(height: 12),
          ..._reorderSuggestions.map(_buildReorderCard),
        ],
        if (_reorderNotice.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_reorderNotice, style: GoogleFonts.poppins(color: const Color(0xFF7D8BA4), fontSize: 10, height: 1.35)),
        ],
      ]),
    );
  }

  Widget _buildReorderCard(Map<String, dynamic> item) {
    final offers = item['online_offers'] is List
        ? (item['online_offers'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    final stock = _number(item['current_stock']);
    final minStock = _number(item['min_stock']);
    final triggerStock = _number(item['reorder_level']) > minStock ? _number(item['reorder_level']) : minStock;
    final suggestedQty = (_number(item['suggested_reorder_qty'], 1)).ceil().clamp(1, 1000000);
    final recordedCost = _number(item['recorded_purchase_price']);
    final bestPrice = _number(item['best_online_price'], -1);
    final urgency = (item['urgency'] ?? 'REORDER').toString().toUpperCase();
    final urgencyColor = urgency == 'CRITICAL'
        ? const Color(0xFFDC2626)
        : urgency == 'HIGH'
            ? const Color(0xFFEA580C)
            : const Color(0xFFD97706);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFE),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFE6EAF4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text((item['product_name'] ?? 'Unnamed product').toString(),
              style: GoogleFonts.poppins(color: _ink, fontWeight: FontWeight.w700, fontSize: 13))),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: urgencyColor.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8)),
            child: Text(urgency, style: GoogleFonts.poppins(color: urgencyColor, fontSize: 9, fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 7),
        Text('Stock: ${stock.toStringAsFixed(stock % 1 == 0 ? 0 : 2)} • Reorder threshold: ${triggerStock.toStringAsFixed(triggerStock % 1 == 0 ? 0 : 2)} • Suggested quantity: $suggestedQty',
            style: GoogleFonts.poppins(color: _muted, fontSize: 10.5, height: 1.5)),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 5, children: [
          Text('Recorded cost ${_money(recordedCost)}', style: GoogleFonts.poppins(color: const Color(0xFF53627E), fontSize: 11)),
          if (bestPrice > 0) Text('Lowest online ${_money(bestPrice)}', style: GoogleFonts.poppins(color: const Color(0xFF07856D), fontWeight: FontWeight.bold, fontSize: 11)),
          if (bestPrice > 0 && recordedCost > 0)
            Text(bestPrice < recordedCost ? '₹${(recordedCost - bestPrice).toStringAsFixed(2)} lower' : bestPrice > recordedCost ? '₹${(bestPrice - recordedCost).toStringAsFixed(2)} higher' : 'Same as recorded cost',
                style: GoogleFonts.poppins(color: bestPrice <= recordedCost ? const Color(0xFF16885E) : const Color(0xFFB7791F), fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        if (offers.isNotEmpty) ...[
          const SizedBox(height: 7),
          ...offers.take(3).map((offer) => Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Row(children: [
              Expanded(child: Text('${offer['source'] ?? 'Online seller'} · ${offer['title'] ?? item['product_name']}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(color: _muted, fontSize: 10))),
              const SizedBox(width: 6),
              Text(_money(offer['price']), style: GoogleFonts.poppins(color: _ink, fontSize: 10, fontWeight: FontWeight.w700)),
              TextButton(
                onPressed: () => _openOffer(offer['url']),
                style: TextButton.styleFrom(minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 7), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('Open'),
              ),
            ]),
          )),
        ] else if ((item['online_lookup_message'] ?? '').toString().trim().isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(item['online_lookup_message'].toString(), style: GoogleFonts.poppins(color: const Color(0xFF8490A8), fontSize: 10)),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: () => _showCreatePO(suggestion: item),
            icon: const Icon(Icons.playlist_add, size: 17),
            label: Text('Draft purchase order ($suggestedQty)', style: const TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _primary,
              side: const BorderSide(color: Color(0xFFBFCBFF)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildOrderCard(dynamic po, int i) {
    final status = (po['status'] ?? 'PENDING').toString().toUpperCase();
    final statusColor = _statusColor(status);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(color: const Color(0xFF233B73).withValues(alpha: 0.035), blurRadius: 14, offset: const Offset(0, 5)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('PO #${po['id'] ?? i + 1}', style: GoogleFonts.poppins(color: _ink, fontWeight: FontWeight.w800)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8)),
            child: Text(status, style: GoogleFonts.poppins(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(po['supplier_name']?.toString() ?? 'Supplier', style: GoogleFonts.poppins(color: _muted)),
        const SizedBox(height: 4),
        Text('₹${po['total_cost']?.toString() ?? '0'}', style: GoogleFonts.poppins(color: const Color(0xFF079579), fontWeight: FontWeight.w800, fontSize: 18)),
        if (status == 'PENDING') ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
              onPressed: () => _markDelivered(po['id']), icon: const Icon(Icons.check, size: 16), label: const Text('Delivered'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16885E), foregroundColor: Colors.white),
            )),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton.icon(
              onPressed: () => _cancelPO(po['id']), icon: const Icon(Icons.close, size: 16), label: const Text('Cancel'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC4C58), foregroundColor: Colors.white),
            )),
          ]),
        ],
      ]),
    );
  }

  Future<void> _fetchOrders() async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> localOrders = [];

    try {
      final localPOData = prefs.getString('purchase_orders_data');
      if (localPOData != null && localPOData.isNotEmpty) {
        final d = jsonDecode(localPOData);
        final raw = d is List ? d : (d is Map && d['orders'] is List ? d['orders'] : const []);
        localOrders = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      debugPrint('⚠️ Error parsing local PO data: $e');
    }

    // Local source renders immediately, including pending offline orders.
    if (mounted) setState(() => _orders = localOrders);

    try {
      final res = await ApiClient.getJson('/purchase-orders/');
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body);
        final raw = d is List ? d : (d is Map && d['orders'] is List ? d['orders'] : const []);
        final remoteOrders = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();

        // Merge by server id while preserving local records that are still
        // pending in the canonical outbox. A remote refresh must not erase an
        // offline order before the server has acknowledged it.
        final merged = <String, Map<String, dynamic>>{};
        for (final local in localOrders) {
          final key = (local['server_id'] ?? local['id'] ?? local['operation_id'] ?? '').toString();
          if (key.isNotEmpty) merged[key] = local;
        }
        for (final remote in remoteOrders) {
          final key = (remote['id'] ?? remote['server_id'] ?? remote['order_id'] ?? '').toString();
          if (key.isEmpty) continue;
          final existing = merged[key];
          if (existing != null && existing['sync_status'] == 'pending') {
            merged[key] = {...remote, ...existing, 'sync_status': 'pending'};
          } else {
            merged[key] = {...?existing, ...remote, 'sync_status': existing?['sync_status'] ?? 'synced'};
          }
        }

        final mergedList = merged.values.toList();
        await prefs.setString('purchase_orders_data', jsonEncode(mergedList));
        if (mounted) setState(() => _orders = mergedList);
      }
    } catch (e) {
      debugPrint('⚠️ Backend PO sync failed, using local data: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _statusColor(String status) {
    switch (status.toUpperCase()) {
      case 'DELIVERED': return const Color(0xFF16885E);
      case 'CANCELLED': return const Color(0xFFDC4C58);
      default: return const Color(0xFFCA8A04);
    }
  }

  Future<void> _markDelivered(dynamic poId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('purchase_orders_data');
      final list = <dynamic>[];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) list.addAll(decoded);
      }

      var changed = false;
      for (var i = 0; i < list.length; i++) {
        final value = list[i];
        if (value is! Map) continue;
        if (value['id'].toString() == poId.toString()) {
          list[i] = {...Map<String, dynamic>.from(value), 'status': 'DELIVERED', 'sync_status': 'pending'};
          changed = true;
          break;
        }
      }

      if (!changed) throw StateError('Purchase order not found locally: $poId');
      await prefs.setString('purchase_orders_data', jsonEncode(list));
      if (mounted) setState(() => _orders = list);

      await SyncQueueManager.enqueue('update_purchase_order_status', {
        'operation_id': 'PO_STATUS_${poId}_delivered',
        'po_id': poId,
        'po_action': 'mark-delivered',
      });
      unawaited(SyncService.processQueueSafe());
    } catch (e) {
      debugPrint('❌ Failed to update local PO status: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update purchase order: $e')),
        );
      }
    }
  }

  Future<void> _cancelPO(dynamic poId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('purchase_orders_data');
      final list = <dynamic>[];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) list.addAll(decoded);
      }

      var changed = false;
      for (var i = 0; i < list.length; i++) {
        final value = list[i];
        if (value is! Map) continue;
        if (value['id'].toString() == poId.toString()) {
          list[i] = {...Map<String, dynamic>.from(value), 'status': 'CANCELLED', 'sync_status': 'pending'};
          changed = true;
          break;
        }
      }

      if (!changed) throw StateError('Purchase order not found locally: $poId');
      await prefs.setString('purchase_orders_data', jsonEncode(list));
      if (mounted) setState(() => _orders = list);

      await SyncQueueManager.enqueue('update_purchase_order_status', {
        'operation_id': 'PO_STATUS_${poId}_cancelled',
        'po_id': poId,
        'po_action': 'cancel',
      });
      unawaited(SyncService.processQueueSafe());
    } catch (e) {
      debugPrint('❌ Failed to cancel PO locally: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel purchase order: $e')),
        );
      }
    }
  }

  /// 🔧 FIX: previously this always sent `'items': []` — the backend's
  /// PurchaseOrderCreate schema requires `items: List[POItem]` with at
  /// least one entry (`min_length=1`), so every single "Create PO" here
  /// was rejected by the backend with a 422 the moment it tried to sync.
  /// This also durably queues the create so a flaky connection doesn't
  /// silently lose the order (matches the retry pattern used for sales).
  Future<void> _createPurchaseOrder(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('purchase_orders_data');
      final list = <dynamic>[];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) list.addAll(decoded);
      }

      final operationId =
          'PO_CREATE_${DateTime.now().millisecondsSinceEpoch}';
      final localOrder = {
        ...payload,
        'id': 'LOCAL-PO-${DateTime.now().millisecondsSinceEpoch}',
        'status': 'PENDING',
        'created_at': DateTime.now().toIso8601String(),
        'sync_status': 'pending',
        'operation_id': operationId,
      };

      list.insert(0, localOrder);
      await prefs.setString('purchase_orders_data', jsonEncode(list));
      if (mounted) setState(() => _orders = list);

      await SyncQueueManager.enqueue('create_purchase_order', {
        ...payload,
        'operation_id': operationId,
        'local_id': localOrder['id'],
      });

      // Canonical local-first path: the UI is already committed. Try to
      // deliver immediately; the durable outbox remains authoritative offline.
      unawaited(SyncService.processQueueSafe());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Purchase order saved locally and queued for sync.')),
        );
      }
    } catch (e) {
      debugPrint('❌ PO local save failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save purchase order: $e')),
        );
      }
    }
  }

  void _showCreatePO({Map<String, dynamic>? suggestion}) {
    final bestOffer = suggestion?['best_offer'] is Map
        ? Map<String, dynamic>.from(suggestion!['best_offer'] as Map)
        : <String, dynamic>{};
    final suggestedCost = _number(suggestion?['best_online_price'], _number(suggestion?['recorded_purchase_price']));
    final supplierC = TextEditingController(text: (bestOffer['source'] ?? '').toString());
    final notesC = TextEditingController(text: suggestion == null
        ? ''
        : 'Draft from low-stock recommendation. Confirm pack size, seller, final price and delivery before ordering.');
    List<Map<String, dynamic>> orderItems = suggestion == null ? [] : [
      {
        'product_id': suggestion['product_id'],
        'product_name': suggestion['product_name'],
        'quantity': (_number(suggestion['suggested_reorder_qty'], 1)).ceil().clamp(1, 1000000),
        'unit_cost': suggestedCost,
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> pickProduct() async {
            final products = await LocalStorageService.loadBackendProducts();
            if (!ctx.mounted) return;
            final selected = await showDialog<Map<String, dynamic>>(
              context: ctx,
              builder: (dCtx) => AlertDialog(
                backgroundColor: _card,
                title: const Text('Select Product', style: TextStyle(color: Colors.white)),
                content: SizedBox(
                  width: double.maxFinite,
                  height: 340,
                  child: products.isEmpty
                      ? const Center(child: Text('No products in inventory yet', style: TextStyle(color: Colors.white38)))
                      : ListView.builder(
                          itemCount: products.length,
                          itemBuilder: (_, i) {
                            final p = products[i];
                            return ListTile(
                              title: Text(p['product_name']?.toString() ?? 'Unknown', style: const TextStyle(color: Colors.white)),
                              subtitle: Text('Stock: ${p['current_stock'] ?? 0}', style: const TextStyle(color: Colors.white38)),
                              onTap: () => Navigator.pop(dCtx, p),
                            );
                          },
                        ),
                ),
              ),
            );
            if (selected == null || !ctx.mounted) return;

            final qtyC = TextEditingController(text: '1');
            final costC = TextEditingController(text: (selected['price'] ?? 0).toString());
            final add = await showDialog<bool>(
              context: ctx,
              builder: (dCtx) => AlertDialog(
                backgroundColor: _card,
                title: Text(selected['product_name']?.toString() ?? 'Item', style: const TextStyle(color: Colors.white)),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  _field(qtyC, 'Quantity', numeric: true),
                  const SizedBox(height: 12),
                  _field(costC, 'Unit Cost (₹)', numeric: true),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
                  TextButton(onPressed: () => Navigator.pop(dCtx, true), child: const Text('Add')),
                ],
              ),
            );
            final qty = int.tryParse(qtyC.text.trim()) ?? 0;
            if (add == true && qty > 0) {
              setModalState(() {
                orderItems.add({
                  'product_id': selected['id'],
                  'product_name': selected['product_name'],
                  'quantity': qty,
                  'unit_cost': double.tryParse(costC.text.trim()) ?? 0.0,
                });
              });
            }
          }

          final total = orderItems.fold<double>(
            0.0,
            (sum, it) => sum + ((it['quantity'] as int) * (it['unit_cost'] as num).toDouble()),
          );

          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('New Purchase Order', style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  _field(supplierC, 'Supplier Name'),
                  const SizedBox(height: 12),
                  _field(notesC, 'Notes (optional)'),
                  const SizedBox(height: 16),
                  Text('Items (at least one required)', style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  ...orderItems.asMap().entries.map((e) {
                    final i = e.key;
                    final it = e.value;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
                      child: Row(children: [
                        Expanded(child: Text('${it['product_name']}', style: const TextStyle(color: Colors.white))),
                        Text('${it['quantity']} × ₹${it['unit_cost']}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                          onPressed: () => setModalState(() => orderItems.removeAt(i)),
                        ),
                      ]),
                    );
                  }),
                  OutlinedButton.icon(
                    onPressed: pickProduct,
                    icon: const Icon(Icons.add, color: Colors.indigoAccent),
                    label: const Text('Add Item', style: TextStyle(color: Colors.indigoAccent)),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.indigoAccent)),
                  ),
                  const SizedBox(height: 12),
                  Text('Estimated Total: ₹${total.toStringAsFixed(2)}',
                      style: GoogleFonts.poppins(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final supplierName = supplierC.text.trim();
                        if (supplierName.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Supplier name is required')));
                          return;
                        }
                        if (orderItems.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Add at least one item')));
                          return;
                        }
                        final payload = {
                          'supplier_name': supplierName,
                          'items': orderItems,
                          if (notesC.text.trim().isNotEmpty) 'notes': notesC.text.trim(),
                        };
                        if (ctx.mounted) Navigator.pop(ctx);
                        await _createPurchaseOrder(payload);
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.indigoAccent, padding: const EdgeInsets.symmetric(vertical: 14)),
                      child: const Text('Create PO', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, {bool numeric = false}) {
    return TextField(
      controller: c,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: Colors.white10,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _ink,
        surfaceTintColor: _bg,
        elevation: 0,
        title: Text(
          'Purchase Orders',
          style: GoogleFonts.poppins(color: _ink, fontSize: 21, fontWeight: FontWeight.w800),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Create purchase order',
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 5,
        onPressed: _showCreatePO,
        child: const Icon(Icons.add_rounded),
      ),
      // Keep product search available immediately even when purchase orders
      // are still loading or the shop has no saved orders yet.
      body: RefreshIndicator(
              onRefresh: _refreshAll,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  _buildPurchaseShoppingChat(),
                  _buildReorderSuggestions(),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(color: const Color(0xFFEDEAFF), borderRadius: BorderRadius.circular(13)),
                        child: const Icon(Icons.receipt_long_rounded, color: _primary),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Your purchase orders', style: GoogleFonts.poppins(color: _ink, fontWeight: FontWeight.w800, fontSize: 17)),
                            Text('Track supplier orders and delivery status', style: GoogleFonts.poppins(color: _muted, fontSize: 11)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (_loading && _orders.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: _border),
                      ),
                      child: const Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _primary),
                          ),
                          SizedBox(width: 11),
                          Expanded(
                            child: Text(
                              'Loading saved purchase orders…',
                              style: TextStyle(color: _muted, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_orders.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 18),
                      decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: _border)),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Container(
                          width: 65,
                          height: 65,
                          decoration: BoxDecoration(color: const Color(0xFFF3F5FC), borderRadius: BorderRadius.circular(20)),
                          child: const Icon(Icons.receipt_long_rounded, color: Color(0xFF8A96B2), size: 32),
                        ),
                        const SizedBox(height: 12),
                        Text('No purchase orders yet', style: GoogleFonts.poppins(color: _ink, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(
                          'Create a draft when you are ready to order from a supplier.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(color: _muted, fontSize: 11, height: 1.5),
                        ),
                      ]),
                    )
                  else
                    ..._orders.asMap().entries.map((entry) => _buildOrderCard(entry.value, entry.key)),
                ],
              ),
            ),
    );
  }
}