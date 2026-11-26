import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/screens/transport_screen.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/utils/week_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 回帰（ステップ4 判断点2）: 「週間利用計画が無い」の判定は「その週の目印が無い」。
///
/// 以前は「その日の有効な予定が 0 件」で判定していたため、全員をキャンセルにした日に、
/// 出席管理は利用曜日から全員の予定を作り、送迎計画は利用曜日の全員を対象にしていた。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  const stamp = AuditStamp(staffId: 's-a', staffName: '職員 冬子');
  // 2026-11-30 は月曜日
  final monday = DateTime(2026, 11, 30);
  final wednesday = DateTime(2026, 12, 2);
  final weekKey = WeekUtil.weekKeyFromDate(monday);

  Future<List<Customer>> setUpCustomers() async {
    await FakeBackend.attachWithStaff();
    final cs = [
      Customer(id: 'c1', name: '架空 一', nameKana: 'カクウ イチ', regularDays: [1, 3]),
      Customer(id: 'c2', name: '架空 二', nameKana: 'カクウ ニ', regularDays: [3]),
      Customer(id: 'c3', name: '架空 三', nameKana: 'カクウ サン', regularDays: [2]),
    ];
    for (final c in cs) {
      await CustomerService.instance.addCustomer(c, stamp: stamp);
    }
    return CustomerService.instance.getAllCustomers();
  }

  Future<void> cancelAllOn(DateTime day) async {
    final w = WeeklyScheduleService.instance;
    for (final e in w.getEntriesForDate(day)) {
      await w.updateEntryStatus(
          weekKey, day.weekday, e.customerId, ScheduleStatus.cancelled);
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  test('週間利用計画がある週で全員をキャンセルにした日: 出席管理は誰も作らず、送迎計画の対象も 0 人', () async {
    final cs = await setUpCustomers();
    await WeeklyScheduleService.instance.getOrCreateSchedule(monday, cs);
    expect(
        WeeklyScheduleService.instance
            .getEntriesForDate(wednesday)
            .map((e) => e.customerId),
        unorderedEquals(['c1', 'c2']));
    await cancelAllOn(wednesday);
    expect(
        WeeklyScheduleService.instance.getEntriesForDate(wednesday), isEmpty);
    expect(WeeklyScheduleService.instance.hasWeekFor(wednesday), isTrue);

    final created = await AttendanceService.instance
        .ensureTodayScheduledRecords(wednesday, cs);
    expect(created, 0);
    expect(AttendanceService.instance.getRecordsByDate(wednesday), isEmpty);
    expect(await TransportScreen.scheduledCustomersFor(wednesday), isEmpty);
  });

  test('一部だけキャンセル: キャンセルしていない児童だけが予定・送迎の対象になる', () async {
    final cs = await setUpCustomers();
    await WeeklyScheduleService.instance.getOrCreateSchedule(monday, cs);
    await WeeklyScheduleService.instance.updateEntryStatus(
        weekKey, wednesday.weekday, 'c1', ScheduleStatus.cancelled);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await AttendanceService.instance.ensureTodayScheduledRecords(wednesday, cs);
    expect(
        AttendanceService.instance
            .getRecordsByDate(wednesday)
            .map((r) => r.customerId),
        ['c2']);
    expect(
        (await TransportScreen.scheduledCustomersFor(wednesday))
            .map((c) => c.id),
        ['c2']);
  });

  test('週の目印が本当に無い週は、今までどおり利用曜日から作る（動きは変わらない）', () async {
    final cs = await setUpCustomers();
    expect(WeeklyScheduleService.instance.hasWeekFor(wednesday), isFalse);
    final created = await AttendanceService.instance
        .ensureTodayScheduledRecords(wednesday, cs);
    expect(created, 2);
    expect(
        AttendanceService.instance
            .getRecordsByDate(wednesday)
            .map((r) => r.customerId),
        unorderedEquals(['c1', 'c2']));
    expect(
        (await TransportScreen.scheduledCustomersFor(wednesday))
            .map((c) => c.id),
        unorderedEquals(['c1', 'c2']));
    // 日曜は利用曜日の対象外（送迎は 0 人）
    expect(await TransportScreen.scheduledCustomersFor(DateTime(2026, 12, 6)),
        isEmpty);
  });
}
