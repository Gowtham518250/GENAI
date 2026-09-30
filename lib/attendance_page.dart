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
  bool _marking = false;
  List<dynamic> _records = [];
  Map<String, dynamic>? _todaySummary;
  int? _userId;
  late TabController _tab;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
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
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _init();
    _startTimer();
    _startRefreshTimer();
  }

  @override
  void dispose() {
    _tab.dispose();
    _pulseController.dispose();
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

  /// Backend sends naive timestamps with no timezone suffix (e.g.
  /// "2026-07-28T04:15:00"), which are actually UTC. DateTime.parse would
  /// otherwise treat that string as *local* time, which is wrong by our
  /// UTC offset. This normalizes any server timestamp to local time
  /// consistently, whether or not it carries a timezone suffix already.
  DateTime? _parseServerTime(dynamic raw) {
    if (raw == null) return null;
    final str = raw.toString();
    DateTime? t = DateTime.tryParse(str);
    if (t == null) return null;
    if (!str.contains('+') && !str.endsWith('Z')) {
      t = DateTime.parse('${str}Z');
    }
    return t.toLocal();
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
    final total = r['total_working_hours'];
    if (total is num) return total.toDouble();

    final sessionHours = r['working_hours'];
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

  Future<void> _checkInOut() async {
    if (_userId == null) {
      _showSnack('⚠️ User ID not found. Please login again.', _absent);
      return;
    }
    setState(() => _marking = true);

    try {
      // _mySession is refreshed straight from OfflineAttendanceService after
      // every fetch/check-in/check-out, so it's always the current truth —
      // no risk of reading a stale collapsed record from `_records`.
      if (_mySession == null) {
        await OfflineAttendanceService.checkIn(employeeId: _userId!);
        final sessions = await OfflineAttendanceService.todaySessions(employeeId: _userId!);
        _showSnack('✅ Session ${sessions.length} started — checked in', _present);
      } else {
        final sessionNo = _sessionIndex(_mySession!) + 1;
        await OfflineAttendanceService.checkOut(employeeId: _userId!);
        _showSnack(
          '👋 Session $sessionNo ended — checked out. Start another session anytime.',
          _primary,
        );
      }

      await _fetch();
    } catch (e) {
      _showSnack('❌ Attendance could not be saved safely: $e', _absent);
    } finally {
      if (mounted) setState(() => _marking = false);
    }
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
      floatingActionButton: ScaleTransition(
        scale: _pulseAnimation,
        child: FloatingActionButton.extended(
          onPressed: _marking ? null : _checkInOut,
          backgroundColor: btnColor,
          foregroundColor: Colors.white,
          elevation: 4,
          icon: _marking
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Icon(btnIcon),
          label: Text(btnLabel,
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        ),
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
          const SizedBox(height: 12),
          ..._staff.map((worker) => _workerAttendanceTile(worker)),
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

  Widget _workerAttendanceTile(Worker worker) {
    // Check today's attendance from backend records using worker_id
    final today = _df.format(DateTime.now());
    final workerRecords = _records.where((r) {
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

    // A worker can have several sessions on the same day. Do NOT use
    // "any open row" as the current state: the backend stores a daily row
    // plus session metadata, and a stale open-looking row can coexist with
    // a newer completed checkout. Determine the current state from the
    // latest check-in/check-out event instead.
    DateTime? latestCheckIn;
    DateTime? latestCheckOut;
    Map<String, dynamic>? latestRecord;

    DateTime? eventTime(dynamic value) => _parseServerTime(value);

    for (final raw in workerRecords) {
      if (raw is! Map) continue;
      final record = Map<String, dynamic>.from(raw);
      final cin = eventTime(record['check_in_time']);
      final cout = eventTime(record['check_out_time']);

      if (cin != null && (latestCheckIn == null || cin.isAfter(latestCheckIn!))) {
        latestCheckIn = cin;
        latestRecord = record;
      }
      if (cout != null && (latestCheckOut == null || cout.isAfter(latestCheckOut!))) {
        latestCheckOut = cout;
        latestRecord = record;
      }
    }

    // Checked in only when the latest check-in happened after the latest
    // checkout (or there has never been a checkout).
    final isIn = latestCheckIn != null &&
        (latestCheckOut == null || latestCheckIn.isAfter(latestCheckOut));
    final workerRecord = latestRecord;
    
    // Calculate monthly hours from backend records
    final workerId = int.tryParse(worker.id) ?? 0;
    final monthlyHours = _calculateWorkerMonthlyHours(workerId);
    final predictedSalary = worker.salary > 0 ? (monthlyHours / 200.0) * worker.salary : 0.0;
    final isLateToday = workerRecord != null && _isLateCheckIn(workerRecord);

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
            trailing: SizedBox(
              width: 100,
              child: ElevatedButton(
                onPressed: () async {
                  final verified = await _showVerifyPinDialog(worker);
                  if (verified) {
                    await _markWorkerAttendance(worker, isIn);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isIn ? _absent : _present,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(80, 32),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                child: Text(
                  isIn ? 'CHECK OUT' : 'CHECK IN',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
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
        _showSnack('✅ ${worker.name} checked in — saved offline and queued', _present);
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