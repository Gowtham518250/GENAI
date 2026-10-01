import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../visual_widgets.dart';

class CustomerAiShoppingPage extends StatefulWidget {
  const CustomerAiShoppingPage({super.key});

  @override
  State<CustomerAiShoppingPage> createState() => _CustomerAiShoppingPageState();
}

class _CustomerAiShoppingPageState extends State<CustomerAiShoppingPage> {
  final _controller = TextEditingController();
  bool _loading = false;
  String _message = '';
  String _error = '';
  String _intent = '';
  String _productQuery = '';
  String _shopHint = '';
  List<Map<String, dynamic>> _results = [];
  final List<String> _recent = [];

  static const examples = [
    'low price rice',
    'best rated atta',
    'milk under ₹80',
    'low price rice at Ganesh Store',
    'best rated shampoo under ₹500',
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _ask([String? preset]) async {
    final query = (preset ?? _controller.text).trim();
    if (query.length < 2 || _loading) return;

    _controller.text = query;
    FocusScope.of(context).unfocus();

    setState(() {
      _loading = true;
      _error = '';
      _message = '';
      _results = [];
      _intent = '';
      _productQuery = '';
      _shopHint = '';
    });

    try {
      final response = await ApiClient.getJson(
        '/store/customer-ai?q=${Uri.encodeQueryComponent(query)}&limit=10',
      );
      final body = response.statusCode == 200 ? jsonDecode(response.body) : null;
      final data = body is Map
          ? Map<String, dynamic>.from(body)
          : <String, dynamic>{};

      if (response.statusCode != 200) {
        throw Exception(
          data['detail']?.toString() ?? 'Shopping AI is temporarily unavailable.',
        );
      }

      final results = data['recommendations'] is List
          ? List<Map<String, dynamic>>.from(
              (data['recommendations'] as List)
                  .whereType<Map>()
                  .map(Map<String, dynamic>.from),
            )
          : <Map<String, dynamic>>[];

      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = data['message']?.toString() ?? '';
        _intent = data['intent_label']?.toString() ?? '';
        _productQuery = data['product_query']?.toString() ?? query;
        _shopHint = data['shop_hint']?.toString() ?? '';
        _results = results;
      });

      if (data['available'] == true && !_recent.contains(query)) {
        setState(() {
          _recent.insert(0, query);
          if (_recent.length > 6) _recent.removeLast();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _openShop(String shopId) {
    if (shopId.isEmpty) return;
    Navigator.pushNamed(context, '/customer-home', arguments: shopId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      appBar: AppBar(
        title: const Text('AI Shopping', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Marketplace',
            onPressed: () => Navigator.pushReplacementNamed(context, '/customer-marketplace'),
            icon: const Icon(Icons.storefront_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0F172A), Color(0xFF312E81), Color(0xFF4F46E5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(28),
              boxShadow: const [
                BoxShadow(color: Color(0x241E1B4B), blurRadius: 26, offset: Offset(0, 12)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.auto_awesome_rounded, color: Colors.amberAccent),
                    ),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Retail Mind AI', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18)),
                          SizedBox(height: 2),
                          Text('Real shop + product data', style: TextStyle(color: Colors.white60, fontSize: 11)),
                        ],
                      ),
                    ),
                    _tag('LIVE'),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  'Ask naturally. Compare real shops.',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 25, height: 1.05),
                ),
                const SizedBox(height: 7),
                const Text(
                  'Ask for low price, best rating, a budget, or a specific shop. '
                  'Products are returned only when they exist in an online-enabled shop.',
                  style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.45),
                ),
                const SizedBox(height: 17),
                TextField(
                  controller: _controller,
                  onSubmitted: (_) => _ask(),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'e.g. low price rice at Ganesh Store',
                    hintStyle: const TextStyle(color: Colors.white54),
                    prefixIcon: const Icon(Icons.search_rounded, color: Colors.white70),
                    suffixIcon: _loading
                        ? const Padding(
                            padding: EdgeInsets.all(13),
                            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                          )
                        : IconButton(
                            onPressed: _ask,
                            icon: const Icon(Icons.arrow_forward_rounded, color: Colors.white),
                          ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.08),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.13)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.13)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final example in examples)
                      ActionChip(
                        label: Text(example, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w700)),
                        backgroundColor: Colors.white.withValues(alpha: 0.07),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.09)),
                        onPressed: () => _ask(example),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 15),
          if (_recent.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: Text('Recent', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  ),
                  for (final item in _recent)
                    InputChip(
                      label: Text(item, style: const TextStyle(fontSize: 10)),
                      avatar: const Icon(Icons.history_rounded, size: 14),
                      onPressed: () => _ask(item),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 15),
          if (_error.isNotEmpty)
            _stateCard(Icons.cloud_off_rounded, 'Shopping AI unavailable', _error, const Color(0xFFDC2626))
          else if (!_loading && _message.isNotEmpty && _results.isEmpty)
            _stateCard(Icons.search_off_rounded, 'Product unavailable', _message, const Color(0xFFB45309)),
          if (_message.isNotEmpty && _results.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFFEEF2FF), Color(0xFFF5F3FF)]),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFC7D2FE)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.psychology_alt_rounded, color: AppColors.brand),
                      const SizedBox(width: 8),
                      const Text('AI answer', style: TextStyle(color: AppColors.brand, fontWeight: FontWeight.w900)),
                      const Spacer(),
                      if (_intent.isNotEmpty) _lightTag(_intent, AppColors.brand),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_message, style: const TextStyle(color: Color(0xFF1E1B4B), fontWeight: FontWeight.w700, height: 1.45)),
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      if (_productQuery.isNotEmpty) _lightTag(_productQuery, const Color(0xFF475569)),
                      if (_shopHint.isNotEmpty) _lightTag(_shopHint, const Color(0xFF7C3AED)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 15),
            Text(
              '${_results.length} verified product option${_results.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < _results.length; i++) _resultCard(_results[i], i),
          ],
          if (!_loading && _message.isEmpty && _error.isEmpty && _results.isEmpty)
            _stateCard(
              Icons.tips_and_updates_outlined,
              'Ask one simple question',
              'Try low price rice, best rated atta, milk under ₹80, or low price rice at a shop.',
              AppColors.brand,
            ),
        ],
      ),
    );
  }

  Widget _resultCard(Map<String, dynamic> item, int index) {
    final product = item['product_name']?.toString() ?? 'Product';
    final shop = item['shop_name']?.toString() ?? 'Shop';
    final shopId = item['shop_id']?.toString() ?? '';
    final price = double.tryParse(item['price']?.toString() ?? '') ?? 0;
    final stock = double.tryParse(item['stock_available']?.toString() ?? '') ?? 0;
    final rating = double.tryParse(item['rating']?.toString() ?? '') ?? 0;
    final reviews = int.tryParse(item['rating_count']?.toString() ?? '') ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [BoxShadow(color: Color(0x0A0F172A), blurRadius: 20, offset: Offset(0, 8))],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.brandLight,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Text('${index + 1}', style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.brand, fontSize: 17)),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 3),
                    Text(shop, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.brand, fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              Text('₹${price.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.brand, fontSize: 18, fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _metric(Icons.star_rounded, rating > 0 ? '${rating.toStringAsFixed(1)} rating' : 'New shop', const Color(0xFFF59E0B)),
              _metric(Icons.rate_review_outlined, reviews > 0 ? '$reviews ratings' : 'No ratings yet', const Color(0xFF64748B)),
              _metric(Icons.inventory_2_outlined, stock > 0 ? '${stock.toStringAsFixed(0)} in stock' : 'Unavailable', stock > 0 ? const Color(0xFF059669) : const Color(0xFFDC2626)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text('Open the shop to view details and order', style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500))),
              FilledButton.icon(
                onPressed: () => _openShop(shopId),
                icon: const Icon(Icons.storefront_rounded, size: 16),
                label: const Text('View shop'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _lightTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800)),
    );
  }

  Widget _tag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.w900)),
    );
  }

  Widget _stateCard(IconData icon, String title, String message, Color color) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(17)),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: 9),
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.45)),
        ],
      ),
    );
  }
}
