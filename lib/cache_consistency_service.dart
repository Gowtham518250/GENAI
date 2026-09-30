import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Read-side consistency coordinator for offline-first datasets.
/// Tracks remote freshness and local pending mutations per role/user.
class CacheConsistencyService {
  static const Duration defaultMaxAge = Duration(minutes: 2);

  static Future<String> _scope() async {
    final prefs = await SharedPreferences.getInstance();
    final role = (prefs.getString('user_type') ?? prefs.getString('role') ?? 'OWNER').trim().toUpperCase();
    final intUserId = prefs.getInt('user_id') ?? prefs.getInt('userId');
    final userId = intUserId?.toString() ??
        prefs.getString('user_id') ??
        prefs.getString('userId') ??
        'anonymous';
    return role + '_' + userId;
  }

  static Future<String> _key(String dataset) async {
    return 'cache_consistency_' + await _scope() + '_' + dataset.trim().toLowerCase();
  }

  static Future<Map<String, dynamic>> metadata(String dataset) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(await _key(dataset));
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> _write(String dataset, Map<String, dynamic> value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await _key(dataset), jsonEncode(value));
  }

  static DateTime? _parse(dynamic value) => DateTime.tryParse(value?.toString() ?? '');

  static Future<void> markRemoteRefresh(String dataset, {DateTime? serverUpdatedAt, int? recordCount}) async {
    final now = DateTime.now().toUtc();
    final current = await metadata(dataset);
    current['last_remote_refresh_at'] = now.toIso8601String();
    current['last_remote_updated_at'] = (serverUpdatedAt ?? now).toUtc().toIso8601String();
    // A remote read does not ACK local mutations. Preserve dirty state until
    // durable mutations have been acknowledged explicitly.
    if (current['pending_mutations'] == null) {
      current['dirty'] = false;
    }
    if (recordCount != null) current['record_count'] = recordCount;
    await _write(dataset, current);
  }

  static Future<void> markLocalMutation(String dataset, {String? operationId}) async {
    final current = await metadata(dataset);
    current['dirty'] = true;
    current['pending_mutations'] =
        ((current['pending_mutations'] as num?)?.toInt() ?? 0) + 1;
    current['local_revision'] = ((current['local_revision'] as num?)?.toInt() ?? 0) + 1;
    current['last_local_mutation_at'] = DateTime.now().toUtc().toIso8601String();
    if (operationId != null && operationId.isNotEmpty) current['last_operation_id'] = operationId;
    await _write(dataset, current);
  }

  static Future<void> markLocalMutationAcknowledged(String dataset, {String? operationId}) async {
    final current = await metadata(dataset);
    final remaining =
        ((current['pending_mutations'] as num?)?.toInt() ?? 0) - 1;
    current['pending_mutations'] = remaining < 0 ? 0 : remaining;
    current['dirty'] = (current['pending_mutations'] as int) > 0;
    current['last_ack_at'] = DateTime.now().toUtc().toIso8601String();
    if (operationId != null && operationId.isNotEmpty) current['last_ack_operation_id'] = operationId;
    await _write(dataset, current);
  }

  static Future<void> markConflict(String dataset, {String? identity, String? reason}) async {
    final current = await metadata(dataset);
    current['conflict_count'] = ((current['conflict_count'] as num?)?.toInt() ?? 0) + 1;
    current['last_conflict_at'] = DateTime.now().toUtc().toIso8601String();
    if (identity != null) current['last_conflict_identity'] = identity;
    if (reason != null) current['last_conflict_reason'] = reason;
    await _write(dataset, current);
  }

  static Future<bool> isFresh(String dataset, {Duration maxAge = defaultMaxAge}) async {
    final current = await metadata(dataset);
    final last = _parse(current['last_remote_refresh_at']);
    if (last == null) return false;
    return DateTime.now().toUtc().difference(last.toUtc()) <= maxAge;
  }

  static Future<DateTime?> lastRemoteRefresh(String dataset) async {
    return _parse((await metadata(dataset))['last_remote_refresh_at']);
  }

  static bool isPending(Map<String, dynamic> record) {
    final sync = (record['sync_status'] ?? record['syncState'] ?? record['status'])?.toString().trim().toLowerCase();
    return sync == 'pending' || sync == 'pending_sync' || sync == 'retry_wait' || sync == 'failed' || sync == 'dirty' || record['is_offline'] == true;
  }

  static String identity(Map<String, dynamic> record, [List<String> fields = const ['operation_id','local_order_id','server_order_id','order_id','product_id','id','invoice_id','sale_id','invoice_number','sku','barcode']]) {
    for (final field in fields) {
      final value = record[field]?.toString().trim();
      if (value != null && value.isNotEmpty && value != 'null' && value != '0') return value.toLowerCase();
    }
    return '';
  }

  static DateTime? updatedAt(Map<String, dynamic> record) {
    for (final field in const ['server_updated_at','updated_at','last_updated','local_updated_at','created_at']) {
      final parsed = _parse(record[field]);
      if (parsed != null) return parsed.toUtc();
    }
    return null;
  }

  /// Unsynced local mutations stay visible until their ACK arrives.
  /// Otherwise the newer server representation wins.
  static Map<String, dynamic> mergeRecord(Map<String, dynamic> local, Map<String, dynamic> remote, {String? dataset}) {
    final key = identity(remote).isNotEmpty ? identity(remote) : identity(local);
    final localPending = isPending(local);
    final localUpdated = updatedAt(local);
    final remoteUpdated = updatedAt(remote);

    if (localPending) {
      final merged = <String, dynamic>{...remote, ...local, 'conflict_state': 'local_pending'};
      if (remoteUpdated != null && localUpdated != null && remoteUpdated.isAfter(localUpdated)) {
        merged['server_snapshot_updated_at'] = remoteUpdated.toIso8601String();
        merged['conflict_state'] = 'local_pending_remote_newer';
      }
      if (dataset != null) {
        Future.microtask(() => markConflict(dataset, identity: key, reason: merged['conflict_state']?.toString()));
      }
      return merged;
    }

    final localTime = localUpdated ?? DateTime.fromMillisecondsSinceEpoch(0);
    final remoteTime = remoteUpdated ?? DateTime.fromMillisecondsSinceEpoch(0);
    final remoteWins = remoteUpdated == null
        ? true
        : !remoteTime.isBefore(localTime);
    return remoteWins ? <String, dynamic>{...local, ...remote, 'conflict_state': 'remote_wins'} : <String, dynamic>{...remote, ...local, 'conflict_state': 'local_newer'};
  }

  static List<Map<String, dynamic>> mergeLists(List<dynamic> local, List<dynamic> remote, {required String dataset}) {
    final merged = <String, Map<String, dynamic>>{};
    final anonymous = <Map<String, dynamic>>[];
    for (final raw in local) {
      if (raw is! Map) continue;
      final record = Map<String, dynamic>.from(raw);
      final key = identity(record);
      if (key.isEmpty) anonymous.add(record); else merged[key] = record;
    }
    for (final raw in remote) {
      if (raw is! Map) continue;
      final record = Map<String, dynamic>.from(raw);
      final key = identity(record);
      if (key.isEmpty) { anonymous.add(record); continue; }
      final existing = merged[key];
      merged[key] = existing == null ? {...record, 'sync_status': 'synced'} : mergeRecord(existing, record, dataset: dataset);
    }
    if (kDebugMode) debugPrint('🧭 [CacheConsistency] $dataset merged local=${local.length} remote=${remote.length} result=${merged.length + anonymous.length}');
    return [...merged.values, ...anonymous];
  }
}
