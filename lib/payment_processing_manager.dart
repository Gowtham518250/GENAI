import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'api_client.dart';
import 'local_storage_service.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';
import 'offline_payment_queue.dart';
import 'error_logger.dart';
import 'payment_detection_service.dart';
import 'payment_event.dart';

/// Payment Processing Manager - Orchestrates the complete payment flow with error handling,
/// offline support, and fallback options
class PaymentProcessingManager {
  static const String _tag = '💳 PAYMENT_MANAGER';
  
  final ErrorLogger _errorLogger = ErrorLogger();
  final OfflinePaymentQueue _offlineQueue = OfflinePaymentQueue();
  final Connectivity _connectivity = Connectivity();
  bool _isOnline = true;  // Initialize to true to prevent early offline triggers
  
  // Callbacks
  Function(PaymentEvent)? onPaymentDetected;
  Function(double, int)? onSyncProgress;  // (amount, count)
  Function()? onSyncComplete;
  
  PaymentProcessingManager() {
    _initializeConnectivity();
    _checkInitialConnection();
  }
  
  Future<void> _checkInitialConnection() async {
    final result = await _connectivity.checkConnectivity();
    _isOnline = result != ConnectivityResult.none;
    if (kDebugMode) print('$_tag Initial connection: ${_isOnline ? "ONLINE" : "OFFLINE"}');
  }
  
  void _initializeConnectivity() {
    _connectivity.onConnectivityChanged.listen((result) {
      _isOnline = result != ConnectivityResult.none;
      if (kDebugMode) print('$_tag Connection: ${_isOnline ? "ONLINE" : "OFFLINE"}');
      
      if (_isOnline) {
        _syncQueuedPayments();
      }
    });
  }
  
  /// Main payment detection handler - runs with full error handling
  Future<void> handlePaymentDetected(PaymentEvent payment) async {
    try {
      if (kDebugMode) print('$_tag Detected: ₹${payment.amount} from ${payment.detectionSource}');
      
      // Connectivity no longer decides persistence. The payment
      // operation is always written to the canonical outbox first; the
      // SyncEngine flushes immediately when a network is available.
      await _processPaymentOnline(payment);
      
      onPaymentDetected?.call(payment);
    } catch (e) {
      await _errorLogger.logPaymentError(
        detectionSource: payment.detectionSource,
        errorReason: 'Unhandled error in handlePaymentDetected',
        paymentDetails: {'amount': payment.amount, 'error': e.toString()},
      );
      
      // Canonical fallback: persist the same payment operation into
      // SyncQueueManager instead of using the legacy payment queue.
      try {
        final invoiceNumber = payment.saleId?.trim() ?? '';
        if (invoiceNumber.isNotEmpty) {
          await LocalStorageService.recordUnifiedPayment(
            '',
            payment.amount,
            invoiceNumber: invoiceNumber,
            paymentMethod: 'ONLINE',
            paymentDate: payment.timestamp.toIso8601String(),
            idempotencyKey: payment.fingerprint,
          );

          await SyncQueueManager.enqueue('record_payment', {
            'operation_id': 'PAYMENT_${payment.fingerprint}',
            'idempotency_key': payment.fingerprint,
            'invoice_number': invoiceNumber,
            'amount': payment.amount,
            'reference_id': payment.referenceId,
            'payer_name': payment.payerName,
            'source': payment.detectionSource,
            'timestamp': payment.timestamp.toIso8601String(),
            'payment_method': 'ONLINE',
            'vpa': payment.vpa,
            'bank_name': payment.bankName,
          });
        }
      } catch (fallbackError) {
        await _errorLogger.logPaymentError(
          detectionSource: payment.detectionSource,
          errorReason: 'Canonical payment fallback failed',
          paymentDetails: {
            'amount': payment.amount,
            'error': fallbackError.toString(),
          },
        );
      }
    }
  }
  
