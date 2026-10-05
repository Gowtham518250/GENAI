import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../api_client.dart';
import '../../online_store_service.dart';
import '../../visual_widgets.dart';

class OnlineShoppingConfigPage extends StatefulWidget {
  const OnlineShoppingConfigPage({super.key});

  @override
  State<OnlineShoppingConfigPage> createState() => _OnlineShoppingConfigPageState();
}

class _OnlineShoppingConfigPageState extends State<OnlineShoppingConfigPage> {
  bool _isOnline = false;
  bool _isLoading = true;
  String _shopId = '';
  List<Map<String, dynamic>> _inventory = [];

  // Speech to text
  final stt.SpeechToText _speechToText = stt.SpeechToText();
  bool _isListening = false;
  String _lastWords = '';

  @override
  void initState() {
    super.initState();
    _loadShopData();
  }

  Future<void> _loadShopData() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('user_id') ?? 0;
    _shopId = userId.toString();

    if (_shopId == '0') {
      setState(() => _isLoading = false);
      return;
    }

    try {
      // Online Shopping Manager and this screen now read the same backend
      // source of truth instead of maintaining separate toggle states.
      final online = await OnlineStoreService.getOnlineSettings();
      if (mounted) {
        setState(() {
          _isOnline = online['is_online_store_enabled'] == true;
        });
      }

      final res = await ApiClient.getJson(
        '/api/inventory/products?shop_id=$_shopId&user_id=$_shopId',
      );
      if (res.statusCode == 200 && mounted) {
        final List data = json.decode(res.body);
        setState(() {
          _inventory = List<Map<String, dynamic>>.from(data);
        });
      }
    } catch (e) {
      debugPrint('Error loading shop data: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _toggleOnlineStatus(bool value) async {
    final previous = _isOnline;
    setState(() => _isOnline = value);

    try {
      double? latitude;
      double? longitude;

      if (value) {
        bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) throw Exception('Location services disabled.');

        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          throw Exception('Location permission is required to publish the shop.');
        }

        final pos = await Geolocator.getCurrentPosition();
        latitude = pos.latitude;
        longitude = pos.longitude;
      }

      final current = await OnlineStoreService.getOnlineSettings();
      final result = await OnlineStoreService.setOnlineSettings({
        'is_online_store_enabled': value,
        'online_setup_fee': current['online_setup_fee'] ?? 0,
        'min_order': current['min_order'] ?? 0,
        'delivery_fee': current['delivery_fee'] ?? 0,
        'offer_delivery': current['offer_delivery'] ?? true,
        'offer_pickup': current['offer_pickup'] ?? true,
        'accept_cod': current['accept_cod'] ?? true,
        'accept_online': current['accept_online'] ?? false,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
      });

      if (result['success'] != true) {
        throw Exception(result['error'] ?? 'Failed to update online-store status.');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              value
                  ? 'Shop is now Live & Visible to Customers!'
                  : 'Shop is now offline.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _isOnline = previous);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update online store: $e')),
        );
      }
    }
  }

  void _startListening() async {
    bool available = await _speechToText.initialize();
    if (available) {
      setState(() => _isListening = true);
      _speechToText.listen(
        onResult: (result) {
          setState(() {
            _lastWords = result.recognizedWords;
          });
          if (result.finalResult) {
            _processVoiceCommand(_lastWords);
          }
        },
      );
    }
  }

  void _stopListening() async {
    await _speechToText.stop();
    setState(() => _isListening = false);
  }

  void _processVoiceCommand(String command) {
    // Basic NLP mock for: "Add 10 apples for 50 rupees"
    String name = command;
    double price = 0.0;
    int stock = 1;

    final lower = command.toLowerCase();
    if (lower.contains('for')) {
      final parts = lower.split('for');
      name = parts[0].replaceAll(RegExp(r'[0-9]'), '').trim();
      final priceMatch = RegExp(r'\d+').firstMatch(parts[1]);
      if (priceMatch != null) price = double.parse(priceMatch.group(0)!);
      
      final qtyMatch = RegExp(r'\d+').firstMatch(parts[0]);
      if (qtyMatch != null) stock = int.parse(qtyMatch.group(0)!);
    }

    _showAddItemDialog(name: name, price: price, stock: stock);
  }

  void _showAddItemDialog({String name = '', double price = 0.0, int stock = 0, String imageUrl = ''}) {
    final nameCtrl = TextEditingController(text: name);
    final priceCtrl = TextEditingController(text: price > 0 ? price.toString() : '');
    final stockCtrl = TextEditingController(text: stock > 0 ? stock.toString() : '');
    final imageCtrl = TextEditingController(text: imageUrl);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Online Stock'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Item Name')),
              TextField(controller: priceCtrl, decoration: const InputDecoration(labelText: 'Price'), keyboardType: TextInputType.number),
              TextField(controller: stockCtrl, decoration: const InputDecoration(labelText: 'Stock Qty'), keyboardType: TextInputType.number),
              TextField(
                controller: imageCtrl,
                decoration: const InputDecoration(
                  labelText: 'Image URL (optional)',
                  hintText: 'https://...',
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () async {
                  final picker = ImagePicker();
                  final file = await picker.pickImage(source: ImageSource.gallery);
                  if (file != null && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Paste image URL above after uploading photo elsewhere.')),
                    );
                  }
                },
                icon: const Icon(Icons.photo_library),
                label: const Text('Pick from gallery'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final itemName = nameCtrl.text.trim();
              if (itemName.isEmpty) return;
              final newItem = {
                'product_name': itemName,
                'name': itemName,
                'price': double.tryParse(priceCtrl.text) ?? 0.0,
                'stock': int.tryParse(stockCtrl.text) ?? 0,
                'image_url': imageCtrl.text.trim(),
              };

              try {
                await ApiClient.postJson('/api/inventory/products', {
                  ...newItem,
                  'user_id': int.tryParse(_shopId) ?? 0,
                  'shop_id': _shopId,
                });
                
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Saved — visible to customers when in stock')),
                  );
                }
                _loadShopData();
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to save: $e')),
                  );
                }
              }
            },
            child: const Text('Save to Inventory'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Online Shopping Setup', style: TextStyle(color: Colors.black87)),
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black87),
        elevation: 1,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isListening ? _stopListening : _startListening,
        backgroundColor: _isListening ? Colors.red : AppColors.primary,
        icon: Icon(_isListening ? Icons.mic_off : Icons.mic),
        label: Text(_isListening ? 'Listening...' : 'Voice Add Stock'),
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: Colors.black))
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Enable Online Store', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            _isOnline ? 'Customers can see your shop on the map.' : 'Your shop is currently hidden.',
                            style: TextStyle(color: Colors.grey[600], fontSize: 13),
                          ),
                        ],
                      ),
                      Switch(
                        value: _isOnline,
                        onChanged: _toggleOnlineStatus,
                        activeColor: AppColors.primary,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Online Inventory', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle, color: AppColors.primary),
                    onPressed: _showAddItemDialog,
                  )
                ],
              ),
              const SizedBox(height: 8),
              if (_inventory.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24.0),
                  child: Center(child: Text('No items in online inventory. Add some using the Voice button!')),
                )
              else
                ..._inventory.map((item) {
                  final img = (item['image_url'] ?? item['imageUrl'] ?? '').toString();
                  final name = item['product_name'] ?? item['name'] ?? 'Unknown';
                  final stock = item['stock'] ?? item['quantity'] ?? 0;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: img.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(img, width: 48, height: 48, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const CircleAvatar(
                                        backgroundColor: AppColors.primary,
                                        child: Icon(Icons.image, color: Colors.white, size: 20),
                                      )),
                            )
                          : const CircleAvatar(
                              backgroundColor: AppColors.primary,
                              child: Icon(Icons.image, color: Colors.white),
                            ),
                      title: Text(name.toString()),
                      subtitle: Text(stock == 0 ? 'Out of stock (hidden online)' : 'Stock: $stock'),
                      trailing: Text(
                        'Rs ${item['price'] ?? 0}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                  );
                }),
            ],
          ),
    );
  }
}
