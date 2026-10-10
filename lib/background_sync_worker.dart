import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'api_client.dart';
import 'operation_queue_service.dart';
import 'sync_queue_manager.dart';
import 'session_management.dart';
import 'uuid_service.dart';
import 'data_validation_service.dart';
import 'local_storage_service.dart';

/// Background Sync Worker
/// Processes operations from the persistent queue in the background
/// Implements exponential backoff and priority-based processing
class BackgroundSyncWorker {
  static BackgroundSyncWorker? _instance;
  Timer? _syncTimer;
  Timer? _highPriorityTimer;
  bool _isRunning = false;
  bool _isProcessing = false;
  bool _isHighPriorityProcessing = false;

  static const Duration _syncInterval = Duration(minutes: 5);
  static const Duration _highPriorityInterval = Duration(minutes: 1);
  
  BackgroundSyncWorker._();
  
  static BackgroundSyncWorker get instance {
    _instance ??= BackgroundSyncWorker._();
    return _instance!;
  }
  
  /// Start the background sync worker
  Future<void> start() async {
    if (_isRunning) {
      if (kDebugMode) debugPrint('🔄 Background sync worker already running');
      return;
    }
    
    _isRunning = true;
    
    if (kDebugMode) debugPrint('🚀 Starting background sync worker');
    
    // Initial sync
    await _performSync();
    
    // Start periodic sync
    _syncTimer = Timer.periodic(_syncInterval, (_) async {
      await _performSync();
    });
    
    // Start high-priority sync timer
    _startHighPrioritySync();
  }
  
  /// Stop the background sync worker
  void stop() {
    if (!_isRunning) return;
    
    _isRunning = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    _highPriorityTimer?.cancel();
    _highPriorityTimer = null;

    if (kDebugMode) debugPrint('🛑 Background sync worker stopped');
  }
  
  /// Start high-priority sync timer
  void _startHighPrioritySync() {
    _highPriorityTimer?.cancel();
    _highPriorityTimer = Timer.periodic(_highPriorityInterval, (_) async {
      if (_isRunning) await _syncHighPriorityOperations();
    });
  }
  
  /// Perform sync operation
  Future<void> _performSync() async {
    if (_isProcessing) {
      if (kDebugMode) debugPrint('⏳ Sync already in progress, skipping');
      return;
    }
    
    _isProcessing = true;
    
    try {
      // Check network connectivity
      final connectivityResult = await Connectivity().checkConnectivity();
      final hasNetwork = connectivityResult != ConnectivityResult.none;
      
      if (!hasNetwork) {
        if (kDebugMode) debugPrint('🌐 No network connection, skipping sync');
        return;
      }
      
      // Check if user is authenticated
      final isAuthenticated = await SessionManagementService.isTokenValid();
      if (!isAuthenticated) {
        if (kDebugMode) debugPrint('🔒 User not authenticated, skipping sync');
        return;
      }
      
      // SyncService owns the canonical durable outbox and already dispatches it
      // on demand / on its throttled pulse. This worker only adapts legacy items.
      // Get legacy queue stats
      final stats = await OperationQueueService.instance.getQueueStats();
      
      if (stats.pendingOperations == 0) {
        if (kDebugMode) debugPrint('✅ No pending operations to sync');
        return;
      }
      
      if (kDebugMode) {
        debugPrint('🔄 Starting sync: ${stats.pendingOperations} pending operations');
        debugPrint('   High priority: ${stats.highPriorityPending}');
      }
      
      // Process operations
      await _processOperations();
      
      // Clean up old operations
      await OperationQueueService.instance.cleanupOldOperations();
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Sync error: $e');
    } finally {
      _isProcessing = false;
    }
  }
  
