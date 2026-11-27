@Timeout(Duration(seconds: 150))
library;

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/day_ticker.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/screens/next_day_booking_screen.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:linkday_app/utils/week_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 翌日予約選択で今日（出席の記録がある日）を開いたときは、出席の記録から数える。
/// 同じ日の出席管理と、利用する・お休み・定員超過・空きが揃う。
/// 出席管理で欠席の児童はお休みと同じ扱いで「出席管理で欠席」の印。週間利用計画は書き換えない。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    DayTicker.instance.debugReset();
    await FakeBackend.detach();
  });

  const stamp = AuditStamp(staffId: 's-a', staffName: '職員 冬子');
  // 今日は 2026-12-01（火）
  final today = DateTime(2026, 12, 1);
  final w = WeeklyScheduleService.instance;
  final a = AttendanceService.instance;
  const capacity = 4;
  const ids = ['c1', 'c2', 'c3', 'c4', 'c5'];

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return v;
      })) as T;

  Customer child(String id, {List<int> days = const [2]}) =>
      Customer(id: id, name: '架空 $id', nameKana: 'カクウ $id', regularDays: days);

  /// 今日（火）を利用する 5 人（定員 4）。応募用の 1 人（a1）は今日の予定なし
  Future<void> setUpData(WidgetTester t) => io(t, () async {
        DayTicker.instance.now = () => today.add(const Duration(hours: 10));
        await FakeBackend.attach(
            staff: const [FakeBackend.staffA, FakeBackend.staffB],
            currentStaffId: 's-a');
        for (final id in ids) {
          await CustomerService.instance.addCustomer(child(id), stamp: stamp);
        }
        await CustomerService.instance
            .addCustomer(child('a1', days: const [3]), stamp: stamp);
        final s = SettingsService.instance.getSettings();
        SettingsService.instance.debugSetSettings(AppSettings(
            facilityName: s.facilityName, maxStudentsPerDay: capacity));
        await w.getOrCreateSchedule(WeekUtil.weekStartFromDate(today),
            CustomerService.instance.getAllCustomers());
        await a.ensureDate(today);
        await a.ensureTodayScheduledRecords(
            today, CustomerService.instance.getAllCustomers());
      });

  Future<void> open(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: NextDayBookingScreen(initialDate: today)));
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  Future<void> setStatus(WidgetTester t, String id, AttendanceStatus s) async {
    await io(t, () async {
      final r = a.getRecord(id, today)!;
      await a.upsertRecord(
          r.copyWith(
              status: s,
              absenceReason: s == AttendanceStatus.absent ? '体調不良' : null,
              clearAbsenceReason: s != AttendanceStatus.absent),
          stamp: stamp);
    });
    await t.pumpAndSettle();
  }

  String text(WidgetTester t, String key) =>
      t.widget<Text>(find.byKey(Key(key))).data ?? '';

  /// 出席管理の数（利用・欠席・空き枠・定員超過）
  List<int> attendance() {
    final s = a.getTodaySummary(today);
    return [s.usedCount, s.absentCount, s.availableSlots, s.overCapacity];
  }

  /// 翌日予約選択の数（利用する・お休み・空き・定員超過）
  List<int> nextDay(WidgetTester t) {
    int n(String s) => int.parse(RegExp(r'\d+').firstMatch(s)!.group(0)!);
    final free = find.byKey(const Key('nextDayFree'));
    final over = find.byKey(const Key('nextDayOver'));
    return [
      n(text(t, 'nextDayUsing')),
      n(text(t, 'nextDayAbsent')),
      free.evaluate().isEmpty ? 0 : n(text(t, 'nextDayFree')),
      over.evaluate().isEmpty ? 0 : n(text(t, 'nextDayOver')),
    ];
  }

  ScheduleStatus? planStatus(String id) {
    for (final e in w.getAllEntriesForDate(today)) {
      if (e.customerId == id) return e.status;
    }
    return null;
  }

  testWidgets('出席管理で欠席・欠席の取り消し・LINE の応募で 1 人入った場合のそれぞれで、数が同じ', (t) async {
    await setUpData(t);
    await open(t);
    expect(attendance(), [5, 0, 0, 1], reason: '欠席なし: 5 人・定員 4');
    expect(nextDay(t), attendance());

    // 出席管理で c1 を欠席にする（週間利用計画は「通常」のまま）
    await setStatus(t, 'c1', AttendanceStatus.absent);
    expect(attendance(), [4, 1, 0, 0]);
    expect(nextDay(t), attendance(), reason: '欠席あり');
    expect(planStatus('c1'), ScheduleStatus.planned, reason: '計画は書き換えない');
    // お休みと同じ扱いで、出席管理で欠席の印
    expect(text(t, 'nextDayTimeText_c1'), contains('出席管理で欠席'));
    final off =
        t.widget<ElevatedButton>(find.byKey(const Key('nextDayAbsent_c1')));
    expect(off.onPressed, isNull, reason: '今日はこの画面から直せない');
    expect(find.byKey(const Key('nextDayUse_c1')), findsOneWidget);

    // 欠席の取り消し
    await setStatus(t, 'c1', AttendanceStatus.scheduled);
    expect(attendance(), [5, 0, 0, 1]);
    expect(nextDay(t), attendance(), reason: '欠席の取り消し');
    expect(text(t, 'nextDayTimeText_c1'), isNot(contains('出席管理で欠席')));

    // c2 が欠席 → 空いた枠に LINE の応募で a1 が入る
    // （職員が週間利用計画に「追加」し、出席管理を開くと出席の予定ができる）
    await setStatus(t, 'c2', AttendanceStatus.absent);
    expect(attendance(), [4, 1, 0, 0]);
    expect(nextDay(t), attendance());
    await io(t, () async {
      await w.addExtra(today, CustomerService.instance.getCustomerById('a1')!);
      await a.ensureTodayScheduledRecords(
          today, CustomerService.instance.getAllCustomers());
    });
    await t.pumpAndSettle();
    expect(attendance(), [5, 1, 0, 1]);
    expect(nextDay(t), attendance(), reason: 'LINE の応募で 1 人入った');
    expect(text(t, 'nextDayTimeText_a1'), contains('追加'));
    expect(planStatus('c2'), ScheduleStatus.planned, reason: '計画は書き換えない');
    expect(t.takeException(), isNull);
  });

  testWidgets('出席管理にだけ記録がある児童（計画に無い）も、出席の記録どおりに数える', (t) async {
    await setUpData(t);
    await open(t);
    await io(t, () async {
      await a.upsertRecord(
          AttendanceRecord(
              customerId: 'a1',
              customerName: '架空 a1',
              dateKey: AttendanceRecord.makeDateKey(today),
              status: AttendanceStatus.present,
              checkInTime: today.add(const Duration(hours: 10))),
          stamp: stamp);
    });
    await t.pumpAndSettle();
    expect(attendance(), [6, 0, 0, 2]);
    expect(nextDay(t), attendance());
    expect(find.byKey(const Key('nextDayCard_a1')), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('明日以降は今までどおり週間利用計画から数える', (t) async {
    await setUpData(t);
    final wed = today.add(const Duration(days: 1));
    await io(t, () async {
      // 明日の出席の記録があっても使わない
      await a.upsertRecord(
          AttendanceRecord(
              customerId: 'c1',
              customerName: '架空 c1',
              dateKey: AttendanceRecord.makeDateKey(wed),
              status: AttendanceStatus.absent),
          stamp: stamp);
    });
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: NextDayBookingScreen(initialDate: wed)));
    await io(t, () async {});
    await t.pumpAndSettle();
    final planned = w
        .getAllEntriesForDate(wed)
        .where((e) => e.status != ScheduleStatus.cancelled)
        .length;
    expect(text(t, 'nextDayUsing'), '$planned人');
    expect(find.textContaining('出席管理で欠席'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