  /// Process payment with automatic retry
  Future<void> _processPaymentOnline(PaymentEvent payment) async {
    final invoiceNumber = payment.saleId?.trim() ?? '';
    if (invoiceNumber.isEmpty) {
      await _errorLogger.logPaymentError(
        detectionSource: payment.detectionSource,
        errorReason: 'Payment detected without a matched invoice; automatic recording skipped safely',
        paymentDetails: {
          'amount': payment.amount,
          'reference_id': payment.referenceId,
        },
      );
      return;
    }

    final payload = {
      'operation_id': 'PAYMENT_${payment.fingerprint}',
      'idempotency_key': payment.fingerprint,
      'invoice_number': invoiceNumber,
      'amount': payment.amount,
      'reference_id': payment.referenceId,
      'payer_name': payment.payerName,
      'source': payment.detectionSource,
      'timestamp': payment.timestamp.toIso8601String(),
      'payment_method': 'ONLINE',
      'vpa': payment.vpa,
      'bank_name': payment.bankName,
    };

    try {
      // Canonical local-first: update the local invoice ledger first, then
      // persist the same idempotent operation in the durable outbox.
      // This makes the payment visible immediately even without a network.
      await LocalStorageService.recordUnifiedPayment(
        '',
        payment.amount,
        invoiceNumber: invoiceNumber,
        paymentMethod: 'ONLINE',
        paymentDate: payment.timestamp.toIso8601String(),
        idempotencyKey: payment.fingerprint,
      );

      await SyncQueueManager.enqueue('record_payment', payload);
      unawaited(SyncService.processQueueSafe());

      await _errorLogger.logError(
        message: 'Payment queued for sync: ₹${payment.amount}',
        source: 'PaymentProcessing',
        severity: 'INFO',
      );
    } catch (e) {
      await _errorLogger.logPaymentError(
        detectionSource: payment.detectionSource,
        errorReason: 'Failed to persist automatic payment into canonical outbox',
        paymentDetails: {'amount': payment.amount, 'error': e.toString()},
      );
    }
  }

  /// Sync queued payments when connection restored
  Future<void> _syncQueuedPayments() async {
    try {
      final queued = await _offlineQueue.getQueuedPayments();
      if (queued.isEmpty) return;

      int migrated = 0;
      int failed = 0;

      for (final item in queued) {
        if (item['status'] != 'PENDING') continue;

        final invoiceNumber = item['invoice_number']?.toString().trim() ?? '';
        final idempotencyKey =
            item['idempotency_key']?.toString().trim() ?? item['id']?.toString().trim() ?? '';
        if (invoiceNumber.isEmpty || idempotencyKey.isEmpty) {
          failed++;
          continue;
        }

        final payload = <String, dynamic>{
          'operation_id': 'PAYMENT_$idempotencyKey',
          'idempotency_key': idempotencyKey,
          'invoice_number': invoiceNumber,
          'amount': item['amount'],
          'reference_id': item['reference_id'] ?? item['referenceId'],
          'payer_name': item['payer_name'] ?? item['payerName'],
          'source': item['source'] ?? item['detectionSource'],
          'timestamp': item['timestamp'],
          'payment_method': item['payment_method'] ?? 'ONLINE',
          'vpa': item['vpa'],
          'bank_name': item['bankName'] ?? item['bank_name'],
        };

        try {
          await SyncQueueManager.enqueue('record_payment', payload);
          await SyncService.processQueueSafe();

          final stillPending = await SyncQueueManager.containsBusinessOperation(
            'record_payment',
            idempotencyKey,
          );
          if (!stillPending) {
            await _offlineQueue.markAsSynced(item['id'].toString());
            migrated++;
          }
        } catch (e) {
          failed++;
          if (kDebugMode) {
            print('$_tag Failed migrating legacy payment ${item['id']}: $e');
          }
        }
      }

      if (migrated > 0 || failed > 0) {
        await _offlineQueue.updateSyncStatus(synced: migrated, failed: failed);
      }
      onSyncComplete?.call();
    } catch (e) {
      await _errorLogger.logError(
        message: 'Error migrating legacy payment queue: $e',
        source: 'PaymentSync',
        severity: 'ERROR',
      );
    }
  }

  /// Show offline notification to user
  void _showOfflineNotification(PaymentEvent payment) {
    // This would show a toast/snackbar in the UI
    print('$_tag 🔴 OFFLINE: Payment queued - ₹${payment.amount}');
  }
  
  /// Get offline queue status
  Future<Map<String, dynamic>> getOfflineStatus() async {
    final pending = await _offlineQueue.getPendingCount();
    final status = await _offlineQueue.getSyncStatus();
    
    return {
      'isOnline': _isOnline,
      'pendingPayments': pending,
      'syncStatus': status,
    };
  }
  
  /// Export logs for debugging
  Future<String> exportDebugLogs() async {
    return await _errorLogger.exportLogsAsJson();
  }
  
  /// Clear old logs (older than 48 hours)
  Future<void> cleanupOldLogs() async {
    await _errorLogger.clearOldLogs(olderThanHours: 48);
  }
}
