import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'models.dart';
import 'payment_history_storage.dart';

/// Full attendance detail for a single worker:
/// - Monthly calendar (present / absent / half-day)
/// - Attendance % + a simple daily-hours trend
/// - Late check-in / early check-out flags
/// - Payroll summary (hours × rate) for the month, minus payments already made
class WorkerAttendanceDetailPage extends StatefulWidget {
  final Worker worker;
  const WorkerAttendanceDetailPage({super.key, required this.worker});

  @override
  State<WorkerAttendanceDetailPage> createState() =>
      _WorkerAttendanceDetailPageState();
}

class _WorkerAttendanceDetailPageState
    extends State<WorkerAttendanceDetailPage> {
  static const Color _primary = Color(0xFF6366F1);
  static const Color _present = Color(0xFF10B981);
  static const Color _absent = Color(0xFFEF4444);
  static const Color _half = Color(0xFFF59E0B);

  // Configurable shift window used to flag late arrivals / early departures.
  static const TimeOfDay _shiftStart = TimeOfDay(hour: 9, minute: 30);
  static const TimeOfDay _shiftEnd = TimeOfDay(hour: 18, minute: 30);
  static const int _graceMinutes = 15;

  bool _loading = true;
  List<dynamic> _records = [];
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  int? _shopkeeperId;
  List<WorkerPayment> _payments = [];

  int get _workerId => int.tryParse(widget.worker.id) ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _attendanceCacheKey(int workerId) =>
      'attendance_worker_cache_$workerId';

  Future<List<dynamic>> _loadLocalAttendance() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_attendanceCacheKey(_workerId));
    if (raw == null || raw.isEmpty) return <dynamic>[];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? List<dynamic>.from(decoded) : <dynamic>[];
    } catch (_) {
      return <dynamic>[];
    }
  }

  Future<void> _saveLocalAttendance(List<dynamic> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _attendanceCacheKey(_workerId),
      jsonEncode(records),
    );
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      _shopkeeperId = prefs.getInt('user_id') ?? prefs.getInt('userId');

      // LOCAL-FIRST: payroll and attendance remain visible after page
      // recreation or temporary backend/network failure.
      final cachedRecords = await _loadLocalAttendance();
      if (cachedRecords.isNotEmpty && mounted) {
        setState(() => _records = cachedRecords);
      }

      // BACKEND REFRESH: successful response replaces the local snapshot.
      try {
        final res = await ApiClient.getJson(
          '${ApiClient.attendancePrefix}/employee/${widget.worker.id}',
        );

        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final records = data is Map && data['records'] is List
              ? List<dynamic>.from(data['records'] as List)
              : data is List
                  ? List<dynamic>.from(data)
                  : <dynamic>[];

          await _saveLocalAttendance(records);

          if (mounted) {
            setState(() => _records = records);
          }
        }
      } catch (e) {
        // Keep cached records when the backend is temporarily unavailable.
        debugPrint('⚠️ Worker attendance backend refresh failed: $e');
      }

      if (_shopkeeperId != null) {
        final workerId = int.tryParse(widget.worker.id) ?? 0;
        _payments = await PaymentHistoryStorage.fetchForWorker(
          _shopkeeperId!,
          workerId,
        );
      }
    } catch (e) {
      debugPrint('⚠️ Worker attendance local load failed: $e');
    }

    if (mounted) setState(() => _loading = false);
  }

  // ---- Data helpers ----------------------------------------------------

  Map<String, Map<String, dynamic>> _sessionsFor(
    Map<String, dynamic> record,
  ) {
    final raw = record['sessions'];
    if (raw is Map) {
      final out = <String, Map<String, dynamic>>{};
      for (final entry in raw.entries) {
        if (entry.value is Map) {
          out[entry.key.toString()] =
              Map<String, dynamic>.from(entry.value as Map);
        }
      }
      if (out.isNotEmpty) return out;
    }

    final hasSession =
        record['check_in_time'] != null ||
        record['check_out_time'] != null ||
        record['working_hours'] != null;
    if (!hasSession) return <String, Map<String, dynamic>>{};

    return {
      'session': <String, dynamic>{
        'label': 'Attendance Session',
        'check_in_time': record['check_in_time'],
        'check_out_time': record['check_out_time'],
        'working_hours': _hoursOf(record),
      },
    };
  }

  int _sessionCount(Map<String, dynamic> record) {
    return _sessionsFor(record).values.where((session) {
      return session['check_in_time'] != null ||
          session['check_out_time'] != null ||
          ((session['working_hours'] is num) &&
              (session['working_hours'] as num).toDouble() > 0);
    }).length;
  }

  String _dayAttendanceStatus(Map<String, dynamic> record) {
    final count = _sessionCount(record);
    if (count >= 2) return 'PRESENT';
    if (count == 1) return 'HALF_DAY';
    return 'ABSENT';
  }

  Color _dayStatusColor(Map<String, dynamic> record) {
    switch (_dayAttendanceStatus(record)) {
      case 'PRESENT':
        return _present;
      case 'HALF_DAY':
        return _half;
      default:
        return _absent;
    }
  }

  String _dayStatusLabel(Map<String, dynamic> record) {
    final count = _sessionCount(record);
    if (count >= 2) return 'Present • 2 sessions';
    if (count == 1) return 'Partial • 1 session';
    return 'Absent / no session';
  }

  Map<String, dynamic>? _recordFor(DateTime day) {
    final target = DateFormat('yyyy-MM-dd').format(day);
    for (final r in _records) {
      final recDate = (r['attendance_date'] ?? '').toString().split('T').first.trim();
      if (recDate == target) return Map<String, dynamic>.from(r as Map);
    }
    return null;
  }

  List<Map<String, dynamic>> _recordsInMonth(DateTime month) {
    return _records.where((r) {
      final d = DateTime.tryParse((r['attendance_date'] ?? '').toString());
      return d != null && d.year == month.year && d.month == month.month;
    }).map((r) => Map<String, dynamic>.from(r as Map)).toList();
  }

  double _hoursOf(Map<String, dynamic> r) {
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
      return cout.difference(cin).inMinutes / 60.0;
    }
    if (cin != null && r['check_out_time'] == null) {
      return DateTime.now().difference(cin).inSeconds / 3600.0;
    }
    return 0.0;
  }

  /// Backend sends naive timestamps with no timezone suffix, which are
  /// actually UTC. DateTime.parse would otherwise read that string as
  /// *local* time, throwing Late/Early flags off by the UTC offset. This
  /// mirrors the normalization used on the main Attendance page so both
  /// screens agree on what "late" means.
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

  bool _isLate(Map<String, dynamic> r) {
    final local = _parseServerTime(r['check_in_time']);
    if (local == null) return false;
    final threshold = DateTime(local.year, local.month, local.day,
        _shiftStart.hour, _shiftStart.minute + _graceMinutes);
    return local.isAfter(threshold);
  }

  bool _isEarly(Map<String, dynamic> r) {
    final local = _parseServerTime(r['check_out_time']);
    if (local == null) return false;
    final threshold = DateTime(local.year, local.month, local.day,
        _shiftEnd.hour, _shiftEnd.minute - _graceMinutes);
    return local.isBefore(threshold);
  }

  /// Attendance % for the selected month, counting elapsed days only
  /// (or all days if the month is fully in the past).
  double _attendancePercent(DateTime month) {
    final recs = _recordsInMonth(month);
    if (recs.isEmpty) return 0;
    final now = DateTime.now();
    final isCurrentMonth = month.year == now.year && month.month == now.month;
    final daysElapsed = isCurrentMonth
        ? now.day
        : DateTime(month.year, month.month + 1, 0).day;

    double score = 0;
    for (final r in recs) {
      final st = _dayAttendanceStatus(r);
      if (st == 'PRESENT') {
        score += 1;
      } else if (st == 'HALF_DAY') {
        score += 0.5;
      }
    }
    return daysElapsed == 0 ? 0 : (score / daysElapsed) * 100;
  }

  double _monthlyHours(DateTime month) {
    return _recordsInMonth(month).fold<double>(0, (sum, r) => sum + _hoursOf(r));
  }

  // ---- Performance insights --------------------------------------------

  DateTime get _prevMonth => DateTime(_month.year, _month.month - 1);

  /// % of check-ins that were on time (i.e. not late) this month.
  /// Null when there's no check-in data yet for the month, so the UI can
  /// show "—" instead of a misleading 100%.
  double? _punctualityScore(DateTime month) {
    final recs = _recordsInMonth(month).where((r) => r['check_in_time'] != null).toList();
    if (recs.isEmpty) return null;
    final onTime = recs.where((r) => !_isLate(r)).length;
    return (onTime / recs.length) * 100;
  }

  /// Distinct calendar dates (across all history) marked PRESENT or
  /// HALF_DAY, sorted oldest to newest.
  List<DateTime> _presentDatesSorted() {
    final dates = _records
        .where((r) {
          final st = (r['status'] ?? '').toString().trim().toUpperCase();
          return st == 'PRESENT' || st == 'HALF_DAY';
        })
        .map((r) => DateTime.tryParse((r['attendance_date'] ?? '').toString().split('T').first))
        .whereType<DateTime>()
        .toSet()
        .toList()
      ..sort();
    return dates;
  }

  /// How many consecutive days (ending today or yesterday) the worker has
  /// been present. Resets to 0 if the most recent present day is further
  /// back than yesterday, since that's not a "current" streak anymore.
  int _currentStreak() {
    final dates = _presentDatesSorted();
    if (dates.isEmpty) return 0;
    final gapToToday = DateTime.now().difference(dates.last).inDays;
    if (gapToToday > 1) return 0;
    int streak = 1;
    for (var i = dates.length - 1; i > 0; i--) {
      if (dates[i].difference(dates[i - 1]).inDays == 1) {
        streak++;
      } else {
        break;
      }
    }
    return streak;
  }

  /// Longest run of consecutive present days within the given month.
  int _bestStreakInMonth(DateTime month) {
    final dates = _presentDatesSorted().where((d) => d.year == month.year && d.month == month.month).toList();
    if (dates.isEmpty) return 0;
    int best = 1, cur = 1;
    for (var i = 1; i < dates.length; i++) {
      if (dates[i].difference(dates[i - 1]).inDays == 1) {
        cur++;
        if (cur > best) best = cur;
      } else {
        cur = 1;
      }
    }
    return best;
  }

  /// Change vs the previous month. hasPrevData is false when the previous
  /// month has no records at all, so the UI can say "no data" instead of
  /// implying a 0% attendance drop that never really happened.
  ({double pctDelta, double hrsDelta, bool hasPrevData}) _monthOverMonth() {
    final hasPrev = _recordsInMonth(_prevMonth).isNotEmpty;
    final pctDelta = _attendancePercent(_month) - (hasPrev ? _attendancePercent(_prevMonth) : 0);
    final hrsDelta = _monthlyHours(_month) - (hasPrev ? _monthlyHours(_prevMonth) : 0);
    return (pctDelta: pctDelta, hrsDelta: hrsDelta, hasPrevData: hasPrev);
  }

  double get _hourlyRate =>
      widget.worker.salary > 0 ? widget.worker.salary / 200.0 : 0.0;

  double _paidThisMonth() {
    final now = DateTime.now();
    return _payments
        .where((p) => p.date.year == _month.year && p.date.month == _month.month)
        .fold<double>(0, (sum, p) => sum + p.amount);
  }

  // ---- UI ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final w = widget.worker;
    final monthHours = _monthlyHours(_month);
    final payroll = monthHours * _hourlyRate;
    final paid = _paidThisMonth();
    final balance = payroll - paid;
    final pct = _attendancePercent(_month);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(w.name, style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _monthSwitcher(),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: _statTile('Attendance', '${pct.toStringAsFixed(0)}%', _present)),
                    const SizedBox(width: 10),
                    Expanded(child: _statTile('Hours', monthHours.toStringAsFixed(1), _primary)),
                    const SizedBox(width: 10),
                    Expanded(child: _statTile('Payroll', '₹${payroll.toStringAsFixed(0)}', _half)),
                  ]),
                  const SizedBox(height: 16),
                  _insightsCard(),
                  const SizedBox(height: 24),
                  Text('Calendar', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 12),
                  _calendar(),
                  const SizedBox(height: 12),
                  _legend(),
                  const SizedBox(height: 24),
                  Text('Daily Hours Trend', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 12),
                  _trendChart(),
                  const SizedBox(height: 24),
                  Text('Late / Early Check-ins', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 12),
                  _lateEarlyList(),
                  const SizedBox(height: 24),
                  Text('Payroll Summary', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 12),
                  _payrollCard(monthHours, payroll, paid, balance),
                  const SizedBox(height: 80),
                ]),
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _shopkeeperId == null ? null : _showAddPaymentDialog,
        backgroundColor: _primary,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Log Payment', style: TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _monthSwitcher() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6)],
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
        ),
        Text(DateFormat('MMMM yyyy').format(_month),
            style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 15)),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
        ),
      ]),
    );
  }

  Widget _statTile(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6)],
      ),
      child: Column(children: [
        Text(value, style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
        const SizedBox(height: 4),
        Text(label, style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade600)),
      ]),
    );
  }

  /// Compact analytics strip: punctuality, current streak, best streak this
  /// month, and how this month compares to last — everything derived from
  /// records already loaded, no extra API calls.
  Widget _insightsCard() {
    final punctuality = _punctualityScore(_month);
    final currentStreak = _currentStreak();
    final bestStreak = _bestStreakInMonth(_month);
    final mom = _monthOverMonth();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.indigo.withValues(alpha: 0.25), blurRadius: 16, offset: const Offset(0, 6))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PERFORMANCE INSIGHTS', style: GoogleFonts.poppins(
              fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.w700, color: Colors.white60)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _insightBlock(
                punctuality == null ? '—' : '${punctuality.toStringAsFixed(0)}%',
                'Punctuality', Icons.punch_clock_rounded)),
            Container(width: 1, height: 40, color: Colors.white24),
            Expanded(child: _insightBlock('$currentStreak', 'Day Streak', Icons.local_fire_department_rounded)),
            Container(width: 1, height: 40, color: Colors.white24),
            Expanded(child: _insightBlock('$bestStreak', 'Best Streak', Icons.emoji_events_rounded)),
          ]),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
            child: mom.hasPrevData
                ? Row(children: [
                    Icon(mom.pctDelta >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                        color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'vs last month: ${mom.pctDelta >= 0 ? '+' : ''}${mom.pctDelta.toStringAsFixed(0)}% attendance'
                        ' • ${mom.hrsDelta >= 0 ? '+' : ''}${mom.hrsDelta.toStringAsFixed(1)} hrs',
                        style: GoogleFonts.poppins(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ])
                : Row(children: [
                    const Icon(Icons.info_outline_rounded, color: Colors.white70, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('No data for ${DateFormat('MMMM').format(_prevMonth)} to compare against yet',
                          style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12)),
                    ),
                  ]),
          ),
        ],
      ),
    );
  }

  Widget _insightBlock(String value, String label, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Colors.white70, size: 18),
        const SizedBox(height: 6),
        Text(value, style: GoogleFonts.poppins(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
        Text(label, style: GoogleFonts.poppins(color: Colors.white60, fontSize: 10)),
      ],
    );
  }

  Widget _calendar() {
    final firstDay = DateTime(_month.year, _month.month, 1);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leadingBlanks = firstDay.weekday % 7;

    final cells = <Widget>[];
    for (var i = 0; i < leadingBlanks; i++) {
      cells.add(const SizedBox());
    }

    for (var d = 1; d <= daysInMonth; d++) {
      final day = DateTime(_month.year, _month.month, d);
      final rec = _recordFor(day);
      final isFuture = day.isAfter(DateTime.now());

      Color color = Colors.grey.shade200;
      Color textColor = Colors.grey.shade500;

      if (rec != null) {
        color = _dayStatusColor(rec);
        textColor = Colors.white;
      } else if (!isFuture) {
        color = _absent.withValues(alpha: 0.15);
        textColor = _absent;
      }

      cells.add(
        GestureDetector(
          onTap: rec == null ? null : () => _showDayDetail(day, rec),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(9),
              boxShadow: rec != null
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.18),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$d',
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
                if (rec != null && _sessionCount(rec) == 1)
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.more_horiz_rounded,
                      size: 11,
                      color: Colors.white70,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: ['S', 'M', 'T', 'W', 'T', 'F', 'S']
                .map(
                  (d) => Expanded(
                    child: Center(
                      child: Text(
                        d,
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1,
            children: cells,
          ),
        ],
      ),
    );
  }

  Widget _legend() {
    Widget dot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade600)),
        ]);
    return Wrap(spacing: 16, runSpacing: 8, children: [
      dot(_present, 'Present'),
      dot(_half, 'Half day'),
      dot(_absent, 'Absent / no record'),
    ]);
  }

  Widget _trendChart() {
    final recs = _recordsInMonth(_month)
      ..sort((a, b) => (a['attendance_date'] ?? '').toString().compareTo((b['attendance_date'] ?? '').toString()));
    if (recs.isEmpty) {
      return _emptyCard('No records yet this month');
    }
    final maxHours = recs.map(_hoursOf).fold<double>(1, (m, v) => v > m ? v : m);
    return Container(
      height: 130,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: recs.map((r) {
          final hours = _hoursOf(r);
          final h = maxHours == 0 ? 4.0 : (hours / maxHours) * 90;
          final day = DateTime.tryParse((r['attendance_date'] ?? '').toString());
          final late = _isLate(r);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(hours.toStringAsFixed(1), style: GoogleFonts.poppins(fontSize: 8, color: Colors.grey.shade500)),
                  const SizedBox(height: 2),
                  Container(
                    height: h.clamp(4, 90),
                    decoration: BoxDecoration(
                      color: late ? _absent : _primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(day != null ? '${day.day}' : '', style: GoogleFonts.poppins(fontSize: 8, color: Colors.grey.shade400)),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _lateEarlyList() {
    final recs = _recordsInMonth(_month).where((r) => _isLate(r) || _isEarly(r)).toList()
      ..sort((a, b) => (b['attendance_date'] ?? '').toString().compareTo((a['attendance_date'] ?? '').toString()));
    if (recs.isEmpty) {
      return _emptyCard('No late arrivals or early departures this month 🎉');
    }
    return Column(
      children: recs.map((r) {
        final late = _isLate(r);
        final early = _isEarly(r);
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)],
          ),
          child: Row(children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange.shade600, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${r['attendance_date']}: ${[
                  if (late) 'Late check-in',
                  if (early) 'Early check-out',
                ].join(' • ')}',
                style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        );
      }).toList(),
    );
  }

  Widget _payrollCard(double hours, double payroll, double paid, double balance) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _payrollRow('Hours worked', '${hours.toStringAsFixed(1)} hrs'),
        _payrollRow('Rate', '₹${_hourlyRate.toStringAsFixed(2)}/hr'),
        const Divider(color: Colors.white24, height: 20),
        _payrollRow('Earned this month', '₹${payroll.toStringAsFixed(2)}', bold: true),
        _payrollRow('Already paid', '₹${paid.toStringAsFixed(2)}'),
        const Divider(color: Colors.white24, height: 20),
        _payrollRow(balance >= 0 ? 'Balance due' : 'Overpaid', '₹${balance.abs().toStringAsFixed(2)}', bold: true),
      ]),
    );
  }

  Widget _payrollRow(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13)),
        Text(value, style: GoogleFonts.poppins(
            color: Colors.white, fontSize: bold ? 16 : 13, fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
      ]),
    );
  }

  Widget _emptyCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
      ),
      child: Text(text, textAlign: TextAlign.center, style: GoogleFonts.poppins(color: Colors.grey.shade500, fontSize: 12)),
    );
  }

  void _showDayDetail(DateTime day, Map<String, dynamic> rec) {
    final sessions = _sessionsFor(rec);
    final ordered = sessions.entries.toList()
      ..sort((a, b) {
        final aIn = _parseServerTime(a.value['check_in_time']);
        final bIn = _parseServerTime(b.value['check_in_time']);
        if (aIn == null && bIn == null) return 0;
        if (aIn == null) return 1;
        if (bIn == null) return -1;
        return aIn.compareTo(bIn);
      });

    final totalHours = ordered.fold<double>(
      0,
      (sum, entry) {
        final value = entry.value['working_hours'];
        if (value is num) return sum + value.toDouble();
        return sum;
      },
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Color(0xFFE5E7EB),
                        borderRadius: BorderRadius.all(Radius.circular(99)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          DateFormat('EEEE, dd MMM yyyy').format(day),
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _dayStatusColor(rec).withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _dayStatusLabel(rec),
                          style: GoogleFonts.poppins(
                            color: _dayStatusColor(rec),
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Attendance sessions for this date',
                    style: GoogleFonts.poppins(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ...ordered.map((entry) {
                    final session = entry.value;
                    final label = (session['label'] ?? entry.key).toString();
                    final checkIn = _parseServerTime(session['check_in_time']);
                    final checkOut = _parseServerTime(session['check_out_time']);
                    final rawHours = session['working_hours'];
                    final hours = rawHours is num ? rawHours.toDouble() : 0.0;
                    final isOpen = session['check_in_time'] != null &&
                        session['check_out_time'] == null;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _primary.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: _primary.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.access_time_filled_rounded,
                                  size: 18,
                                  color: _primary,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  label,
                                  style: GoogleFonts.poppins(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              Text(
                                hours > 0
                                    ? '${hours.toStringAsFixed(2)} hrs'
                                    : (isOpen ? 'In progress' : '0.00 hrs'),
                                style: GoogleFonts.poppins(
                                  color: isOpen ? _half : _primary,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _sessionTimeTile(
                                  icon: Icons.login_rounded,
                                  label: 'Check-in',
                                  value: checkIn == null
                                      ? 'Not recorded'
                                      : _fmtTime(checkIn.toIso8601String()),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _sessionTimeTile(
                                  icon: Icons.logout_rounded,
                                  label: 'Check-out',
                                  value: checkOut == null
                                      ? (isOpen ? 'Still active' : 'Not recorded')
                                      : _fmtTime(checkOut.toIso8601String()),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.schedule_rounded, color: Color(0xFF6366F1), size: 19),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Total worked hours',
                            style: GoogleFonts.poppins(
                              color: Colors.grey.shade700,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${totalHours.toStringAsFixed(2)} hrs',
                          style: GoogleFonts.poppins(
                            color: Colors.black87,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Record date: ${((rec['attendance_date'] ?? '').toString().split('T').first)}',
                    style: GoogleFonts.poppins(
                      color: Colors.grey.shade500,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sessionTimeTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: _primary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: GoogleFonts.poppins(color: Colors.grey.shade500, fontSize: 9)),
                const SizedBox(height: 2),
                Text(value, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(color: Colors.black87, fontSize: 11, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(String iso) {
    final t = _parseServerTime(iso);
    return t != null ? DateFormat.jm().format(t) : iso;
  }

  void _showAddPaymentDialog() {
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    String type = 'Salary';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (context, setModalState) {
        return AlertDialog(
          title: Text('Log Payment for ${widget.worker.name}', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Amount (₹)', prefixIcon: Icon(Icons.currency_rupee)),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: type,
              items: ['Salary', 'Advance', 'Bonus', 'Other']
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (v) => setModalState(() => type = v ?? 'Salary'),
              decoration: const InputDecoration(labelText: 'Type'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(labelText: 'Note (optional)', prefixIcon: Icon(Icons.note_alt_outlined)),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final amt = double.tryParse(amountCtrl.text.trim());
                if (amt == null || amt <= 0 || _shopkeeperId == null) return;
                final workerId = int.tryParse(widget.worker.id) ?? 0;
                await PaymentHistoryStorage.addPayment(
                  _shopkeeperId!,
                  WorkerPayment(
                    id: DateTime.now().microsecondsSinceEpoch.toString(),
                    workerId: workerId,
                    amount: amt,
                    note: noteCtrl.text.trim(),
                    type: type,
                    date: DateTime.now(),
                  ),
                );
                if (context.mounted) Navigator.pop(ctx);
                await _load();
              },
              style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
              child: const Text('Save'),
            ),
          ],
        );
      }),
    );
  }
}