  /// Process legacy high-priority work only when there is something pending.
  /// Canonical queued writes belong exclusively to SyncService.
  Future<void> _syncHighPriorityOperations() async {
    if (_isProcessing || _isHighPriorityProcessing || !_isRunning) return;
    _isHighPriorityProcessing = true;

    try {
      final stats = await OperationQueueService.instance.getQueueStats();
      if (stats.highPriorityPending == 0) return;

      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) return;

      if (!await SessionManagementService.isTokenValid()) return;

      if (kDebugMode) {
        debugPrint(
          '🔥 Syncing legacy high-priority operations: ${stats.highPriorityPending}',
        );
      }
      await _processOperations(priorityOnly: OperationPriority.high);
    } catch (e) {
      if (kDebugMode) debugPrint('❌ High-priority sync error: $e');
    } finally {
      _isHighPriorityProcessing = false;
    }
  }
  /// 🔒 DATA VALIDATION: Validate operation data before sending to backend
  Future<ValidationResult> _validateOperationData(Operation operation) async {
    try {
      final data = operation.payload;
      
      // Validate based on operation type
      switch (operation.type.toOperationString()) {
        case 'create_sale':
        case 'update_sale':
          return DataValidationService.instance.validateSingleSale(data);
        case 'create_customer':
        case 'update_customer':
          // Validate customer data
          if (data['phone'] != null) {
            final phone = data['phone'].toString();
            if (phone.isNotEmpty && !RegExp(r'^[0-9]{10}$').hasMatch(phone)) {
              return ValidationResult(
                isValid: false,
                message: 'Invalid phone number format',
                issues: ['Invalid phone: $phone'],
                issueCount: 1,
              );
            }
          }
          return ValidationResult(isValid: true, message: 'Customer data valid');
        case 'update_stock':
          // Validate inventory data
          if (data['current_stock'] != null) {
            final stock = int.tryParse(data['current_stock'].toString());
            if (stock == null || stock < 0) {
              return ValidationResult(
                isValid: false,
                message: 'Invalid stock value',
                issues: ['Invalid stock: ${data['current_stock']}'],
                issueCount: 1,
              );
            }
          }
          return ValidationResult(isValid: true, message: 'Inventory data valid');
        default:
          return ValidationResult(isValid: true, message: 'Data validation passed');
      }
    } catch (e) {
      return ValidationResult(
        isValid: false,
        message: 'Validation error: $e',
        issues: ['Validation exception: $e'],
        issueCount: 1,
      );
    }
  }

  Future<void> _recordDurableRetry(
    Map<String, dynamic> raw,
    String error,
  ) async {
    final actionId = raw['action_id']?.toString();
    if (actionId == null) return;

    final retries = int.tryParse(raw['retries']?.toString() ?? '') ?? 0;
    final nextRetries = retries + 1;
    final backoffSeconds =
        (1 << nextRetries.clamp(0, 6)).clamp(2, 120);

    final updated = Map<String, dynamic>.from(raw)
      ..['status'] = nextRetries >= 10 ? 'FAILED' : 'PENDING'
      ..['retries'] = nextRetries
      ..['last_attempt'] = DateTime.now().toUtc().toIso8601String()
      ..['updated_at'] = DateTime.now().toUtc().toIso8601String()
      ..['last_error'] = error
      ..['needs_attention'] = nextRetries >= 10
      ..['next_attempt_at'] = DateTime.now()
          .toUtc()
          .add(Duration(seconds: backoffSeconds.toInt()))
          .toIso8601String();

    await SyncQueueManager.update(actionId, updated);
  }
  /// Process operations from the queue
  Future<void> _processOperations({OperationPriority? priorityOnly}) async {
    int processedCount = 0;
    int successCount = 0;
    int duplicateCount = 0;
    int errorCount = 0;
    
    while (true) {
      // Get next operation
      final operation = await OperationQueueService.instance.getNextOperation();
      
      if (operation == null) break;
      
      // Skip if not matching priority filter
      if (priorityOnly != null && operation.priority != priorityOnly) {
        break;
      }
      
      // Mark as in progress
      await OperationQueueService.instance.markInProgress(operation.operationId);
      
      try {
        // 🔒 DATA VALIDATION: Validate operation data before sending to backend
        final validation = await _validateOperationData(operation);
        if (!validation.isValid) {
          if (kDebugMode) debugPrint('⚠️ Operation data validation failed: ${validation.message}');
          await OperationQueueService.instance.markFailed(
            operation.operationId,
            error: 'Data validation failed: ${validation.message}'
          );
          errorCount++;
          continue;
        }
        
        // Send to backend
        final success = await _sendOperationToBackend(operation);
        
        if (success) {
          // Mark as completed
          await OperationQueueService.instance.markCompleted(operation.operationId);
          successCount++;
          
          if (kDebugMode) {
            debugPrint('✅ Operation completed: ${operation.operationId}');
          }
        } else {
          // Mark as failed
          await OperationQueueService.instance.markFailed(
            operation.operationId,
            error: 'Backend returned failure'
          );
          errorCount++;
        }
        
      } catch (e) {
        // Mark as failed
        await OperationQueueService.instance.markFailed(
          operation.operationId,
          error: e.toString()
        );
        errorCount++;
        
        if (kDebugMode) {
          debugPrint('❌ Operation failed: ${operation.operationId} - $e');
        }
      }
      
      processedCount++;
      
      // Safety limit to prevent infinite loops
      if (processedCount >= 50) {
        if (kDebugMode) debugPrint('⚠️ Reached operation processing limit');
        break;
      }
    }
    
    if (kDebugMode) {
      debugPrint('📊 Sync complete: $processedCount processed, $successCount success, $duplicateCount duplicate, $errorCount errors');
    }
  }
  
  /// Send operation to backend
  Future<bool> _sendOperationToBackend(Operation operation) async {
    try {
      final response = await ApiClient.postJson('/api/operations', {
        'operation_id': operation.operationId,
        'operation_type': operation.type.toOperationString(),
        'payload': operation.payload,
        'entity_id': operation.entityId,
        'device_id': operation.deviceId,
        'user_id': operation.userId,
        'timestamp': operation.createdTime.toIso8601String(),
      });
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = _parseResponse(response.body);
        
        // Check if operation was duplicate
        if (data['status'] == 'duplicate') {
          if (kDebugMode) debugPrint('♻️ Duplicate operation skipped: ${operation.operationId}');
          return true; // Consider duplicate as success
        }
        
        return data['status'] == 'success';
      } else {
        if (kDebugMode) debugPrint('❌ Backend error: ${response.statusCode}');
        return false;
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Network error sending operation: $e');
      return false;
    }
  }
  
  /// Parse response JSON
  dynamic _parseResponse(String responseBody) {
    try {
      // Simple JSON parse
      final parts = responseBody.split('{');
      if (parts.length > 1) {
        // Use simple parsing - in production use dart:convert
        return {'status': 'success'}; // Placeholder
      }
      return {'status': 'error'};
    } catch (e) {
      return {'status': 'error'};
    }
  }
  
  /// Force immediate sync (manual trigger)
  Future<void> forceSync() async {
    if (kDebugMode) debugPrint('🔄 Force sync triggered');
    
    // Cancel any existing sync
    if (_isProcessing) {
      await Future.delayed(Duration(seconds: 1));
    }
    
    await _performSync();
  }
  
  /// Get sync status
  Future<SyncStatus> getSyncStatus() async {
    final stats = await OperationQueueService.instance.getQueueStats();
    final connectivityResult = await Connectivity().checkConnectivity();
    final hasNetwork = connectivityResult != ConnectivityResult.none;
    
    return SyncStatus(
      isRunning: _isRunning,
      isProcessing: _isProcessing,
      hasNetwork: hasNetwork,
      pendingOperations: stats.pendingOperations,
      highPriorityPending: stats.highPriorityPending,
      failedOperations: stats.failedOperations,
      lastSyncTime: stats.lastSyncTime,
      queueHealth: stats.health,
    );
  }
}

