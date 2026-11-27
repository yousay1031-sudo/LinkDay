import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/next_day_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/utils/week_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 出席管理の定員の数え方は「その日に利用した人数」（予定 + 在室中 + 退室済）。
/// 事業所の方針「その日に定員の人数が利用したら定員」に合わせる。
/// - 朝（全員予定）・昼（一部在室）・夕方（全員退室）で、定員超過と空き枠は変わらない
/// - 欠席が出たときだけ空き枠が 1 つ増える
/// - 同じ日の翌日予約選択の人数（利用する − 定員）と食い違わない
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  final today = DateTime.now();
  final day = DateTime(today.year, today.month, today.day);
  final at = DateTime(day.year, day.month, day.day, 10);
  final w = WeeklyScheduleService.instance;
  final a = AttendanceService.instance;
  const ids = ['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7'];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FakeBackend.attachWithStaff();
    await FakeBackend.resetSchedules();
    await FakeBackend.resetAttendance();
    // 7 人が今日を利用する（週間利用計画 → 出席の予定は同じ元から作る）
    final customers = [
      for (final id in ids)
        Customer(
            id: id,
            name: '架空 $id',
            nameKana: 'カクウ $id',
            regularDays: [day.weekday]),
    ];
    await w.getOrCreateSchedule(WeekUtil.weekStartFromDate(day), customers);
    await _settle();
    await a.ensureTodayScheduledRecords(day, customers);
    await _settle();
  });
  tearDown(() async {
    await FakeBackend.resetSchedules();
    await FakeBackend.detach();
  });

  Future<void> setCapacity(int n) async {
    await SettingsService.instance.updateOperatingHours('08:00', '17:00', n);
    await _settle();
  }

  Future<void> setStatus(String id, AttendanceStatus s) async {
    final r = a.getRecord(id, day)!;
    await a.upsertRecord(r.copyWith(
      status: s,
      checkInTime: at,
      checkOutTime: at,
      clearCheckIn:
          s == AttendanceStatus.scheduled || s == AttendanceStatus.absent,
      clearCheckOut: s != AttendanceStatus.departed,
    ));
    await _settle();
  }

  /// 欠席は出席管理と週間利用計画（翌日予約選択の元）の両方に付ける
  Future<void> markAbsent(String id) async {
    await setStatus(id, AttendanceStatus.absent);
    await w.updateEntryStatus(WeekUtil.weekKeyFromDate(day), day.weekday, id,
        ScheduleStatus.cancelled);
    await _settle();
  }

  /// [出席管理の空き枠, 出席管理の定員超過, 翌日予約選択の空き, 翌日予約選択の超過]
  List<int> counts(int capacity) {
    final s = a.getTodaySummary(day);
    final n = NextDayCounts.of(w.getAllEntriesForDate(day), capacity);
    return [s.availableSlots, s.overCapacity, n.free, n.over];
  }

  test('定員 8・7 人: 朝・昼・夕方とも空き枠 1。欠席が出たときだけ 2 に増える', () async {
    await setCapacity(8);
    expect(counts(8), [1, 0, 1, 0], reason: '朝（全員予定）');
    for (final id in ids.take(3)) {
      await setStatus(id, AttendanceStatus.present);
    }
    expect(counts(8), [1, 0, 1, 0], reason: '昼（3 人在室・4 人予定）');
    for (final id in ids.take(3)) {
      await setStatus(id, AttendanceStatus.departed);
    }
    for (final id in ids.skip(3)) {
      await setStatus(id, AttendanceStatus.present);
    }
    expect(counts(8), [1, 0, 1, 0], reason: '昼すぎ（3 人退室・4 人在室）');
    for (final id in ids.skip(3)) {
      await setStatus(id, AttendanceStatus.departed);
    }
    expect(counts(8), [1, 0, 1, 0], reason: '夕方（全員退室）。帰っても空き枠は増えない');
    await markAbsent('c7');
    expect(counts(8), [2, 0, 2, 0], reason: '欠席で空いた枠だけ増える');
  });

  test('定員 6・7 人: 朝・昼・夕方とも定員超過 1。欠席が出ると超過 0・空き枠 0', () async {
    await setCapacity(6);
    expect(counts(6), [0, 1, 0, 1], reason: '朝（全員予定）');
    for (final id in ids.take(4)) {
      await setStatus(id, AttendanceStatus.present);
    }
    expect(counts(6), [0, 1, 0, 1], reason: '昼（4 人在室・3 人予定）');
    for (final id in ids) {
      await setStatus(id, AttendanceStatus.departed);
    }
    expect(counts(6), [0, 1, 0, 1], reason: '夕方（全員退室）。帰っても超過は減らない');
    await markAbsent('c1');
    expect(counts(6), [0, 0, 0, 0], reason: '欠席 1 人でちょうど定員');
    await markAbsent('c2');
    expect(counts(6), [1, 0, 1, 0], reason: 'もう 1 人欠席で空き枠 1');
  });

  test('欠席を取り消すと空き枠は元に戻る（欠席で空いた枠のぶんだけ）', () async {
    await setCapacity(8);
    await setStatus('c1', AttendanceStatus.departed);
    await markAbsent('c2');
    expect(counts(8)[0], 2);
    await setStatus('c2', AttendanceStatus.scheduled);
    expect(a.getTodaySummary(day).availableSlots, 1);
  });
}
