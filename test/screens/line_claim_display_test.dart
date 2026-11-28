@Timeout(Duration(seconds: 180))
library;

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/transport_plan.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/screens/attendance_screen.dart';
import 'package:linkday_app/screens/next_day_booking_screen.dart';
import 'package:linkday_app/screens/weekly_schedule_screen.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/next_day_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/services/transport_plan_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:linkday_app/utils/week_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// LINE の空き枠の応募で予定に入った児童（Functions が書いた予定・出席の予定）を、
/// 週間利用計画・翌日予約選択・出席管理で同じように扱う。
///  - 「LINEの応募で追加」の印（出席管理では確定した時刻も）
///  - 送迎を使うのに、すでにある送迎ルートに入っていなければ「送迎計画に入っていません」
///  - 出席管理と翌日予約選択の数が、確定の前後・取り消しの前後で揃う
///  - アプリで時間を直しても、印（lineClaim）は消えない
void main() {
  late Directory tmp;
  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('linkday_line_claim_');
    Hive.init(tmp.path);
    SlotService.instance.remoteEnabled = false;
    AppMotion.debugDisableLooping = true;
  });
  tearDownAll(() async {
    AppMotion.debugDisableLooping = false;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  const stamp = AuditStamp(staffId: 's-a', staffName: '職員 冬子');
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final key = AttendanceRecord.makeDateKey(today);
  final w = WeeklyScheduleService.instance;
  final a = AttendanceService.instance;
  const capacity = 2;
  final claimedAt = DateTime(today.year, today.month, today.day, 9, 5);

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return v;
      })) as T;

  Customer child(String id, {List<int>? days, List<String> locs = const []}) =>
      Customer(
          id: id,
          name: '架空 $id',
          nameKana: 'カクウ $id',
          regularDays: days ?? [today.weekday],
          transportLocations: locs);

  CollectionReference<Map<String, dynamic>> col(String c) =>
      FacilityContext.instance.col(c);

  /// 今日を利用する 2 人（定員 2）。c1 が欠席。a1 は送迎を使う（今日の予定なし）。
  /// 今日の送迎ルートには c2 だけが入っている
  Future<void> setUpData(WidgetTester t) => io(t, () async {
        await FakeBackend.attach(
            staff: const [FakeBackend.staffA], currentStaffId: 's-a');
        for (final c in [
          child('c1'),
          child('c2', locs: const ['架空の家 2']),
          child('a1', days: const [], locs: const ['架空の家 1']),
        ]) {
          await CustomerService.instance.addCustomer(c, stamp: stamp);
        }
        final s = SettingsService.instance.getSettings();
        SettingsService.instance.debugSetSettings(AppSettings(
            facilityName: s.facilityName, maxStudentsPerDay: capacity));
        await w.getOrCreateSchedule(WeekUtil.weekStartFromDate(today),
            CustomerService.instance.getAllCustomers());
        await a.ensureDate(today);
        await a.ensureTodayScheduledRecords(
            today, CustomerService.instance.getAllCustomers());
        final r = a.getRecord('c1', today)!;
        await a.upsertRecord(
            r.copyWith(status: AttendanceStatus.absent, absenceReason: '体調不良'),
            stamp: stamp);
        await TransportPlanService.instance.ensureDate(key);
        await TransportPlanService.instance.saveRoute(
            TransportVehicleRoute(
              vehicleName: '車両A',
              vehicleIndex: 0,
              transportType: TransportType.pickup,
              dateKey: key,
              capacity: 5,
              stops: [
                TransportStop(
                    customerId: 'c2', customerName: '架空 c2', address: '架空の家 2')
              ],
            ),
            stamp: stamp);
      });

  /// Functions（slotSchedule.ts）が確定のときに書くのと同じ形で、予定と出席の予定を書く
  Future<void> claimByLine(WidgetTester t) => io(t, () async {
        final mark = {
          'slotId': '${key}_c1',
          'customerId': 'a1',
          'claimedAt': Timestamp.fromDate(claimedAt),
          'via': 'line',
          'prev': null,
          'prevAttendance': null,
        };
        final audit = {
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedByStaffId': null,
          'updatedByStaffName': 'LINEの応募',
          'createdAt': FieldValue.serverTimestamp(),
        };
        await col(FsPaths.scheduleEntries).doc('${key}_a1').set({
          'date': key,
          'weekKey': WeekUtil.weekKeyFromDate(today),
          'customerId': 'a1',
          'customerName': '架空 a1',
          'status': 'additional',
          'plannedStartTime': '14:00',
          'plannedEndTime': '17:00',
          'transportLocationIndex': null,
          'note': null,
          'lineClaim': mark,
          ...audit,
        });
        await col(FsPaths.attendance).doc('${key}_a1').set({
          'date': key,
          'customerId': 'a1',
          'customerName': '架空 a1',
          'status': 'scheduled',
          'plannedStartTime': Timestamp.fromDate(
              DateTime(today.year, today.month, today.day, 14)),
          'plannedEndTime': Timestamp.fromDate(
              DateTime(today.year, today.month, today.day, 17)),
          'checkInTime': null,
          'checkOutTime': null,
          'absenceReason': null,
          'lineClaim': mark,
          ...audit,
        });
      });

  /// Functions が取り消し（入室前）のときにするのと同じく、予定と出席の予定を消す
  Future<void> releaseByLine(WidgetTester t) => io(t, () async {
        await col(FsPaths.scheduleEntries).doc('${key}_a1').delete();
        await col(FsPaths.attendance).doc('${key}_a1').delete();
      });

  String text(WidgetTester t, String k) =>
      t.widget<Text>(find.byKey(Key(k))).data ?? '';

  List<int> attendance() {
    final s = a.getTodaySummary(today);
    return [s.usedCount, s.absentCount, s.availableSlots, s.overCapacity];
  }

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

  Future<void> openNextDay(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: NextDayBookingScreen(initialDate: today)));
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  Future<void> pumpFor(WidgetTester t, int ms) async {
    for (var left = ms; left > 0; left -= 16) {
      await t.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('翌日予約選択: 確定の前後・取り消しの前後で出席管理と数が揃い、印と送迎の知らせが出る',
      (t) async {
    await setUpData(t);
    await openNextDay(t);
    expect(attendance(), [1, 1, 1, 0], reason: '確定の前: c2 だけ利用・c1 欠席');
    expect(nextDay(t), attendance());

    await claimByLine(t);
    await t.pumpAndSettle();
    expect(attendance(), [2, 1, 0, 0], reason: '欠席 1 人に 1 人が入って定員ちょうど');
    expect(nextDay(t), attendance(), reason: '確定の後');
    expect(text(t, 'nextDayTimeText_a1'), '14:00〜17:00　LINEの応募で追加');
    expect(text(t, 'nextDayTransport_a1'), '送迎計画に入っていません');
    // 送迎ルートに入っている c2 には出ない
    expect(text(t, 'nextDayTransport_c2'), isNot(contains('入っていません')));

    await releaseByLine(t);
    await t.pumpAndSettle();
    expect(attendance(), [1, 1, 1, 0], reason: '取り消しの後');
    expect(nextDay(t), attendance());
    expect(find.byKey(const Key('nextDayCard_a1')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('出席管理: 「LINEの応募で追加（確定した時刻）」と送迎の知らせ。ボタンはカードに収まる',
      (t) async {
    await setUpData(t);
    await claimByLine(t);
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme, home: const AttendanceScreen()));
    await io(t, () async {});
    await pumpFor(t, 1500);
    expect(t.takeException(), isNull, reason: 'はみ出しの警告が出ていない');
    expect(text(t, 'attendanceLineNote_a1'),
        'LINEの応募で追加（${claimedAt.month}/${claimedAt.day} 09:05 確定）・送迎計画に入っていません');
    expect(find.byKey(const Key('attendanceLineNote_c2')), findsNothing);

    // 取り消されたが入室済み（Functions が印に releasedAt を書く）
    await io(t, () async {
      await col(FsPaths.attendance).doc('${key}_a1').update({
        'status': 'present',
        'checkInTime': Timestamp.fromDate(claimedAt.add(const Duration(hours: 5))),
      });
      await col(FsPaths.scheduleEntries).doc('${key}_a1').update({
        'lineClaim.releasedAt': Timestamp.fromDate(claimedAt.add(const Duration(hours: 6))),
        'lineClaim.keptReason': 'checked_in',
      });
    });
    await pumpFor(t, 600);
    expect(text(t, 'attendanceLineNote_a1'),
        'LINEで取り消し（入室済みのため予定に残しています）');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    await pumpFor(t, 3000);
  });

  testWidgets('週間利用計画: 印を読み、アプリで時間を直しても印は消えない', (t) async {
    await setUpData(t);
    await claimByLine(t);
    ScheduleEntry entry() =>
        w.getAllEntriesForDate(today).firstWhere((e) => e.customerId == 'a1');
    expect(entry().lineClaim?.slotId, '${key}_c1');
    expect(entry().lineClaim?.claimedAt, claimedAt);
    expect(entry().isLineClaimActive, isTrue);
    await io(t, () async {
      await w.updateEntryTimes(WeekUtil.weekKeyFromDate(today), today.weekday,
          'a1', '15:00', '17:30');
    });
    final doc = (await io(
            t, () => col(FsPaths.scheduleEntries).doc('${key}_a1').get()))
        .data()!;
    expect(doc['plannedStartTime'], '15:00');
    expect((doc['lineClaim'] as Map)['slotId'], '${key}_c1',
        reason: 'アプリの書き込みで印が消えない');
    expect(entry().lineClaim?.slotId, '${key}_c1');
    // 週間利用計画の画面: 表のマスに「LINE」、押すと「LINEの応募で追加（確定した時刻）」
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme, home: const WeeklyScheduleScreen()));
    await io(t, () async {});
    await pumpFor(t, 1500);
    // 週間利用計画は翌週を開く。今日の週へ戻る
    await t.tap(find.byTooltip('前の週'));
    await io(t, () async {});
    await pumpFor(t, 1200);
    expect(find.byKey(const Key('weeklyLineMark_a1')), findsOneWidget);
    expect(find.byKey(const Key('weeklyLineMark_c2')), findsNothing);
    await t.tap(find.byKey(const Key('weeklyLineMark_a1')));
    await pumpFor(t, 800);
    expect(text(t, 'weeklyLineNote'),
        'LINEの応募で追加（${claimedAt.month}/${claimedAt.day} 09:05 確定）');
    expect(text(t, 'weeklyStatusBadge_a1'), 'LINEの応募で追加');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    await pumpFor(t, 2000);

    // お休みにすると、いまは利用しない（印は残すが「追加」の知らせは出さない）
    await io(t, () async {
      await w.updateEntryStatus(WeekUtil.weekKeyFromDate(today), today.weekday,
          'a1', ScheduleStatus.cancelled);
    });
    expect(entry().isLineClaimActive, isFalse);
    expect(
        NextDayTransport.lineNote(entry(), null,
            routesExist: false, inRoute: true),
        isNull);
  });
}