/// Sync status model
class SyncStatus {
  final bool isRunning;
  final bool isProcessing;
  final bool hasNetwork;
  final int pendingOperations;
  final int highPriorityPending;
  final int failedOperations;
  final DateTime? lastSyncTime;
  final QueueHealth queueHealth;
  
  SyncStatus({
    required this.isRunning,
    required this.isProcessing,
    required this.hasNetwork,
    required this.pendingOperations,
    required this.highPriorityPending,
    required this.failedOperations,
    this.lastSyncTime,
    required this.queueHealth,
  });
  
  /// Get overall sync health
  SyncHealth get overallHealth {
    if (!hasNetwork) return SyncHealth.offline;
    if (failedOperations > 10) return SyncHealth.critical;
    if (failedOperations > 5) return SyncHealth.warning;
    if (highPriorityPending > 20) return SyncHealth.warning;
    if (pendingOperations == 0) return SyncHealth.excellent;
    return SyncHealth.good;
  }
  
  /// Get status message
  String get statusMessage {
    switch (overallHealth) {
      case SyncHealth.excellent:
        return 'All data synced';
      case SyncHealth.good:
        return 'Syncing data...';
      case SyncHealth.warning:
        return 'Some sync issues';
      case SyncHealth.critical:
        return 'Sync problems detected';
      case SyncHealth.offline:
        return 'Offline - data saved locally';
    }
  }
}

/// Overall sync health
enum SyncHealth {
  excellent,
  good,
  warning,
  critical,
  offline,
}