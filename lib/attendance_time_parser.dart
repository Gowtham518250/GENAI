/// Parses attendance timestamps returned by the backend.
///
/// Older API records can contain a timezone-naive Asia/Kolkata wall time;
/// preserve that value as local time. Timestamps with an explicit UTC or
/// numeric offset are parsed and converted to the device's local timezone.
class AttendanceTimeParser {
  static DateTime? parseServerTime(dynamic raw) {
    if (raw == null) return null;

    final value = raw.toString().trim();
    if (value.isEmpty) return null;

    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;

    final hasExplicitZone =
        RegExp(r'(?:[zZ]|[+-]\d{2}:\d{2})$').hasMatch(value);
    return hasExplicitZone ? parsed.toLocal() : parsed;
  }
}
