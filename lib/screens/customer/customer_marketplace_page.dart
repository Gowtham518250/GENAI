import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../visual_widgets.dart';

class CustomerMarketplacePage extends StatefulWidget {
  const CustomerMarketplacePage({super.key});

  @override
  State<CustomerMarketplacePage> createState() => _CustomerMarketplacePageState();
}

class _CustomerMarketplacePageState extends State<CustomerMarketplacePage> {
  final _searchController = TextEditingController();
  final _aiController = TextEditingController();
  Timer? _debounce;

  String _mode = 'all';
  String _query = '';
  bool _loading = false;
  bool _aiLoading = false;
  String _error = '';
  String _aiResponse = '';
  List<Map<String, dynamic>> _shops = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _recommendations = [];

  @override
  void initState() {
    super.initState();
    _runSearch('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _aiController.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String value) async {
    final query = value.trim();
    if (!mounted) return;
    setState(() {
      _query = query;
      _loading = true;
      _error = '';
    });

    try {
      final uri = '/store/marketplace/search?q=${Uri.encodeQueryComponent(query)}'
          '&mode=$_mode&limit=40';
      final response = await ApiClient.getJson(uri);
      if (response.statusCode != 200) {
        throw Exception('Marketplace is temporarily unavailable.');
      }

      final data = jsonDecode(response.body);
      final shops = data is Map && data['shops'] is List
          ? List<Map<String, dynamic>>.from(
              (data['shops'] as List).whereType<Map>().map(Map<String, dynamic>.from),
            )
          : <Map<String, dynamic>>[];
      final products = data is Map && data['products'] is List
          ? List<Map<String, dynamic>>.from(
              (data['products'] as List).whereType<Map>().map(Map<String, dynamic>.from),
            )
          : <Map<String, dynamic>>[];

      if (!mounted) return;
      setState(() {
        _shops = shops;
        _products = products;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _runSearch(value));
  }

  Future<void> _askAi() async {
    final query = _aiController.text.trim();
    if (query.length < 2) return;

    setState(() {
      _aiLoading = true;
      _aiResponse = '';
      _recommendations = [];
    });

    try {
      final response = await ApiClient.getJson(
        '/store/ai/recommend?q=${Uri.encodeQueryComponent(query)}&limit=10',
      );
      final raw = response.statusCode == 200 ? jsonDecode(response.body) : null;
      final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

      if (response.statusCode != 200) {
        throw Exception(data['detail']?.toString() ?? 'Shopping assistant is unavailable.');
      }

      if (!mounted) return;
      setState(() {
        _aiResponse = data['response']?.toString() ?? 'Here are the matching shops.';
        _recommendations = data['recommendations'] is List
            ? List<Map<String, dynamic>>.from(
                (data['recommendations'] as List).whereType<Map>().map(Map<String, dynamic>.from),
              )
            : [];
        _aiLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiLoading = false;
        _aiResponse = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _openShop(String shopId) {
    if (shopId.isEmpty) return;
    Navigator.pushNamed(context, '/customer-home', arguments: shopId);
  }

  Widget _rating(Map<String, dynamic> item) {
    final rating = double.tryParse(item['rating']?.toString() ?? '') ?? 0;
    final count = int.tryParse(item['rating_count']?.toString() ?? '') ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star_rounded, size: 16, color: Color(0xFFF59E0B)),
        const SizedBox(width: 3),
        Text(
          rating > 0 ? rating.toStringAsFixed(1) : 'New',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        if (count > 0) ...[
          const SizedBox(width: 3),
          Text('($count)', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ],
      ],
    );
  }

  Widget _shopCard(Map<String, dynamic> shop) {
    final id = shop['shop_id']?.toString() ?? '';
    final name = shop['shop_name']?.toString() ?? 'Shop';
    final address = shop['address']?.toString() ?? '';
    final tagline = shop['tagline']?.toString() ?? '';

    return InkWell(
      onTap: () => _openShop(id),
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: const [
            BoxShadow(color: Color(0x0D0F172A), blurRadius: 20, offset: Offset(0, 8)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: AppColors.brandLight,
                  child: const Icon(Icons.storefront_rounded, color: AppColors.brand),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.black45),
              ],
            ),
            if (tagline.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(tagline, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey.shade600)),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                _rating(shop),
                const Spacer(),
                if (address.isNotEmpty)
                  Flexible(
                    child: Text(
                      address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                'Online shopping enabled',
                style: TextStyle(color: Color(0xFF047857), fontSize: 11, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _productCard(Map<String, dynamic> product) {
    final shopId = product['shop_id']?.toString() ?? '';
    final name = product['product_name']?.toString() ?? 'Product';
    final shop = product['shop_name']?.toString() ?? 'Shop';
    final price = double.tryParse(product['price']?.toString() ?? '0') ?? 0;
    final stock = int.tryParse(product['stock_available']?.toString() ?? '0') ?? 0;

    return InkWell(
      onTap: () => _openShop(shopId),
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: AppColors.brandLight,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(Icons.inventory_2_outlined, color: AppColors.brand),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(shop, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                  const SizedBox(height: 7),
                  Row(children: [
                    _rating(product),
                    const Spacer(),
                    Text('₹${price.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.brand)),
                  ]),
                  const SizedBox(height: 5),
                  Text('${stock} in stock', style: TextStyle(fontSize: 11, color: stock > 0 ? Colors.green.shade700 : Colors.red.shade700)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recommendationCard(Map<String, dynamic> item, int index) {
    final shopId = item['shop_id']?.toString() ?? '';
    final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
    final name = item['product_name']?.toString() ?? 'Product';
    final shop = item['shop_name']?.toString() ?? 'Shop';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.brandLight,
            child: Text('${index + 1}', style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.brand)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(shop, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('₹${price.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.brand)),
              _rating(item),
              TextButton(onPressed: () => _openShop(shopId), child: const Text('Open shop')),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: AppBar(
        title: const Text('RetailShop Marketplace', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'AI Shopping',
            onPressed: () => Navigator.pushNamed(context, '/customer-ai-shopping'),
            icon: const Icon(Icons.auto_awesome_rounded),
          ),
          IconButton(
            tooltip: 'My orders',
            onPressed: () => Navigator.pushNamed(context, '/order-tracking'),
            icon: const Icon(Icons.receipt_long_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _runSearch(_query),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 34),
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFEEF2FF), Color(0xFFE0F2FE)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Find the right shop or the right price.', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, height: 1.05)),
                  const SizedBox(height: 8),
                  Text(
                    'Search shop names to open their storefront, or search products to compare offers across every shop that enabled Online Shopping.',
                    style: TextStyle(color: Colors.blueGrey.shade700, height: 1.45),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: 'Search shops, products, brands…',
                      filled: true,
                      fillColor: Colors.white,
                      suffixIcon: _loading
                          ? const Padding(
                              padding: EdgeInsets.all(13),
                              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : null,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final option in const [
                        ('all', 'Everything'),
                        ('shops', 'Shops'),
                        ('products', 'Products'),
                      ])
                        ChoiceChip(
                          label: Text(option.$2),
                          selected: _mode == option.$1,
                          onSelected: (_) {
                            setState(() => _mode = option.$1);
                            _runSearch(_searchController.text);
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0F172A), Color(0xFF312E81)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [BoxShadow(color: Color(0x221E1B4B), blurRadius: 20, offset: Offset(0, 10))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.auto_awesome_rounded, color: Colors.amberAccent),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Shopping assistant', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(999)),
                      child: const Text('TOP 10', style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w800)),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  const Text('Ask for cheap, highly rated, budget or price-limited products. The assistant searches every online-enabled shop.', style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.45)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _aiController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'e.g. Find low price rice or best rated atta',
                      hintStyle: const TextStyle(color: Colors.white54),
                      prefixIcon: const Icon(Icons.psychology_alt_outlined, color: Colors.white70),
                      suffixIcon: IconButton(
                        onPressed: _aiLoading ? null : _askAi,
                        icon: _aiLoading
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.arrow_forward_rounded, color: Colors.white),
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.08),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12))),
                    ),
                    onSubmitted: (_) => _askAi(),
                  ),
                  if (_aiResponse.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(_aiResponse, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, height: 1.4)),
                  ],
                  if (_recommendations.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    ..._recommendations.asMap().entries.map((entry) => _recommendationCard(entry.value, entry.key)),
                  ],
                ],
              ),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFFED7AA)),
                ),
                child: Row(children: [
                  const Icon(Icons.wifi_off_rounded, color: Color(0xFFC2410C)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_error, style: const TextStyle(color: Color(0xFF9A3412))),
                  ),
                  TextButton(onPressed: () => _runSearch(_query), child: const Text('Retry')),
                ]),
              ),
            ],
            const SizedBox(height: 22),
            if (_shops.isNotEmpty) ...[
              Row(
                children: [
                  const Expanded(child: Text('Online shops', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900))),
                  Text('${_shops.length} found', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _shops.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: isWide ? 3 : 1,
                  childAspectRatio: isWide ? 1.55 : 2.05,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemBuilder: (_, i) => _shopCard(_shops[i]),
              ),
            ],
            if (_products.isNotEmpty) ...[
              const SizedBox(height: 28),
              const Text('Products across shops', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              ..._products.map(_productCard),
            ],
            if (!_loading && _error.isEmpty && _shops.isEmpty && _products.isEmpty) ...[
              const SizedBox(height: 50),
              const Center(
                child: Text(
                  'No online shops or products matched your search yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
