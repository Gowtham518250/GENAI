import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';

class OfflineSyncCenterPage extends StatefulWidget {
  const OfflineSyncCenterPage({super.key});
  @override
  State<OfflineSyncCenterPage> createState() => _OfflineSyncCenterPageState();
}

class _OfflineSyncCenterPageState extends State<OfflineSyncCenterPage> {
  static const _ink = Color(0xFF172554);
  static const _muted = Color(0xFF64748B);
  static const _primary = Color(0xFF4F46E5);
  bool _loading = true, _working = false, _online = false;
  List<Map<String, dynamic>> _queue = [];
  Map<String, dynamic> _summary = {};
  DateTime? _lastSuccess;
  StreamSubscription<int>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = SyncService.syncQueueStream.listen((_) { if (mounted) unawaited(_load()); });
    unawaited(_load());
  }
  @override
  void dispose() { _subscription?.cancel(); super.dispose(); }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final operations = await SyncQueueManager.getAll();
      final rawSummary = prefs.getString('retail_mind_sync_center_summary_v1');
      final rawLast = prefs.getString('retail_mind_last_successful_sync_at');
      final connected = await Connectivity().checkConnectivity() != ConnectivityResult.none;
      Map<String, dynamic> summary = {};
      if (rawSummary != null && rawSummary.isNotEmpty) {
        final parsed = jsonDecode(rawSummary);
        if (parsed is Map) summary = Map<String, dynamic>.from(parsed);
      }
      operations.sort((a, b) {
        final at = DateTime.tryParse((a['created_at'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch((a['timestamp'] as num?)?.toInt() ?? 0);
        final bt = DateTime.tryParse((b['created_at'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch((b['timestamp'] as num?)?.toInt() ?? 0);
        return bt.compareTo(at);
      });
      if (!mounted) return;
      setState(() { _queue = operations; _summary = summary; _lastSuccess = DateTime.tryParse(rawLast ?? ''); _online = connected; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load sync status: $e')));
    }
  }

  String _status(Map<String, dynamic> item) {
    final status = (item['status'] ?? 'PENDING').toString().toUpperCase();
    if (item['needs_attention'] == true) return 'NEEDS ATTENTION';
    if (status == 'RETRY_WAIT') return 'RETRY SCHEDULED';
    if (status == 'PARKED' || status == 'FAILED') return 'FAILED';
    return status;
  }
  Color _statusColor(Map<String, dynamic> item) {
    final status = (item['status'] ?? 'PENDING').toString().toUpperCase();
    if (item['needs_attention'] == true || status == 'PARKED' || status == 'FAILED') return const Color(0xFFDC2626);
    if (status == 'SYNCING') return const Color(0xFF2563EB);
    if (status == 'RETRY_WAIT') return const Color(0xFFD97706);
    return const Color(0xFF64748B);
  }
  String _actionName(String action) => action.replaceAll('_', ' ');

  Future<void> _retry([String? actionId]) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      if (actionId == null) {
        await SyncService.retryPendingBusinessOperationsNow();
        await SyncService.processQueueSafe();
      } else {
        final prepared = await SyncService.retryQueuedActionNow(actionId);
        if (!prepared && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This operation could not be prepared for retry.')));
      }
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Retry failed: $e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _date(DateTime? value) {
    if (value == null) return 'Not recorded yet';
    final d = value.toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final attention = _queue.where((x) => x['needs_attention'] == true || ['PARKED','FAILED'].contains((x['status'] ?? '').toString().toUpperCase())).length;
    final successful = (_summary['successful_operations'] as num?)?.toInt() ?? 0;
    final failed = (_summary['failed_attempts'] as num?)?.toInt() ?? 0;
    final attempt = DateTime.tryParse((_summary['completed_at'] ?? '').toString());
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FC),
      appBar: AppBar(
        title: Text('Offline Sync Center', style: GoogleFonts.poppins(color: _ink, fontWeight: FontWeight.w800, fontSize: 18)),
        backgroundColor: Colors.white, foregroundColor: _ink, surfaceTintColor: Colors.white, elevation: 0,
        actions: [IconButton(onPressed: _working ? null : _load, tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded))],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator(color: _primary)) : RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF4338CA), Color(0xFF6366F1), Color(0xFF3B82F6)]), borderRadius: BorderRadius.circular(22)),
              child: Row(children: [
                Icon(_online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, color: Colors.white, size: 30),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_online ? 'Connection available' : 'Working offline', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 3),
                  Text(_online ? 'The app can attempt to send queued changes.' : 'Queued changes stay on this device until connection returns.', style: GoogleFonts.poppins(color: Colors.white.withValues(alpha: 0.88), fontSize: 11, height: 1.4)),
                ])),
              ]),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _metric('Queued', _queue.length.toString(), const Color(0xFFD97706))),
              const SizedBox(width: 8),
              Expanded(child: _metric('Attention', attention.toString(), attention > 0 ? const Color(0xFFDC2626) : const Color(0xFF059669))),
              const SizedBox(width: 8),
              Expanded(child: _metric('Succeeded', successful.toString(), const Color(0xFF059669))),
            ]),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(17), border: Border.all(color: const Color(0xFFE5EAF3))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Sync history', style: GoogleFonts.poppins(color: _ink, fontSize: 14, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                _historyRow('Last successful sync', _date(_lastSuccess)),
                const SizedBox(height: 8),
                _historyRow('Last sync attempt', _date(attempt)),
                const SizedBox(height: 8),
                _historyRow('Failed attempts last run', failed.toString()),
              ]),
            ),
            const SizedBox(height: 14),
            SizedBox(height: 48, child: FilledButton.icon(
              onPressed: _working ? null : () => _retry(),
              icon: _working ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.sync_rounded),
              label: Text(_working ? 'Processing queue…' : 'Sync now / Retry pending changes'),
              style: FilledButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
            )),
            const SizedBox(height: 22),
            Text('Queued operations (${_queue.length})', style: GoogleFonts.poppins(color: _ink, fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            if (_queue.isEmpty)
              const Card(child: Padding(padding: EdgeInsets.all(22), child: Text('No queued changes.')))
            else
              ..._queue.map(_operationCard),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value, Color color) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFE5EAF3))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: GoogleFonts.poppins(color: color, fontWeight: FontWeight.w800, fontSize: 20)),
      const SizedBox(height: 3), Text(label, style: GoogleFonts.poppins(color: _muted, fontSize: 9.5)),
    ]),
  );
  Widget _historyRow(String label, String value) => Row(children: [
    Expanded(child: Text(label, style: GoogleFonts.poppins(color: _muted, fontSize: 11))),
    const SizedBox(width: 8), Flexible(child: Text(value, textAlign: TextAlign.right, style: GoogleFonts.poppins(color: _ink, fontSize: 10.5, fontWeight: FontWeight.w700))),
  ]);
  Widget _operationCard(Map<String, dynamic> item) {
    final color = _statusColor(item);
    final id = item['action_id']?.toString() ?? '';
    final error = (item['last_error'] ?? '').toString().trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_actionName((item['action'] ?? '').toString()), style: GoogleFonts.poppins(color: _ink, fontWeight: FontWeight.w700))),
            Text(_status(item), style: GoogleFonts.poppins(color: color, fontSize: 9, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 6),
          Text('Operation: $id · retries: ${(item['retries'] as num?)?.toInt() ?? 0}', style: GoogleFonts.poppins(color: _muted, fontSize: 10)),
          if (error.isNotEmpty) Text('Last error: $error', maxLines: 3, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(color: const Color(0xFFB91C1C), fontSize: 10)),
          Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: _working || id.isEmpty ? null : () => _retry(id), icon: const Icon(Icons.replay_rounded, size: 17), label: const Text('Retry this item'))),
        ]),
      ),
    );
  }
}
