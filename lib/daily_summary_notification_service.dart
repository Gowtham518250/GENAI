import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'analytics_engine.dart';
import 'local_storage_service.dart';

/// Schedules a daily 9 PM income summary notification in Telugu + English.
/// Uses flutter_local_notifications (already in pubspec: ^17.1.2).
/// No extra packages needed — uses a repeating daily timer approach.
class DailySummaryNotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId   = 'daily_summary_channel';
  static const _channelName = '\u0c30ోజూ స్టేట్మెంట్ | Daily Summary';
  static const _notifId     = 9900;
  static const _prefKey     = 'daily_summary_last_scheduled_date';

  static bool _channelCreated = false;

  /// Call from DashboardPage.initState() once per app session.
  /// Schedules the 9 PM notification for today (or tomorrow if already past 9 PM).
  static Future<void> scheduleTodayNotification({
    required double todayRevenue,
    required int todayBills,
    required String topProduct,
  }) async {
    try {
      await _ensureChannel();

      final prefs  = await SharedPreferences.getInstance();
      final today  = DateTime.now();
      final todayStr = '${today.year}-${today.month}-${today.day}';

      // Only schedule once per day
      final lastScheduled = prefs.getString(_prefKey) ?? '';
      if (lastScheduled == todayStr) return;
      await prefs.setString(_prefKey, todayStr);

      final ninepm = DateTime(today.year, today.month, today.day, 21, 0, 0);
      final target = ninepm.isBefore(today)
          ? ninepm.add(const Duration(days: 1))
          : ninepm;
      final delay = target.difference(today);

      if (kDebugMode) {
        debugPrint('\u2705 Daily summary notification scheduled in \${delay.inMinutes} min');
      }

      // Do not capture dashboard values at scheduling time. The shop can
      // create more bills after the dashboard opens, so the 9 PM report is
      // recalculated from the latest canonical local sales when it fires.
      Timer(delay, () async {
        try {
          final latestSales = await LocalStorageService.loadSales();
          final engine = AnalyticsEngine();
          engine.recalculateAnalytics(latestSales, 0);

          final revenue = engine.todaySalesValue;
          final bills = engine.todayTransactionsValue;
          final bestProduct = engine.todayTopProduct;

          final amountStr = _formatAmount(revenue);
          final teluguBody =
              '\u0c28\u0c47\u0c21\u0c41 \u0c38\u0c02\u0c2a\u0c3e\u0c26\u0c28: \u20b9$amountStr | $bills \u0c2c\u0c3f\u0c32\u0c4d\u0c32\u0c41'
              '\${bestProduct.isNotEmpty ? " | Best: $bestProduct" : ""}';

          await _showNow(
            title: '\u0c2a\u0c4d\u0c30\u0c24\u0c3f\u0c30\u0c4b\u0c1c\u0c42 \u0c30\u0c3f\u0c2a\u0c4b\u0c30\u0c4d\u0c1f\u0c4d \ud83d\udcca | Daily Report',
            body: teluguBody,
          );

          if (kDebugMode) {
            debugPrint(
              '\u2705 Daily report sent from canonical local sales: \u20b9$revenue | $bills bills',
            );
          }
        } catch (e) {
          if (kDebugMode) debugPrint('Daily summary notify error: $e');
        }
      });
    } catch (e) {
      if (kDebugMode) debugPrint('DailySummaryNotificationService error: $e');
    }
  }

  static Future<void> _showNow({required String title, required String body}) async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Daily shop income summary at 9 PM',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(''),
      icon: '@mipmap/ic_launcher',
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(_notifId, title, body, details);
  }

  static Future<void> _ensureChannel() async {
    if (_channelCreated) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(initSettings);

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      const channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Daily shop income summary at 9 PM',
        importance: Importance.high,
      );
      await androidPlugin.createNotificationChannel(channel);
    }
    _channelCreated = true;
  }

  static String _formatAmount(double v) {
    if (v >= 100000) return '${(v / 100000).toStringAsFixed(1)}L';
    if (v >= 1000)   return '${(v / 1000).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }
}
