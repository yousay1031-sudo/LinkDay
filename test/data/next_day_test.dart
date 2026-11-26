import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/transport_plan.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/next_day_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/utils/week_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ4 段階2: 翌日予約選択（対象の日・人数・送迎の表示・利用する／お休み・追加）
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  const stamp = AuditStamp(staffId: 's-a', staffName: '職員 冬子');
  // 2026-11-30（月）〜12-06（日）
  final mon = DateTime(2026, 11, 30);
  final tue = DateTime(2026, 12, 1);
  final wed = DateTime(2026, 12, 2);
  final sat = DateTime(2026, 12, 5);
  final weekKey = WeekUtil.weekKeyFromDate(mon);
  final w = WeeklyScheduleService.instance;

  Future<void> setUpData({List<Customer>? customers}) async {
    await FakeBackend.attachWithStaff();
    for (final c in customers ??
        [
          Customer(
              id: 'c1',
              name: '架空 一',
              nameKana: 'カクウ イチ',
              regularDays: [1, 3],
              transportLocations: ['架空の家', '架空の学校']),
          Customer(id: 'c2', name: '架空 二', nameKana: 'カクウ ニ', regularDays: [3]),
          Customer(
              id: 'c3', name: '架空 三', nameKana: 'カクウ サン', regularDays: [2]),
        ]) {
      await CustomerService.instance.addCustomer(c, stamp: stamp);
    }
  }

  Customer cust(String id) => CustomerService.instance.getCustomerById(id)!;
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  Future<Map<String, dynamic>?> stored(DateTime d, String cid) async =>
      (await FakeBackend.current.db
              .collection(FsPaths.facilities)
              .doc(FakeBackend.current.facilityId)
              .collection(FsPaths.scheduleEntries)
              .doc(WeeklyScheduleService.entryDocId(d, cid))
              .get())
          .data();

  group('開く日（承認済みの判断点1 A: 予定の無い日は飛ばす。最大 7 日先まで）', () {
    test('土曜に開くと、予定の無い日曜を飛ばして月曜（週がまだ無ければ作る）', () async {
      await setUpData();
      final next = DateTime(2026, 12, 7); // 翌週の月曜
      final got = await NextDayService.findTargetDate(sat);
      expect(got, next);
      expect(w.hasWeekFor(next), isTrue); // 画面: 週間利用計画と同じ処理で作った
    });

    test('明日に予定があれば明日（お休みだけの日も予定がある日として扱う）', () async {
      await setUpData();
      await w.getOrCreateSchedule(
          mon, CustomerService.instance.getAllCustomers());
      expect(await NextDayService.findTargetDate(mon), tue);
      // 火曜の予定（c3）をお休みにしても火曜
      await w.setUse(tue, cust('c3'), use: false);
      await settle();
      expect(await NextDayService.findTargetDate(mon), tue);
    });

    test('ホームの印のときは週を作らず、利用曜日から作られるはずの予定で判断する', () async {
      await setUpData();
      expect(w.hasWeekFor(DateTime(2026, 12, 7)), isFalse);
      expect(await NextDayService.findTargetDate(sat, createWeeks: false),
          DateTime(2026, 12, 7));
      expect(w.hasWeekFor(DateTime(2026, 12, 7)), isFalse); // 作っていない
    });

    test('7 日先まで予定が無ければ明日', () async {
      await setUpData(customers: [
        Customer(id: 'x', name: '架空 曜日なし', nameKana: 'カクウ', regularDays: []),
      ]);
      expect(await NextDayService.findTargetDate(tue), wed);
    });
  });

  group('人数と送迎の表示', () {
    test('利用する・お休み・空き・定員超過', () {
      ScheduleEntry e(ScheduleStatus s) =>
          ScheduleEntry(customerId: 'x', customerName: 'x', status: s);
      final c = NextDayCounts.of([
        e(ScheduleStatus.planned),
        e(ScheduleStatus.additional),
        e(ScheduleStatus.cancelled),
      ], 10);
      expect([c.using, c.absent, c.free, c.over], [2, 1, 8, 0]);
      final over = NextDayCounts.of(
          List.generate(12, (_) => e(ScheduleStatus.planned)), 10);
      expect([over.free, over.over], [0, 2]);
    });

    test('送迎: 場所の無い児童は「送迎なし」、場所は予定の番号の場所、ルートの車両', () {
      final c = Customer(
          id: 'c1',
          name: 'x',
          nameKana: 'x',
          transportLocations: ['架空の家', '架空の学校']);
      final noLoc = Customer(id: 'c2', name: 'y', nameKana: 'y');
      ScheduleEntry e(int? i) => ScheduleEntry(
          customerId: 'c1', customerName: 'x', transportLocationIndex: i);
      expect(NextDayTransport.placeText(noLoc, e(null)), '送迎なし');
      expect(NextDayTransport.placeText(c, e(null)), '送迎：架空の家');
      expect(NextDayTransport.placeText(c, e(1)), '送迎：架空の学校');
      expect(NextDayTransport.placeText(c, e(5)), '送迎：架空の家');
      TransportVehicleRoute r(TransportType t, String v, String cid) =>
          TransportVehicleRoute(
            vehicleName: v,
            vehicleIndex: 0,
            transportType: t,
            dateKey: '2026-12-02',
            stops: [
              TransportStop(customerId: cid, customerName: 'x', address: 'a')
            ],
            capacity: 5,
          );
      final routes = [
        r(TransportType.pickup, '車両A', 'c1'),
        r(TransportType.dropoff, '車両B', 'c1'),
        r(TransportType.pickup, '車両C', 'c9'),
      ];
      expect(NextDayTransport.routeText('c1', routes), 'お迎え 車両A・お送り 車両B');
      expect(NextDayTransport.routeText('c2', routes), isNull);
    });
  });

  group('利用する／お休み・追加（週間利用計画の予定を直接変える）', () {
    test('お休みはキャンセル（予定は消さない）。利用するに戻すと、利用曜日なら通常・違えば追加', () async {
      await setUpData();
      await w.getOrCreateSchedule(
          mon, CustomerService.instance.getAllCustomers());
      await w.setUse(wed, cust('c1'), use: false);
      await settle();
      expect((await stored(wed, 'c1'))!['status'], 'cancelled');
      expect((await stored(wed, 'c1'))!['updatedByStaffName'], '職員 冬子');
      expect(w.getEntriesForDate(wed).map((e) => e.customerId), ['c2']);
      expect(w.getAllEntriesForDate(wed).length, 2); // 消していない
      await w.setUse(wed, cust('c1'), use: true);
      await settle();
      expect((await stored(wed, 'c1'))!['status'], 'planned');

      // 利用曜日でない日に追加した予定をお休み → 利用する は「追加」に戻る
      await w.addExtra(tue, cust('c1'));
      await w.setUse(tue, cust('c1'), use: false);
      await w.setUse(tue, cust('c1'), use: true);
      await settle();
      expect((await stored(tue, 'c1'))!['status'], 'additional');
    });

    test('追加した児童の予定時刻は、同じ週のほかの日の予定時刻（無ければ空）', () async {
      await setUpData();
      await w.getOrCreateSchedule(
          mon, CustomerService.instance.getAllCustomers());
      await w.updateEntryTimes(weekKey, mon.weekday, 'c1', '14:30', '17:30');
      await w.updateEntryTimes(weekKey, wed.weekday, 'c1', '14:30', '17:30');
      await w.addExtra(tue, cust('c1'));
      await w.addExtra(sat, cust('c2')); // c2 は水曜だけ・時刻なし
      await settle();
      final t1 = (await stored(tue, 'c1'))!;
      expect([t1['status'], t1['plannedStartTime'], t1['plannedEndTime']],
          ['additional', '14:30', '17:30']);
      final t2 = (await stored(sat, 'c2'))!;
      expect([t2['plannedStartTime'], t2['plannedEndTime']], [null, null]);
    });

    test('「お休み」「利用する」を続けて押しても、遅れて届いた古い内容に戻らない', () async {
      await setUpData();
      await w.getOrCreateSchedule(
          mon, CustomerService.instance.getAllCustomers());
      await settle();
      // 送信の完了を待たずに続けて押す（最後はお休み）
      for (var i = 0; i < 5; i++) {
        await w.setUse(wed, cust('c1'), use: i.isOdd);
      }
      await w.setUse(wed, cust('c1'), use: false);
      ScheduleStatus now() => w
          .getAllEntriesForDate(wed)
          .firstWhere((e) => e.customerId == 'c1')
          .status;
      expect(now(), ScheduleStatus.cancelled);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(now(), ScheduleStatus.cancelled, reason: '途中で古い内容に戻った');
      }
      expect((await stored(wed, 'c1'))!['status'], 'cancelled');
    });

    test('他の端末（週間利用計画の画面を含む）の変更が届き、最後の更新時刻が分かる', () async {
      await setUpData();
      await w.getOrCreateSchedule(
          mon, CustomerService.instance.getAllCustomers());
      await settle();
      final before = w.latestUpdateOn(wed);
      expect(before, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await FakeBackend.current.db
          .collection(FsPaths.facilities)
          .doc(FakeBackend.current.facilityId)
          .collection(FsPaths.scheduleEntries)
          .doc(WeeklyScheduleService.entryDocId(wed, 'c2'))
          .update({
        'status': 'cancelled',
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedByStaffName': '職員 夏男',
      });
      await settle();
      expect(
          w
              .getAllEntriesForDate(wed)
              .firstWhere((e) => e.customerId == 'c2')
              .status,
          ScheduleStatus.cancelled);
      expect(w.latestUpdateOn(wed)!.isAfter(before!), isTrue);
    });
  });
}
