import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/attendance_time_parser.dart';

void main() {
  group('AttendanceTimeParser', () {
    test('returns null for missing or invalid timestamps', () {
      expect(AttendanceTimeParser.parseServerTime(null), isNull);
      expect(AttendanceTimeParser.parseServerTime(' '), isNull);
      expect(AttendanceTimeParser.parseServerTime('not-a-date'), isNull);
    });

    test('preserves legacy timezone-naive timestamps', () {
      const value = '2026-10-15T09:45:00';
      expect(
        AttendanceTimeParser.parseServerTime(value),
        DateTime.parse(value),
      );
    });

    test('accepts timestamps with a numeric timezone offset', () {
      const value = '2026-10-15T09:45:00+05:30';
      expect(
        AttendanceTimeParser.parseServerTime(value),
        DateTime.parse(value).toLocal(),
      );
    });

    test('accepts UTC timestamps', () {
      const value = '2026-10-15T04:15:00Z';
      expect(
        AttendanceTimeParser.parseServerTime(value),
        DateTime.parse(value).toLocal(),
      );
    });
  });
}
