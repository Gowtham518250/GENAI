import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'scoped_shared_preferences.dart';
import 'package:intl/intl.dart';
import 'api_client.dart';
import 'app_localizations.dart';
import 'package:provider/provider.dart';
import 'language_provider.dart';
import 'models.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'worker_local_storage.dart';
import 'worker_attendance_detail_page.dart';
import 'worker_pin_reset_page.dart';
import 'attendance_offline_service.dart';
import 'sync_service.dart';

class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});
  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const Color _primary = Color(0xFF6366F1);
  static const Color _present = Color(0xFF10B981);
  static const Color _absent = Color(0xFFEF4444);
  static const Color _half = Color(0xFFF59E0B);

  // Shift window used to flag late check-ins / early check-outs.
  static const TimeOfDay _shiftStart = TimeOfDay(hour: 9, minute: 30);
  static const int _lateGraceMinutes = 15;

  final DateFormat _df = DateFormat('yyyy-MM-dd');
  bool _loading = true;
  List<dynamic> _records = [];
  Map<String, dynamic>? _todaySummary;
  int? _userId;
  late TabController _tab;
  Timer? _timer;
  Timer? _refreshTimer;
  bool _refreshInFlight = false;
  String _liveHours = '0.0';
  List<Worker> _staff = [];
  // Source of truth for "am I currently checked in?" — read straight from
  // OfflineAttendanceService (which supports multiple sessions/day) instead
  // of being derived from the collapsed `_records` display list.
  Map<String, dynamic>? _mySession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tab = TabController(length: 3, vsync: this);
    _init();
    _startTimer();
    _startRefreshTimer();
  }

  @override
  void dispose() {
    _tab.dispose();
    _timer?.cancel();
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getInt('user_id') ?? prefs.getInt('userId');

    if (_userId == null) {
      if (kDebugMode) debugPrint('⚠️ No user_id found in preferences');
      // Delay snack message until widget is built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showSnack('⚠️ Please login to use attendance', _absent);
      });
    }

    await _loadStaff();
    // Backend is authoritative after login/data-clear; reconcile before the
    // first UI fetch so a stale local state cannot force a false Check In.
    try {
      await OfflineAttendanceService.reconcileFromBackend();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Attendance reconciliation deferred: $e');
    }
    await _fetch();
  }

  Future<void> _loadStaff() async {
    // Load staff from local storage first (immediate response)
    try {
      final workers = await WorkerLocalStorage.fetchWorkers(_userId ?? 0);
      
      if (workers.isNotEmpty && mounted) {
        setState(() {
          _staff = workers;
        });
        if (kDebugMode) debugPrint('📦 Loaded ${_staff.length} workers from local storage');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error loading staff from local storage: $e');
    }
    
    // Then sync with backend in background
    try {
      final url = (_userId != null && _userId! > 0)
          ? '${ApiClient.attendanceWorkers}?user_id=$_userId'
          : ApiClient.attendanceWorkers;
      final res = await ApiClient.getJson(url);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (mounted) {
          final syncedWorkers = data is List
              ? data.map((w) => Worker.fromJson(w)).toList()
              : (data is Map && data['workers'] is List)
                  ? (data['workers'] as List)
                      .whereType<Map>()
                      .map((w) => Worker.fromJson(Map<String, dynamic>.from(w)))
                      .toList()
                  : <Worker>[];

          // Backend success becomes the durable offline roster.
          await WorkerLocalStorage.saveWorkers(_userId ?? 0, syncedWorkers);

          setState(() {
            _staff = syncedWorkers;
          });
          if (kDebugMode) {
            debugPrint('✅ Synced and cached ${_staff.length} workers from backend');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Backend staff sync failed: $e, using local data');
    }
  }

  Future<void> _saveStaff() async {
    // Staff is now synced with backend - no local save needed
    // Refresh from backend to ensure consistency
    await _loadStaff();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    try {
      // Local-first: render persisted attendance immediately, even offline.
      var localRecords = await OfflineAttendanceService.loadLocalRecords();
      if (mounted && localRecords.isNotEmpty) {
        setState(() => _records = localRecords);
      }

      final today = _df.format(DateTime.now());
      
      // Fetch shopkeeper's attendance
      String url = '${ApiClient.attendancePrefix}/date/$today';
      if (_userId != null) {
        url += '?employee_id=$_userId';
      }
      final res = await ApiClient.getJson(url);
      
      List<dynamic> allRecords = [];
      
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data is List) {
          allRecords = List<dynamic>.from(data);
        } else if (data is Map) {
          allRecords = List<dynamic>.from((data['records'] ?? []) as List);
          _todaySummary = Map<String, dynamic>.from(data);
        }
      }
      
      // Fetch worker attendance in parallel so payroll/attendance stays responsive.
      final workerResults = await Future.wait<List<dynamic>>(_staff.map((worker) async {
        try {
          final workerUrl = '${ApiClient.attendancePrefix}/employee/${worker.id}';
          final workerRes = await ApiClient.getJson(workerUrl);
          if (workerRes.statusCode == 200) {
            final workerData = json.decode(workerRes.body);
            if (workerData is Map && workerData['records'] is List) return List<dynamic>.from(workerData['records'] as List);
            if (workerData is List) return List<dynamic>.from(workerData);
          }
        } catch (e) {
          if (kDebugMode) debugPrint('Error fetching attendance for worker ${worker.id}: $e');
        }
        return <dynamic>[];
      }));
      for (final workerRecords in workerResults) { allRecords.addAll(workerRecords); }

      // Persist the complete remote history so payroll does not fall to zero
      // on cold start when the network/auth refresh is temporarily unavailable.
      var remoteMergedSuccessfully = false;
      if (allRecords.isNotEmpty) {
        await OfflineAttendanceService.mergeRemoteRecords(
          allRecords.whereType<Map>().map((r) => Map<String, dynamic>.from(r)).toList(),
        );
        // Re-read the cache because mergeRemoteRecords normalizes the backend's
        // nested sessions into independent durable records. This is especially
        // important immediately after the user clears app data.
        localRecords = await OfflineAttendanceService.loadLocalRecords();
        remoteMergedSuccessfully = true;
      }
      
      // IMPORTANT: never replace durable local attendance with a stale/empty
      // cloud response. Immediately after CHECK IN/CHECK OUT the local record
      // is marked local_pending=true; a cloud response can legitimately lag
      // behind it. Merge by employee/worker + business date and prefer the
      // local pending record until sync confirms it.
      final mergedByKey = <String, Map<String, dynamic>>{};
      // Once the remote records have been normalized into the local cache,
      // use that cache as the canonical display source. Mixing the raw
      // one-row-per-day backend response back into the map can overwrite the
      // session-specific records that were just reconstructed.
      final displaySource = remoteMergedSuccessfully
          ? localRecords
          : [...localRecords, ...allRecords];
      String attendanceKey(Map<String, dynamic> r) {
        final employee = (r['worker_id'] ?? r['employee_id'] ?? '').toString();
        final date = (r['attendance_date'] ?? '').toString().split('T').first;
        // Include session_index so multiple check-in/out pairs on the same
        // day are kept as separate records instead of overwriting each
        // other (which previously made hours/history undercount and made
        // the day look "closed" after the first checkout).
        final session = (r['session_index'] ?? 0).toString();
        return '$employee:$date:$session';
      }

      for (final raw in displaySource) {
        if (raw is! Map) continue;
        final record = Map<String, dynamic>.from(raw);
        final key = attendanceKey(record);
        if (key == ':') continue;
        final existing = mergedByKey[key];
        if (existing == null) {
          mergedByKey[key] = record;
        } else if (record['local_pending'] == true && existing['local_pending'] != true) {
          mergedByKey[key] = record;
        } else if (existing['local_pending'] == true) {
          // Preserve the local pending state and its timestamps. Remote data
          // must not make the UI flip back to CHECK IN while sync is pending.
          mergedByKey[key] = {...record, ...existing, 'local_pending': true};
        } else {
          mergedByKey[key] = {...existing, ...record};
        }
      }

      if (mounted) {
        setState(() {
          _records = mergedByKey.values.toList();
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error fetching attendance: $e');
      }
      if (mounted) {
        _showSnack('Failed to load attendance data', _absent);
      }
    }
    setState(() => _loading = false);
    await _refreshMySession();
    await _updateLiveHours();
  }

  Future<void> _refreshAttendanceData() async {
    if (!mounted || _refreshInFlight) return;
    _refreshInFlight = true;
    try {
      await _loadStaff();
      try { await OfflineAttendanceService.reconcileFromBackend(); } catch (e) { if (kDebugMode) debugPrint('⚠️ Attendance reconcile refresh failed: $e'); }
      await _fetch();
    } finally {
      _refreshInFlight = false;
    }
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) => _refreshAttendanceData());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAttendanceData();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (mounted) _updateLiveHours();
    });
  }

  Future<void> _updateLiveHours() async {
    if (_userId == null) return;
    // Sum across ALL of today's sessions (not just one record), so hours
    // keep accumulating correctly across multiple check-in/check-out pairs.
    final total = await OfflineAttendanceService.todayTotalHours(employeeId: _userId!);
    if (mounted) {
      setState(() {
        _liveHours = total.toStringAsFixed(2);
      });
    }
  }

  /// Refreshes the open-session pointer used to drive the check-in/out
  /// button. Always re-read after fetch/check-in/check-out so the button
  /// never gets stuck disabled once a session is closed.
  Future<void> _refreshMySession() async {
    if (_userId == null) return;
    final open = await OfflineAttendanceService.openSessionToday(employeeId: _userId!);
    if (mounted) setState(() => _mySession = open);
  }

  /// Attendance timestamps are stored by the backend as Asia/Kolkata
  /// wall-clock values. Older API responses may omit the timezone suffix;
  /// those values must therefore be treated as local IST time rather than UTC.
  /// Newer responses include an explicit +05:30 offset and are parsed normally.
  DateTime? _parseServerTime(dynamic raw) {
    if (raw == null) return null;
    final str = raw.toString().trim();
    if (str.isEmpty) return null;
    final parsed = DateTime.tryParse(str);
    if (parsed == null) return null;

    // No suffix means the attendance API's legacy IST-naive timestamp.
    if (!str.contains('Z') && !RegExp(r'[+-]\\d{2}:\\d{2}$').hasMatch(str)) {
      return parsed;
    }
    return parsed.toLocal();
  }

  bool _isLateCheckIn(Map r) {
    final cin = _parseServerTime(r['check_in_time']);
    if (cin == null) return false;
    final threshold = DateTime(
        cin.year, cin.month, cin.day, _shiftStart.hour, _shiftStart.minute + _lateGraceMinutes);
    return cin.isAfter(threshold);
  }

  int _sessionIndex(Map r) {
    final raw = r['session_index'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  bool _isOpenSession(Map r) =>
      r['check_in_time'] != null && r['check_out_time'] == null;

  List<Map<String, dynamic>> _ownerSessionsToday() {
    final today = _df.format(DateTime.now());
    final sessions = _records.where((r) {
      if (r is! Map) return false;
      final recDate = (r['attendance_date'] ?? '').toString().split('T').first.trim();
      if (recDate != today) return false;
      final empId = r['employee_id'];
      final workerId = r['worker_id'];
      final isOwner = empId == _userId || empId.toString() == _userId.toString();
      final notWorkerRow = workerId == null ||
          workerId.toString().isEmpty ||
          workerId.toString() == _userId.toString();
      return isOwner && notWorkerRow;
    }).map((r) => Map<String, dynamic>.from(r as Map)).toList();
    sessions.sort((a, b) => _sessionIndex(a).compareTo(_sessionIndex(b)));
    return sessions;
  }

  List<Map<String, dynamic>> _workerSessionsToday(Worker worker) {
    final today = _df.format(DateTime.now());
    final sessions = _records.where((r) {
      if (r is! Map) return false;
      final recordWorkerId = r['worker_id'] ?? r['employee_id'];
      if (recordWorkerId == null) return false;
      final recDate = (r['attendance_date'] ?? '').toString().split('T').first.trim();
      return recordWorkerId.toString() == worker.id.toString() && recDate == today;
    }).map((r) => Map<String, dynamic>.from(r as Map)).toList();
    sessions.sort((a, b) => _sessionIndex(a).compareTo(_sessionIndex(b)));
    return sessions;
  }

  /// Derive a worker's current state from the latest attendance event.
  /// This intentionally does not use "any open row", because the backend
  /// stores a daily attendance row plus session metadata and stale records
  /// can otherwise make a completed checkout look open.
  bool _isWorkerCurrentlyIn(List<Map<String, dynamic>> sessions) {
    DateTime? latestCheckIn;
    DateTime? latestCheckOut;

    for (final session in sessions) {
      final checkIn = _parseServerTime(session['check_in_time']);
      final checkOut = _parseServerTime(session['check_out_time']);

      if (checkIn != null &&
          (latestCheckIn == null || checkIn.isAfter(latestCheckIn!))) {
        latestCheckIn = checkIn;
      }
      if (checkOut != null &&
          (latestCheckOut == null || checkOut.isAfter(latestCheckOut!))) {
        latestCheckOut = checkOut;
      }
    }

    return latestCheckIn != null &&
        (latestCheckOut == null || latestCheckIn.isAfter(latestCheckOut));
  }

  double _hoursForSession(Map r) {
    // Expanded morning/afternoon rows represent one session. Prefer the
    // session's own hours before falling back to the daily aggregate.
    final sessionHours = r['working_hours'];
    if ((r['session_index'] != null || r['session_key'] != null) && sessionHours is num) {
      return sessionHours.toDouble();
    }

    final total = r['total_working_hours'];
    if (total is num) return total.toDouble();

    if (sessionHours is num) return sessionHours.toDouble();

    final sessions = r['sessions'];
    if (sessions is Map) {
      var sum = 0.0;
      for (final value in sessions.values) {
        if (value is Map && value['working_hours'] is num) {
          sum += (value['working_hours'] as num).toDouble();
        }
      }
      if (sum > 0) return sum;
    }

    final cin = _parseServerTime(r['check_in_time']);
    final cout = _parseServerTime(r['check_out_time']);
    if (cin != null && cout != null) {
      return cout.difference(cin).inSeconds / 3600.0;
    }
    if (cin != null && r['check_out_time'] == null) {
      return DateTime.now().difference(cin).inSeconds / 3600.0;
    }
    return 0;
  }

  String _fmtClock(dynamic time) {
    final parsed = _parseServerTime(time);
    if (parsed == null) return '--:--';
    return DateFormat.jm().format(parsed);
  }

  double _calculateWorkerMonthlyHours(int workerId) {
    double totalHours = 0;
    final now = DateTime.now();

    for (final r in _records) {
      final recordWorkerId = r['worker_id'] ?? r['employee_id'];
      if (recordWorkerId == null) continue;
      if (recordWorkerId.toString() != workerId.toString()) continue;

      final attDateStr =
          (r['attendance_date'] ?? '').toString().split('T').first.trim();
      final attDate = DateTime.tryParse(attDateStr);
      if (attDate == null) continue;
      if (attDate.year != now.year || attDate.month != now.month) continue;

      totalHours += _hoursForSession(r);
    }
    return totalHours;
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final mySessions = _ownerSessionsToday();
    final hasOpenSession = _mySession != null;
    final nextSessionNo = mySessions.length + (hasOpenSession ? 0 : 1);
    final currentSessionNo = hasOpenSession
        ? _sessionIndex(_mySession!) + 1
        : (mySessions.isEmpty ? 1 : _sessionIndex(mySessions.last) + 1);

    final btnLabel = hasOpenSession
        ? 'End Session $currentSessionNo'
        : (mySessions.isEmpty
            ? AppLocalizations.of(context).checkIn
            : 'Start Session $nextSessionNo');
    final btnColor = hasOpenSession ? _primary : _present;
    final btnIcon = hasOpenSession ? Icons.logout : Icons.login;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).attendance, style: GoogleFonts.poppins(
            fontWeight: FontWeight.w700, color: Colors.white)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          _buildLanguageSwitcher(),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetch)
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: [
            Tab(text: AppLocalizations.of(context).today),
            Tab(text: AppLocalizations.of(context).history),
            const Tab(text: 'Payroll'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _todayTab(mySessions, hasOpenSession),
          _historyTab(),
          _payrollTab(),
        ],
      ),
    );
  }

  String _sessionKeyForRecord(Map<String, dynamic> record) {
    final raw = (record['session_key'] ?? record['session'] ?? '').toString().trim().toLowerCase();
    if (raw == 'morning') return 'morning';
    if (raw == 'afternoon' || raw == 'evening') return 'afternoon';

    final label = (record['label'] ?? record['session_label'] ?? '').toString().toLowerCase();
    if (label.contains('morning')) return 'morning';
    if (label.contains('afternoon') || label.contains('evening')) return 'afternoon';

    final checkIn = _parseServerTime(record['check_in_time']);
    if (checkIn != null) {
      return checkIn.hour < 14 ? 'morning' : 'afternoon';
    }
    return _sessionIndex(record) == 0 ? 'morning' : 'afternoon';
  }

  String _currentSessionKey() {
    return DateTime.now().hour < 14 ? 'morning' : 'afternoon';
  }

  List<Map<String, dynamic>> _workerSessionRecords(Worker worker, String sessionKey) {
    return _workerSessionsToday(worker)
        .where((record) => _sessionKeyForRecord(record) == sessionKey)
        .toList();
  }

  Widget _sessionHeader(String sessionKey, int present, int active, int staffCount) {
    final morning = sessionKey == 'morning';
    final color = morning ? const Color(0xFFF59E0B) : _primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: 0.12),
            color.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.14),
            child: Icon(morning ? Icons.wb_sunny_outlined : Icons.wb_twilight, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  morning ? 'Morning Session' : 'Afternoon Session',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                Text(
                  morning ? 'Check-ins before 2:00 PM' : 'Check-ins from 2:00 PM onward',
                  style: GoogleFonts.poppins(fontSize: 10, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('$present/$staffCount', style: GoogleFonts.poppins(fontWeight: FontWeight.w800, color: color)),
              Text('$active active', style: GoogleFonts.poppins(fontSize: 9, color: Colors.grey.shade600)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _todayTab(List<Map<String, dynamic>> mySessions, bool hasOpenSession) {
    final today = DateFormat('EEEE, dd MMMM yyyy').format(DateTime.now());
    var inShop = 0;
    var betweenSessions = 0;
    var notMarked = 0;
    for (final worker in _staff) {
      final sessions = _workerSessionsToday(worker);
      if (_isWorkerCurrentlyIn(sessions)) {
        inShop++;
      } else if (sessions.isNotEmpty) {
        betweenSessions++;
      } else {
        notMarked++;
      }
    }
    final statusLabel = hasOpenSession
        ? 'CHECKED IN'
        : (mySessions.isEmpty ? 'NOT STARTED' : 'BETWEEN SESSIONS');
    final statusColor = hasOpenSession
        ? Colors.orange
        : (mySessions.isEmpty ? Colors.grey : _present);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
              borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.calendar_today, color: Colors.white70, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(today, style: GoogleFonts.poppins(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              _bannerStat('${mySessions.length}', 'My sessions'),
              const SizedBox(width: 16),
              _bannerStat('${_staff.length}', 'Workers'),
              const SizedBox(width: 16),
              _bannerStat(_liveHours, 'Hours today'),
            ]),
          ]),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Staff attendance', style: GoogleFonts.poppins(
                fontWeight: FontWeight.w800, fontSize: 18, color: const Color(0xFF1F2937))),
            if (_staff.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: _primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                child: Text('${_staff.length} on roster', style: GoogleFonts.poppins(
                    fontSize: 11, color: _primary, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_staff.isEmpty)
          _noWorkersCard()
        else ...[
          Row(children: [
            Expanded(child: _miniStat('In shop', '$inShop', _present)),
            const SizedBox(width: 8),
            Expanded(child: _miniStat('Between sessions', '$betweenSessions', _primary)),
            const SizedBox(width: 8),
            Expanded(child: _miniStat('Not marked', '$notMarked', Colors.grey)),
          ]),
          const SizedBox(height: 16),
          Builder(builder: (context) {
            final morningPresent = _staff.where((worker) => _workerSessionRecords(worker, 'morning').isNotEmpty).length;
            final morningActive = _staff.where((worker) => _workerSessionRecords(worker, 'morning').any(_isOpenSession)).length;
            return Column(
              children: [
                _sessionHeader('morning', morningPresent, morningActive, _staff.length),
                ..._staff.map((worker) => _workerAttendanceTile(worker, sessionKey: 'morning')),
              ],
            );
          }),
          const SizedBox(height: 14),
          Builder(builder: (context) {
            final afternoonPresent = _staff.where((worker) => _workerSessionRecords(worker, 'afternoon').isNotEmpty).length;
            final afternoonActive = _staff.where((worker) => _workerSessionRecords(worker, 'afternoon').any(_isOpenSession)).length;
            return Column(
              children: [
                _sessionHeader('afternoon', afternoonPresent, afternoonActive, _staff.length),
                ..._staff.map((worker) => _workerAttendanceTile(worker, sessionKey: 'afternoon')),
              ],
            );
          }),
        ],
        const SizedBox(height: 24),
        const Divider(thickness: 1, height: 1),
        const SizedBox(height: 24),

        Text('My sessions today', style: GoogleFonts.poppins(
            fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.08),
              border: Border.all(color: statusColor.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            CircleAvatar(
                backgroundColor: statusColor,
                radius: 22,
                child: Icon(
                    hasOpenSession ? Icons.timelapse : Icons.check,
                    color: Colors.white, size: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(AppLocalizations.of(context).todayStatus,
                    style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade600)),
                Text(statusLabel, style: GoogleFonts.poppins(
                    fontSize: 17, fontWeight: FontWeight.w700, color: statusColor)),
                Text(
                  hasOpenSession
                      ? 'Session ${_sessionIndex(_mySession!) + 1} is open. End it when you step out.'
                      : (mySessions.isEmpty
                          ? 'Start session 1 with the button below.'
                          : 'Last session closed. You can start session ${mySessions.length + 1} anytime.'),
                  style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade600),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        if (mySessions.isEmpty)
          _emptyAttendance()
        else ...[
          ...mySessions.map((session) => _sessionDetailCard(session)),
          const SizedBox(height: 8),
          _hoursCard(_liveHours, isLive: hasOpenSession),
        ],

        const SizedBox(height: 32),
        Text('Attendance Guide', style: GoogleFonts.poppins(
            fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 12),
        _guide('Each check-in and check-out is one session (lunch break = two sessions).', Icons.layers, _primary),
        _guide('Start a worker session when they arrive; end that session when they leave.', Icons.login, _present),
        _guide('If there are no workers, add them in Worker Management first.', Icons.group_off, Colors.grey),
        _guide('History lists every session with in/out times.', Icons.history, Colors.orange),
      ]),
    );
  }

  Widget _bannerStat(String value, String label) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _noWorkersCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6),
        ],
      ),
      child: Column(
        children: [
          Icon(Icons.group_off, size: 32, color: Colors.grey.shade500),
          const SizedBox(height: 8),
          Text(
            'No workers added',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
          ),
          Text(
            'Add workers to manage their attendance here.',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            maxLines: 1,
            style: GoogleFonts.poppins(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 9, color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }

  Widget _sessionDetailCard(Map<String, dynamic> session) {
    final isOpen = _isOpenSession(session);
    final hours = _hoursForSession(session).toStringAsFixed(1);
    final statusColor = isOpen ? _present : Colors.grey;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6),
        ],
      ),
      child: Row(
        children: [
          Icon(
            isOpen ? Icons.timelapse : Icons.check_circle_outline,
            color: statusColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Session ${_sessionIndex(session) + 1}',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                ),
                Text(
                  'In ${_fmtClock(session['check_in_time'])}  ·  Out ${_fmtClock(session['check_out_time'])}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$hours hrs',
            style: GoogleFonts.poppins(
              color: statusColor,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _workerAttendanceTile(Worker worker, {String? sessionKey}) {
    // Check today's attendance from backend records using worker_id
    final today = _df.format(DateTime.now());
    var workerRecords = _records.where((r) {
      // Use worker_id if available, otherwise fall back to employee_id for backward compatibility.
      // Compare as strings: worker.id is a String, but the API returns
      // worker_id/employee_id as a raw JSON int, so a bare `==` here always
      // failed and this tile never detected "already checked in".
      final recordWorkerId = r['worker_id'] ?? r['employee_id'];
      
      // Explicit null check to prevent null pointer exception
      if (recordWorkerId == null) return false;
      
      final recDate = (r['attendance_date'] ?? '').toString().split('T').first.trim();
      return recordWorkerId.toString() == worker.id.toString() && recDate == today;
    }).toList();

    if (sessionKey != null) {
      workerRecords = workerRecords
          .where((r) => r is Map && _sessionKeyForRecord(Map<String, dynamic>.from(r as Map)) == sessionKey)
          .toList();
    }

    final allWorkerSessions = _workerSessionsToday(worker);
    final workerIsCurrentlyIn = _isWorkerCurrentlyIn(allWorkerSessions);
    final currentSessionKey = _currentSessionKey();
    final sessionHasOpen = sessionKey != null && workerRecords.any((r) => r is Map && _isOpenSession(Map<String, dynamic>.from(r as Map)));
    final sessionCompleted = sessionKey != null && workerRecords.any((r) => r is Map && !_isOpenSession(Map<String, dynamic>.from(r as Map)) && r['check_in_time'] != null);

    // A worker can have several sessions on the same day. Use both the
    // collapsed daily row and the backend's nested per-session map.
    DateTime? latestCheckIn;
    DateTime? latestCheckOut;
    Map<String, dynamic>? latestRecord;

    void consider(Map<dynamic, dynamic> record) {
      final cin = _parseServerTime(record['check_in_time']);
      final cout = _parseServerTime(record['check_out_time']);

      if (cin != null &&
          (latestCheckIn == null || cin.isAfter(latestCheckIn!))) {
        latestCheckIn = cin;
        latestRecord = Map<String, dynamic>.from(record);
      }
      if (cout != null &&
          (latestCheckOut == null || cout.isAfter(latestCheckOut!))) {
        latestCheckOut = cout;
        latestRecord ??= Map<String, dynamic>.from(record);
      }
    }

    for (final raw in workerRecords) {
      if (raw is! Map) continue;
      consider(raw);

      final nested = raw['sessions'];
      if (nested is Map) {
        for (final value in nested.values) {
          if (value is Map) consider(value);
        }
      }
    }

    // Currently in only when the newest check-in is newer than the newest
    // checkout. A completed latest session therefore renders CHECK IN.
    final isIn = workerIsCurrentlyIn;
    final workerRecord = latestRecord;
        // Calculate monthly hours from backend records
    final workerId = int.tryParse(worker.id) ?? 0;
    final monthlyHours = _calculateWorkerMonthlyHours(workerId);
    final predictedSalary = worker.salary > 0 ? (monthlyHours / 200.0) * worker.salary : 0.0;
    final isLateToday = workerRecord != null && _isLateCheckIn(workerRecord);
    final isCurrentSession = sessionKey == null || sessionKey == currentSessionKey;
    final canChange = sessionKey == null ||
        (workerIsCurrentlyIn && sessionHasOpen) ||
        (!workerIsCurrentlyIn && isCurrentSession && !sessionCompleted);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4)]
      ),
      child: Column(
        children: [
          ListTile(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => WorkerAttendanceDetailPage(worker: worker)),
            ),
            leading: CircleAvatar(
              backgroundColor: _primary.withValues(alpha: 0.1),
              child: Text(worker.name[0], style: TextStyle(color: _primary, fontWeight: FontWeight.bold)),
            ),
            title: Text(worker.name, style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Row(children: [
              Flexible(
                child: Text('${worker.position} • $monthlyHours hrs this month',
                    style: const TextStyle(fontSize: 11, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (isLateToday) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                  child: const Text('LATE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.orange)),
                ),
              ],
            ]),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 92,
                  child: ElevatedButton(
                    onPressed: canChange
                        ? () async {
                            final verified = await _showVerifyPinDialog(worker);
                            if (verified) {
                              await _markWorkerAttendance(worker, isIn);
                            }
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isIn ? _absent : (sessionCompleted ? Colors.grey.shade300 : _present),
                      foregroundColor: isIn || !sessionCompleted ? Colors.white : Colors.grey.shade700,
                      disabledBackgroundColor: Colors.grey.shade100,
                      disabledForegroundColor: Colors.grey.shade500,
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      minimumSize: const Size(82, 32),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      elevation: 0,
                    ),
                    child: Text(
                      isIn ? 'CHECK OUT' : (sessionCompleted ? 'DONE' : 'CHECK IN'),
                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Reset attendance PIN',
                  onPressed: () async {
                    final changed = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WorkerPinResetPage(worker: worker),
                      ),
                    );
                    if (changed == true && mounted) {
                      await _loadStaff();
                      await _fetch();
                    }
                  },
                  icon: const Icon(Icons.key_rounded, size: 20),
                  color: _primary,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
                ),
              ],
            ),
          ),
          if (worker.salary > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Predicted Salary:', style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey)),
                  Text('₹${predictedSalary.toStringAsFixed(2)}', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.bold, color: _primary)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyAttendance() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10)]),
      child: Column(children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withValues(alpha: 0.1),
              shape: BoxShape.circle),
            child: const Icon(Icons.fingerprint, size: 44, color: Color(0xFF6366F1)),
        ),
        const SizedBox(height: 16),
        Text("Not checked in yet", style: GoogleFonts.poppins(
            fontWeight: FontWeight.w700, fontSize: 16)),
        Text("Tap the Check In button below to mark attendance",
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 13, color: Colors.grey)),
      ]),
    );
  }

  Widget _statusCard(Map<String, dynamic> rec, bool ci, bool co) {
    final status = co
        ? 'PRESENT'
        : (ci ? 'IN PROGRESS' : rec['status'] ?? 'PENDING');
    final color = status == 'PRESENT'
        ? _present
        : (status == 'IN PROGRESS' ? Colors.orange : Colors.grey);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        CircleAvatar(backgroundColor: color, radius: 24,
            child: Icon(
                status == 'PRESENT' ? Icons.check : Icons.access_time,
                color: Colors.white)),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(AppLocalizations.of(context).todayStatus, style: GoogleFonts.poppins(
              fontSize: 12, color: Colors.grey.shade600)),
          Text(status, style: GoogleFonts.poppins(
              fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        ]),
      ]),
    );
  }

  Widget _timeCard(String label, dynamic time, IconData icon, Color color) {
    String t = '--:--';
    final parsed = _parseServerTime(time);
    if (time != null) {
      t = parsed != null ? DateFormat.jm().format(parsed) : 'N/A';
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(
              color: Colors.black.withValues(alpha: 0.05), blurRadius: 6)]),
      child: Column(children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 8),
        Text(label, style: GoogleFonts.poppins(
            fontSize: 11, color: Colors.grey.shade500)),
        Text(t, style: GoogleFonts.poppins(
            fontSize: 16, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }

  Widget _hoursCard(String hours, {bool isLive = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: isLive 
                  ? [const Color(0xFF10B981), const Color(0xFF059669)]
                  : [const Color(0xFF6366F1), const Color(0xFF8B5CF6)]),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: (isLive ? const Color(0xFF10B981) : const Color(0xFF6366F1)).withValues(alpha: 0.3),
              blurRadius: 8, offset: const Offset(0, 4)
            )
          ]),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(children: [
              if (isLive) ...[
                const SizedBox(
                  width: 8, height: 8,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                ),
                const SizedBox(width: 10),
              ],
              Text(isLive ? 'Live Working Hours' : 'Working Hours', style: GoogleFonts.poppins(
                  color: Colors.white70, fontSize: 13)),
            ]),
            Text('$hours hrs', style: GoogleFonts.poppins(
                color: Colors.white, fontSize: 20,
                fontWeight: FontWeight.w700)),
          ]),
    );
  }

  Widget _guide(String text, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Container(width: 36, height: 36,
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: color)),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: GoogleFonts.poppins(
            fontSize: 13, color: Colors.grey.shade700))),
      ]),
    );
  }

  Widget _historyTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_records.isEmpty) return Center(
        child: Text('No attendance records', style: GoogleFonts.poppins()));
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _records.length,
      itemBuilder: (_, i) {
        final r = _records[i];
        final st = r['status'] as String? ?? 'N/A';
        final color = st == 'PRESENT' ? _present
            : (st == 'HALF_DAY' ? Colors.orange : _absent);
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)]),
          child: Row(children: [
            Container(width: 40, height: 40,
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
                child: Icon(
                    st == 'PRESENT' ? Icons.check_circle_outline : Icons.cancel_outlined,
                    color: color, size: 22)),
            const SizedBox(width: 12),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['attendance_date'] ?? '', style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w600, fontSize: 13)),
              if (r['check_in_time'] != null)
                Text('In: ${DateFormat.jm().format(DateTime.tryParse(r['check_in_time']) ?? DateTime.now())}',
                    style: GoogleFonts.poppins(
                        fontSize: 11, color: Colors.grey.shade500)),
            ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: Text(st, style: GoogleFonts.poppins(
                    fontSize: 10, fontWeight: FontWeight.bold, color: color)),
              ),
              if (_isLateCheckIn(r))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('LATE', style: GoogleFonts.poppins(
                      fontSize: 9, fontWeight: FontWeight.bold, color: Colors.orange.shade700)),
                ),
            ]),
          ]),
        );
      },
    );
  }

  Widget _payrollTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_staff.isEmpty) {
      return Center(
          child: Text('Add staff to see payroll summaries', style: GoogleFonts.poppins(color: Colors.grey.shade600)));
    }

    double totalPayroll = 0;
    final rows = _staff.map((w) {
      final workerId = int.tryParse(w.id) ?? 0;
      final hours = _calculateWorkerMonthlyHours(workerId);
      final rate = w.salary > 0 ? w.salary / 200.0 : 0.0;
      final amount = hours * rate;
      totalPayroll += amount;
      return (worker: w, hours: hours, rate: rate, amount: amount);
    }).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Total Payroll · ${DateFormat('MMMM').format(DateTime.now())}',
                style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13)),
            Text('₹${totalPayroll.toStringAsFixed(0)}',
                style: GoogleFonts.poppins(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(height: 16),
        ...rows.map((r) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)],
              ),
              child: InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => WorkerAttendanceDetailPage(worker: r.worker)),
                ),
                child: Row(children: [
                  CircleAvatar(
                    backgroundColor: _primary.withValues(alpha: 0.1),
                    child: Text(r.worker.name[0], style: TextStyle(color: _primary, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(r.worker.name, style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14)),
                      Text('${r.hours.toStringAsFixed(1)} hrs × ₹${r.rate.toStringAsFixed(2)}/hr',
                          style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade500)),
                    ]),
                  ),
                  Text('₹${r.amount.toStringAsFixed(0)}',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w800, fontSize: 15, color: _primary)),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, color: Colors.grey.shade400),
                ]),
              ),
            )),
      ],
    );
  }

  Widget _buildLanguageSwitcher() {
    final langProvider = Provider.of<LanguageProvider>(context);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.language, color: Colors.white, size: 24),
      tooltip: 'Change Language',
      onSelected: (code) => langProvider.setLanguage(code),
      itemBuilder: (context) => LanguageProvider.languages.map((l) {
        return PopupMenuItem<String>(
          value: l['code'],
          child: Text('${l['nativeName']} (${l['name']})'),
        );
      }).toList(),
    );
  }

  Future<void> _markWorkerAttendance(Worker worker, bool isCurrentlyIn) async {
    try {
      if (isCurrentlyIn) {
        final workerId = int.tryParse(worker.id.toString());
        if (workerId == null || workerId <= 0) {
          throw StateError('Invalid worker ID: ${worker.id}');
        }
        await OfflineAttendanceService.checkOut(
          employeeId: workerId,
          workerId: workerId,
        );

        // The checkout is written to the durable local outbox first. Trigger
        // the canonical sync immediately so an online device does not wait
        // for the background timer to reach /api/attendance/check-out.
        try {
          await SyncService.processQueueSafe();
        } catch (syncError) {
          if (kDebugMode) {
            debugPrint('⚠️ Immediate attendance checkout sync deferred: $syncError');
          }
        }

        _showSnack(
          '✅ ${worker.name} checked out',
          _primary,
        );
      } else {
        final workerId = int.tryParse(worker.id.toString());
        if (workerId == null || workerId <= 0) {
          throw StateError('Invalid worker ID: ${worker.id}');
        }
        await OfflineAttendanceService.checkIn(
          employeeId: workerId,
          workerId: workerId,
        );

        // Flush the durable attendance outbox immediately after check-in too.
        // Previously only worker checkout triggered an immediate flush, so an
        // online check-in could remain local until the background sync ran.
        try {
          await SyncService.processQueueSafe();
        } catch (syncError) {
          if (kDebugMode) {
            debugPrint('⚠️ Immediate attendance check-in sync deferred: $syncError');
          }
        }

        _showSnack('✅ ${worker.name} checked in — saved locally and queued for sync', _present);
      }
      await _fetch();
    } catch (e) {
      _showSnack('❌ Attendance could not be saved: $e', _absent);
    }
  }

  Future<bool> _showVerifyPinDialog(Worker worker) async {
    final controller = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Enter PIN for ${worker.name}', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Please enter your 4-digit attendance PIN to verify identity.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 4,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 24, letterSpacing: 10, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                counterText: '',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: _primary.withValues(alpha: 0.05),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () {
              if (controller.text == worker.pin) {
                Navigator.pop(ctx, true);
              } else {
                _showSnack('❌ Invalid PIN. Please try again.', _absent);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
            child: const Text('VERIFY'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
