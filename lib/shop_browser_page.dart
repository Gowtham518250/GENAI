
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:convert';
import 'api_client.dart';
import 'online_store_service.dart';
import 'checkout_page.dart';

class ShopBrowserPage extends StatefulWidget {
  const ShopBrowserPage({super.key});
  @override
  State<ShopBrowserPage> createState() => _ShopBrowserPageState();
}

enum _MarketplaceMode { all, shops, products, ai }

class _ShopBrowserPageState extends State<ShopBrowserPage> {
  final _searchController = TextEditingController();
  bool _loading = true;
  bool _searching = false;
  List<Map<String, dynamic>> _shops = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _ai = [];
  _MarketplaceMode _mode = _MarketplaceMode.all;
  String _aiMessage = '';

  @override
  void initState() {
    super.initState();
    _fetchShops();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchShops() async {
    setState(() => _loading = true);
    try {
      final res = await ApiClient.getJson('/store/shops/nearby?limit=50');
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body);
        final raw = d is List ? d : (d['shops'] ?? []);
        if (mounted) {
          setState(() {
            _shops = (raw as List)
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
          });
        }
      }
    } catch (e) {
      debugPrint('Marketplace fetch error: ' + e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _products = [];
        _ai = [];
        _aiMessage = '';
      });
      await _fetchShops();
      return;
    }

    setState(() => _searching = true);
    try {
      if (_mode == _MarketplaceMode.ai) {
        final data = await OnlineStoreService.aiRecommend(query: query);
        if (!mounted) return;
        setState(() {
          _shops = [];
          _products = [];
          _ai = (data['recommendations'] as List? ?? [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          _aiMessage = data['response']?.toString() ?? '';
        });
      } else {
        final mode = _mode == _MarketplaceMode.shops
            ? 'shops'
            : _mode == _MarketplaceMode.products
                ? 'products'
                : 'all';
        final data = await OnlineStoreService.marketplaceSearch(
          query: query,
          mode: mode,
        );
        if (!mounted) return;
        setState(() {
          _shops = (data['shops'] as List? ?? [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          _products = (data['products'] as List? ?? [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          _ai = [];
          _aiMessage = '';
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: ' + e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _openShop(Map<String, dynamic> data) {
    final id = data['shop_id']?.toString() ?? '';
    if (id.isEmpty) return;
    final name = data['shop_name']?.toString() ?? 'Shop';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ShopProductsPage(shopId: id, shopName: name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _loading || _searching;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          'Retail Marketplace',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: busy ? null : _fetchShops,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchShops,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _hero()),
            SliverToBoxAdapter(child: _searchBar()),
            if (_aiMessage.isNotEmpty)
              SliverToBoxAdapter(child: _aiBanner()),
            if (busy)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_searchController.text.trim().isNotEmpty &&
                _mode == _MarketplaceMode.ai)
              ..._aiResults()
            else if (_searchController.text.trim().isNotEmpty)
              ..._searchResults()
            else
              ..._shopGrid(),
          ],
        ),
      ),
    );
  }

  Widget _hero() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF312E81), Color(0xFF7C3AED)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4F46E5).withValues(alpha: 0.22),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'YOUR LOCAL MARKETPLACE',
            style: GoogleFonts.poppins(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Find shops. Compare prices. Order.',
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 23,
              height: 1.12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Only shops with Online Shopping enabled appear in this marketplace.',
            style: GoogleFonts.poppins(
              color: Colors.white70,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _runSearch(),
              decoration: InputDecoration(
                border: InputBorder.none,
                prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF4F46E5)),
                hintText: 'Search shop name or product name',
                hintStyle: GoogleFonts.poppins(color: Colors.grey.shade500, fontSize: 12),
                suffixIcon: IconButton(
                  onPressed: _searching ? null : _runSearch,
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 17),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip('All', _MarketplaceMode.all),
                _chip('Shops', _MarketplaceMode.shops),
                _chip('Products', _MarketplaceMode.products),
                _chip('AI advice', _MarketplaceMode.ai),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, _MarketplaceMode value) {
    final selected = _mode == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) {
          setState(() => _mode = value);
          if (_searchController.text.trim().isNotEmpty) _runSearch();
        },
        selectedColor: const Color(0xFF4F46E5),
        backgroundColor: Colors.white,
        labelStyle: GoogleFonts.poppins(
          color: selected ? Colors.white : const Color(0xFF374151),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
    );
  }

  List<Widget> _shopGrid() {
    if (_shops.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _empty('No online shops are available yet.'),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(child: _title('Online shops')),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.86,
          ),
          itemCount: _shops.length,
          itemBuilder: (_, i) => _shopCard(_shops[i]),
        ),
      ),
    ];
  }

  List<Widget> _searchResults() {
    final widgets = <Widget>[];
    if (_shops.isNotEmpty) {
      widgets.add(SliverToBoxAdapter(child: _title('Shops')));
      widgets.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          sliver: SliverList.separated(
            itemCount: _shops.length,
            itemBuilder: (_, i) => _shopResult(_shops[i]),
            separatorBuilder: (_, __) => const SizedBox(height: 10),
          ),
        ),
      );
    }
    if (_products.isNotEmpty) {
      widgets.add(SliverToBoxAdapter(child: _title('Products across shops')));
      widgets.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
          sliver: SliverList.separated(
            itemCount: _products.length,
            itemBuilder: (_, i) => _productResult(_products[i]),
            separatorBuilder: (_, __) => const SizedBox(height: 10),
          ),
        ),
      );
    }
    if (_shops.isEmpty && _products.isEmpty) {
      widgets.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: _empty('Nothing matched. Search another shop or product.'),
        ),
      );
    }
    return widgets;
  }

  List<Widget> _aiResults() {
    if (_ai.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _empty('No matching product was found in enabled shops.'),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(child: _title('AI recommendations')),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        sliver: SliverList.separated(
          itemCount: _ai.length,
          itemBuilder: (_, i) => _aiCard(_ai[i], i),
          separatorBuilder: (_, __) => const SizedBox(height: 10),
        ),
      ),
    ];
  }

  Widget _aiBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2FF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC7D2FE)),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome_rounded, color: Color(0xFF4F46E5)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _aiMessage,
              style: GoogleFonts.poppins(
                color: const Color(0xFF3730A3),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _title(String value) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
      child: Text(
        value,
        style: GoogleFonts.poppins(
          color: const Color(0xFF111827),
          fontSize: 17,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _shopCard(Map<String, dynamic> shop) {
    return InkWell(
      onTap: () => _openShop(shop),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 25,
              backgroundColor: const Color(0xFFEEF2FF),
              child: const Icon(Icons.storefront_rounded, color: Color(0xFF4F46E5)),
            ),
            const SizedBox(height: 11),
            Text(
              shop['shop_name']?.toString() ?? 'Shop',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(fontWeight: FontWeight.w800, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              shop['city']?.toString().isNotEmpty == true
                  ? shop['city'].toString()
                  : 'Online shop',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(color: Colors.grey.shade600, fontSize: 11),
            ),
            const Spacer(),
            _ratingRow(shop),
            const SizedBox(height: 8),
            Text(
              'Shop now →',
              style: GoogleFonts.poppins(
                color: const Color(0xFF059669),
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shopResult(Map<String, dynamic> shop) {
    return InkWell(
      onTap: () => _openShop(shop),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xFFEEF2FF),
              child: const Icon(Icons.storefront_rounded, color: Color(0xFF4F46E5)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shop['shop_name']?.toString() ?? 'Shop',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    shop['address']?.toString().isNotEmpty == true
                        ? shop['address'].toString()
                        : 'Online shopping enabled',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(color: Colors.grey.shade600, fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  _ratingRow(shop),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF4F46E5)),
          ],
        ),
      ),
    );
  }

  Widget _productResult(Map<String, dynamic> product) {
    return InkWell(
      onTap: () => _openShop(product),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.inventory_2_rounded, color: Color(0xFF4F46E5)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product['product_name']?.toString() ?? 'Product',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    product['shop_name']?.toString() ?? 'Shop',
                    style: GoogleFonts.poppins(
                      color: const Color(0xFF4F46E5),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _ratingRow(product),
                ],
              ),
            ),
            Text(
              '₹' + ((double.tryParse(product['price']?.toString() ?? '0') ?? 0).toStringAsFixed(2)),
              style: GoogleFonts.poppins(
                color: const Color(0xFF059669),
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(width: 5),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF4F46E5)),
          ],
        ),
      ),
    );
  }

  Widget _aiCard(Map<String, dynamic> item, int index) {
    return InkWell(
      onTap: () => _openShop(item),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE0E7FF)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xFFEEF2FF),
              child: Text(
                (index + 1).toString(),
                style: GoogleFonts.poppins(
                  color: const Color(0xFF4F46E5),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['product_name']?.toString() ?? 'Product',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    item['shop_name']?.toString() ?? 'Shop',
                    style: GoogleFonts.poppins(color: Colors.grey.shade600, fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  _ratingRow(item),
                ],
              ),
            ),
            Text(
              '₹' + ((double.tryParse(item['price']?.toString() ?? '0') ?? 0).toStringAsFixed(2)),
              style: GoogleFonts.poppins(
                color: const Color(0xFF059669),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ratingRow(Map<String, dynamic> data) {
    final rating = double.tryParse(data['rating']?.toString() ?? '0') ?? 0;
    final count = int.tryParse(data['rating_count']?.toString() ?? '0') ?? 0;
    return Row(
      children: [
        const Icon(Icons.star_rounded, color: Color(0xFFF59E0B), size: 15),
        const SizedBox(width: 3),
        Text(
          count == 0 ? 'New' : rating.toStringAsFixed(1) + ' • ' + count.toString(),
          style: GoogleFonts.poppins(
            color: Colors.grey.shade700,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _empty(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, size: 58, color: Color(0xFFCBD5E1)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

class ShopProductsPage extends StatefulWidget {
  final String shopId;
  final String shopName;
  const ShopProductsPage({super.key, required this.shopId, required this.shopName});
  @override
  State<ShopProductsPage> createState() => _ShopProductsPageState();
}

class _ShopProductsPageState extends State<ShopProductsPage> {
  bool _loading = true;
  List<dynamic> _products = [];
  final Map<int, int> _cart = {};

  @override
  void initState() {
    super.initState();
    _fetchProducts();
  }

  Future<void> _fetchProducts() async {
    try {
      final res = await ApiClient.getJson('/store/shops/${widget.shopId}/products');
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body);
        setState(() => _products = d is List ? d : (d['products'] ?? []));
      }
    } catch (e) {
      debugPrint('Products fetch error: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  int get _cartCount => _cart.values.fold(0, (s, v) => s + v);

  void _addToCart(int index) {
    setState(() => _cart[index] = (_cart[index] ?? 0) + 1);
  }

  void _goToCheckout() {
    final items = _cart.entries.map((e) {
      final p = _products[e.key];
      return {'product_id': p['id'], 'product_name': p['product_name'], 'quantity': e.value, 'price': p['unit_price'] ?? p['price'] ?? 0};
    }).toList();
    Navigator.push(context, MaterialPageRoute(builder: (_) => CheckoutPage(cartItems: items, shopId: widget.shopId)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(backgroundColor: Colors.indigo, title: Text(widget.shopName, style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold))),
      floatingActionButton: _cartCount > 0
          ? FloatingActionButton.extended(
              onPressed: _goToCheckout,
              backgroundColor: Colors.indigo,
              icon: const Icon(Icons.shopping_cart),
              label: Text('Cart ($_cartCount)', style: const TextStyle(fontWeight: FontWeight.bold)),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.indigo))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _products.length,
              itemBuilder: (ctx, i) {
                final p = _products[i];
                final inCart = _cart[i] ?? 0;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)]),
                  child: Row(children: [
                    CircleAvatar(backgroundColor: Colors.indigo.shade50, child: const Icon(Icons.inventory_2, color: Colors.indigo, size: 20)),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p['product_name']?.toString() ?? '', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                      Text('Rs ${p['unit_price'] ?? p['price'] ?? 0}', style: GoogleFonts.poppins(color: Colors.indigo, fontWeight: FontWeight.bold)),
                    ])),
                    if (inCart > 0) Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(8)),
                      child: Text('x$inCart', style: GoogleFonts.poppins(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.add_circle, color: Colors.indigo),
                      onPressed: () => _addToCart(i),
                    ),
                  ]),
                );
              },
            ),
    );
  }
}