import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/screens/attendance_screen.dart';

/// 手直し3: 今日を開いているときだけ「当日出席管理」、それ以外の日は「出席管理」
void main() {
  final now = DateTime(2026, 11, 22, 15, 30);

  test('今日（時刻が違っても同じ日）は「当日出席管理」', () {
    expect(attendanceTitleFor(DateTime(2026, 11, 22), now), '当日出席管理');
    expect(attendanceTitleFor(DateTime(2026, 11, 22, 23, 59), now), '当日出席管理');
  });

  test('昨日・明日・別の月の同じ日・別の年の同じ日は「出席管理」', () {
    expect(attendanceTitleFor(DateTime(2026, 11, 21), now), '出席管理');
    expect(attendanceTitleFor(DateTime(2026, 11, 23), now), '出席管理');
    expect(attendanceTitleFor(DateTime(2026, 10, 22), now), '出席管理');
    expect(attendanceTitleFor(DateTime(2025, 11, 22), now), '出席管理');
  });
}
