/// Feature 3: Festival Stock Predictor
/// Show "stock up" banner 7-14 days before Indian festivals

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';

class FestivalStockPredictorService {
  static const List<String> indianFestivals = [
    'Diwali', 'Holi', 'Eid', 'Pongal', 'Navratri', 
    'Durga Puja', 'Rakhi', 'Janmashtami', 'Ganesh Chaturthi'
  ];
  
  /// Get upcoming festival alerts from backend
  static Future<List<Map<String, dynamic>>> getUpcomingFestivalAlerts() async {
    try {
      final response = await ApiClient.getJson(ApiClient.todayInsightEndpoint);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final festivals = List<Map<String, dynamic>>.from(data['festivals'] ?? []);
        
        return festivals.where((f) {
          final daysUntil = f['days_until'] ?? 999;
          return daysUntil > 0 && daysUntil <= 14;
        }).toList();
      }
      return [];
    } catch (e) {
      print('Error fetching festival data: $e');
      return [];
    }
  }
  
  /// Get top products to stock for a festival
  static Future<List<Map<String, dynamic>>> getFestivalTopProducts(String festivalName) async {
    try {
      final response = await ApiClient.getJson('/api/festivals/top-products/$festivalName');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['top_5_products'] ?? []);
      }
      return [];
    } catch (e) {
      print('Error fetching festival products: $e');
      return [];
    }
  }
}


/// Feature 4: Chatbot Context Service
/// Inject shop data into chatbot for personalized responses


class ChatbotContextService {
  static Future<Map<String, String>> _localShopContext() async {
    final prefs = await SharedPreferences.getInstance();
    final shopName = (prefs.getString('shop_name') ??
            prefs.getString('shopName') ??
            prefs.getString('business_name') ??
            'your shop')
        .trim();
    final role = (prefs.getString('user_type') ??
            prefs.getString('role') ??
            'shop owner')
        .trim();
    return {
      'shop_name': shopName.isEmpty ? 'your shop' : shopName,
      'role': role.isEmpty ? 'shop owner' : role,
    };
  }

  /// Build the assistant context locally. No /api/chatbot endpoint is needed.
  static Future<String> getChatbotSystemPrompt() async {
    final context = await _localShopContext();
    return 'You are the Retail Mind assistant for ${context['shop_name']}. '
        'The signed-in user role is ${context['role']}. '
        'Help with sales, invoices, inventory, attendance, and shop operations. '
        'For live business figures, use the authenticated Retail Mind query service '
        'rather than guessing values.';
  }

  /// Build a personalized greeting using locally saved shop information.
  static Future<String> getPersonalizedGreeting() async {
    final context = await _localShopContext();
    return "Hello! I'm your Retail Mind assistant for ${context['shop_name']}. "
        'Ask a question about your sales, invoices, inventory, or shop operations.';
  }

  /// Send business questions through the available, authenticated ask-query API.
  /// The backend scopes the query to the authenticated owner's shop.
  static Future<String> sendMessageWithContext(String userMessage) async {
    final question = userMessage.trim();
    if (question.isEmpty) return 'Please enter a question.';

    try {
      final response = await ApiClient.postForm(
        ApiClient.askQueryEndpoint,
        {
          'query': question,
          'language_code': 'en',
        },
      );

      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (decoded is Map) {
          final answer = decoded['answer'] ?? decoded['message'];
          if (answer != null && answer.toString().trim().isNotEmpty) {
            return answer.toString();
          }
        }
        return 'The assistant returned an empty answer. Please try rephrasing your question.';
      }

      if (decoded is Map) {
        final detail = decoded['detail'] ?? decoded['message'] ?? decoded['error'];
        if (detail != null && detail.toString().trim().isNotEmpty) {
          return detail.toString();
        }
      }
      return 'The assistant service is temporarily unavailable (HTTP ${response.statusCode}).';
    } catch (error) {
      return 'Could not reach the assistant service. Check your connection and try again.';
    }
  }
}
