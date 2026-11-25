import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/pending_echoes.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/transport_plan.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/transport_plan_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/utils/week_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 同じ記録を続けて保存したとき、前の保存の折り返しが後から届いても、
/// 画面用の内容が古い内容に戻らないこと（設定は settings_stale_echo_test）。
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// [svc] の変更通知のたびに [read] の値を記録する
List<T> _watch<T>(ChangeNotifier svc, T Function() read) {
  final seen = <T>[];
  void on() => seen.add(read());
  svc.addListener(on);
  addTearDown(() => svc.removeListener(on));
  return seen;
}

final _today = DateTime.now();
final _dk = AttendanceRecord.makeDateKey(_today);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FakeBackend.attachWithStaff();
  });
  tearDown(FakeBackend.detach);

  test('PendingEchoesByDoc: ドキュメントごとに別々に見分ける', () {
    final e = PendingEchoesByDoc()
      ..add('a', {'v': 1})
      ..add('a', {'v': 2})
      ..add('b', {'v': 1});
    expect(e.isStaleEcho('b', {'v': 1}), isFalse, reason: 'b は最後の書き込み');
    expect(e.isStaleEcho('a', {'v': 1}), isTrue, reason: 'a はこの後に 2 を送っている');
    expect(e.isStaleEcho('a', {'v': 2}), isFalse);
    expect(e.isStaleEcho('c', {'v': 1}), isFalse, reason: '送っていないドキュメント');
  });

  group('顧客', () {
    CustomerService svc() => CustomerService.instance;
    Customer c(String? notes) =>
        Customer(id: 'c1', name: 'あ 一郎', nameKana: 'ア イチロウ', notes: notes);

    test('続けて更新: 後の更新の後に、前の更新の内容に戻らない', () async {
      await svc().addCustomer(c('初め'));
      await _drain();
      await svc().updateCustomer(c('一回目'));
      await svc().updateCustomer(c('二回目'));
      final seen = _watch(svc(), () => svc().getCustomerById('c1')?.notes);
      await _drain();
      expect(seen.where((v) => v != '二回目'), isEmpty,
          reason: '保存した後に古い内容が見えてはいけない: $seen');
      expect(svc().getCustomerById('c1')?.notes, '二回目');
    });

    test('他の端末の変更は反映される', () async {
      await svc().addCustomer(c('初め'));
      await _drain();
      await FakeBackend.current.customerCol.doc('c1').update({'notes': '別端末'});
      await _drain();
      expect(svc().getCustomerById('c1')?.notes, '別端末');
    });
  });

  group('送迎計画', () {
    TransportPlanService svc() => TransportPlanService.instance;
    TransportVehicleRoute r(String note) => TransportVehicleRoute(
        id: 'r0',
        vehicleName: '車両A',
        vehicleIndex: 0,
        transportType: TransportType.pickup,
        dateKey: _dk,
        capacity: 6,
        stops: [],
        note: note);
    final id = TransportPlanService.docIdOf(_dk, 0, TransportType.pickup);
    String? shown() => svc()
        .getRoutesByDate(_dk)
        .where((x) => x.vehicleIndex == 0)
        .firstOrNull
        ?.note;

    test('続けて保存: 後の保存の後に、前の保存の内容に戻らない', () async {
      await svc().ensureDate(_dk);
      await svc().saveRoute(r('初め'));
      await _drain();
      await svc().saveRoute(r('一回目'));
      await svc().saveRoute(r('二回目'));
      final seen = _watch(svc(), shown);
      await _drain();
      expect(seen.where((v) => v != '二回目'), isEmpty,
          reason: '保存した後に古い内容が見えてはいけない: $seen');
      expect(shown(), '二回目');
    });

    test('他の端末の変更は反映される', () async {
      await svc().ensureDate(_dk);
      await svc().saveRoute(r('初め'));
      await _drain();
      await FacilityContext.instance
          .col(FsPaths.transportRoutes)
          .doc(id)
          .update({'note': '別端末'});
      await _drain();
      expect(shown(), '別端末');
    });
  });

  group('出席（トランザクションを使わない操作）', () {
    AttendanceService svc() => AttendanceService.instance;
    AttendanceRecord rec(String note) => AttendanceRecord(
        customerId: 'c1', customerName: 'あ 一郎', dateKey: _dk, note: note);
    String? shown() => svc().getRecord('c1', _today)?.note;

    test('upsert を続けて: 前の内容に戻らない', () async {
      await svc().upsertRecord(rec('初め'));
      await _drain();
      await svc().upsertRecord(rec('一回目'));
      await svc().upsertRecord(rec('二回目'));
      final seen = _watch(svc(), shown);
      await _drain();
      expect(seen.where((v) => v != '二回目'), isEmpty,
          reason: '保存した後に古い内容が見えてはいけない: $seen');
      expect(shown(), '二回目');
    });

    test('備考の更新を続けて: 前の内容に戻らない', () async {
      await svc().upsertRecord(rec('初め'));
      await _drain();
      await svc().updateNote(customerId: 'c1', date: _today, note: '一回目');
      await svc().updateNote(customerId: 'c1', date: _today, note: '二回目');
      final seen = _watch(svc(), shown);
      await _drain();
      expect(seen.where((v) => v != '二回目'), isEmpty,
          reason: '保存した後に古い内容が見えてはいけない: $seen');
      expect(shown(), '二回目');
    });

    test('他の端末の変更は反映される', () async {
      await svc().upsertRecord(rec('初め'));
      await _drain();
      await FacilityContext.instance
          .col(FsPaths.attendance)
          .doc('${_dk}_c1')
          .update({'note': '別端末'});
      await _drain();
      expect(shown(), '別端末');
    });
  });

  group('出席（トランザクション: 入室・退室・欠席）', () {
    AttendanceService svc() => AttendanceService.instance;
    AttendanceStatus? shown() => svc().getRecord('c1', _today)?.status;

    test('入室 → 退室を続けて: 退室の後に入室（在室）に戻らない', () async {
      await svc().upsertRecord(AttendanceRecord(
          customerId: 'c1', customerName: 'あ 一郎', dateKey: _dk));
      await _drain();
      await svc().markPresent(customerId: 'c1', date: _today);
      await svc().markDeparted(customerId: 'c1', date: _today);
      final after = _watch(svc(), shown);
      await _drain();
      expect(after.where((v) => v != AttendanceStatus.departed), isEmpty,
          reason: '退室の後に古い状態が見えてはいけない: $after');
      expect(shown(), AttendanceStatus.departed);
    });

    test('欠席 → 取り消しを続けて: 取り消しの後に欠席に戻らない', () async {
      await svc().upsertRecord(AttendanceRecord(
          customerId: 'c1', customerName: 'あ 一郎', dateKey: _dk));
      await _drain();
      await svc().markAbsent(customerId: 'c1', date: _today, reason: '体調');
      await svc().resetAbsent(customerId: 'c1', date: _today);
      final after = _watch(svc(), shown);
      await _drain();
      expect(after.where((v) => v != AttendanceStatus.scheduled), isEmpty,
          reason: '取り消しの後に古い状態が見えてはいけない: $after');
      expect(shown(), AttendanceStatus.scheduled);
    });
  });

  group('週間利用計画', () {
    WeeklyScheduleService svc() => WeeklyScheduleService.instance;
    final monday = DateTime(2026, 11, 23);
    final weekKey = WeekUtil.weekKeyFromDate(monday);
    final customers = [
      Customer(id: 'c1', name: 'あ 一郎', nameKana: 'ア', regularDays: [1]),
    ];
    ScheduleEntry? entry() => svc()
        .getScheduleByWeekKey(weekKey)
        ?.slotForDay(1)
        ?.entries
        .where((e) => e.customerId == 'c1')
        .firstOrNull;

    test('状態の更新を続けて: 前の内容に戻らない', () async {
      await svc().getOrCreateSchedule(monday, customers);
      await _drain();
      await svc().updateEntryStatus(weekKey, 1, 'c1', ScheduleStatus.cancelled);
      await svc()
          .updateEntryStatus(weekKey, 1, 'c1', ScheduleStatus.additional);
      final seen = _watch(svc(), () => entry()?.status);
      await _drain();
      expect(seen.where((v) => v != ScheduleStatus.additional), isEmpty,
          reason: '保存した後に古い内容が見えてはいけない: $seen');
      expect(entry()?.status, ScheduleStatus.additional);
    });

    test('時刻の更新を続けて: 前の内容に戻らない', () async {
      await svc().getOrCreateSchedule(monday, customers);
      await _drain();
      await svc().updateEntryTimes(weekKey, 1, 'c1', '09:00', '15:00');
      await svc().updateEntryTimes(weekKey, 1, 'c1', '10:00', '16:00');
      final seen = _watch(svc(), () => entry()?.plannedStartTime);
      await _drain();
      expect(seen.where((v) => v != '10:00'), isEmpty,
          reason: '保存した後に古い内容が見えてはいけない: $seen');
      expect(entry()?.plannedStartTime, '10:00');
    });
  });
}
