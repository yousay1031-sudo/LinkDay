import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/data_errors.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 段階5: 出席を Firestore に移し、状態を進める操作をトランザクションにしたことの確認
final _today = DateTime.now();
final _dk = AttendanceRecord.makeDateKey(_today);
final _wd = _today.weekday;
final _customers = [
  Customer(id: 'c1', name: 'あ 一郎', nameKana: 'ア', regularDays: [_wd]),
  Customer(id: 'c2', name: 'い 花子', nameKana: 'イ', regularDays: [_wd]),
  Customer(id: 'c3', name: 'う 次郎', nameKana: 'ウ', regularDays: [_wd]),
];

AttendanceService get _svc => AttendanceService.instance;
CollectionReference<Map<String, dynamic>> _col() =>
    FacilityContext.instance.col(FsPaths.attendance);
Future<Map<String, dynamic>?> _stored(String customerId) async =>
    (await _col().doc('${_dk}_$customerId').get()).data();
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

/// 別の端末の書き込み（この端末のサービスを通らない）
Future<void> _otherDevice(String customerId, Map<String, dynamic> fields) =>
    _col().doc('${_dk}_$customerId').update({
      ...fields,
      'updatedByStaffName': '別端末',
    });

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FakeBackend.attachWithStaff();
    _svc.debugTransactionError = null;
  });
  tearDown(() async {
    _svc.debugTransactionError = null;
    await FakeBackend.detach();
  });

  group('当日予定の作成', () {
    test('記録は {日付}_{顧客ID} の 1 件。担当者なしで「自動」と記録する', () async {
      StaffSession.instance.debugSet(
          facilityId: FakeBackend.defaultFacilityId, staffId: null);
      final n = await _svc.ensureTodayScheduledRecords(_today, _customers);
      expect(n, 3);
      final d = (await _stored('c1'))!;
      expect(d['date'], _dk);
      expect(d['status'], 'scheduled');
      expect(d['updatedByStaffName'], '自動');
      expect(await _svc.ensureTodayScheduledRecords(_today, _customers), 0,
          reason: '2 回目は作らない');
    });

    test('2 つの処理が同時に走っても記録は顧客ごとに 1 件（ID が日付と顧客で決まる）', () async {
      // 注: 偽の保存先はトランザクションの競合（再試行）を再現しないため、
      // ここでは「記録が増えない」ことだけを確かめる。競合時に後の側が作成を
      // 飛ばすことは、検証環境（エミュレータ・2 ブラウザ）で確かめる。
      await Future.wait([
        _svc.ensureTodayScheduledRecords(_today, _customers),
        _svc.ensureTodayScheduledRecords(_today, _customers),
      ]);
      final docs = (await _col().get()).docs;
      expect(docs.map((d) => d.id).toSet(), {'${_dk}_c1', '${_dk}_c2', '${_dk}_c3'});
      expect(_svc.getRecordsByDate(_today).length, 3);
    });

    test('他の端末が先に作って入室まで済ませていても、上書きしない', () async {
      await _col().doc('${_dk}_c1').set({
        ...AttendanceRecord(
                customerId: 'c1',
                customerName: 'あ 一郎',
                dateKey: _dk,
                status: AttendanceStatus.present,
                checkInTime: DateTime(2026, 1, 1, 10))
            .toFirestoreData(),
      });
      // この端末はまだその記録を知らない（購読に届く前）
      _svc.debugSetCache([]);
      final n = await _svc.ensureTodayScheduledRecords(_today, _customers);
      expect(n, 2);
      expect((await _stored('c1'))!['status'], 'present');
    });

    test('通信できないときは作らずに知らせる（画面の表示は続ける）', () async {
      final msgs = <String>[];
      final sub = DataErrors.messages.listen(msgs.add);
      addTearDown(sub.cancel);
      _svc.debugTransactionError =
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
      expect(await _svc.ensureTodayScheduledRecords(_today, _customers), 0);
      await _settle();
      expect(msgs.single, contains('通信できません'));
      expect((await _col().get()).docs, isEmpty);
    });
  });

  group('入室・退室・欠席・欠席の取り消し', () {
    setUp(() async {
      await _svc.ensureTodayScheduledRecords(_today, _customers);
      await _settle();
    });

    test('入室・退室を記録した担当者が残る', () async {
      await _svc.markPresent(customerId: 'c1', date: _today);
      StaffSession.instance.debugSet(
          facilityId: FakeBackend.defaultFacilityId,
          staffId: FakeBackend.staffB.id);
      expect(await _svc.markDeparted(customerId: 'c1', date: _today),
          DepartResult.success);
      final d = (await _stored('c1'))!;
      expect(d['status'], 'departed');
      expect(d['checkInByStaffName'], '山田');
      expect(d['checkOutByStaffName'], '佐藤');
      expect(d['updatedByStaffName'], '佐藤');
    });

    test('他の端末で退室済みなら、入室を記録せず状態を戻さない', () async {
      await _otherDevice('c1', {
        'status': 'departed',
        'checkInTime': Timestamp.fromDate(DateTime(2026, 1, 1, 10)),
        'checkOutTime': Timestamp.fromDate(DateTime(2026, 1, 1, 15)),
      });
      // この端末の画面はまだ「予定」のまま（購読に届く前に押した）
      _svc.debugSetCache([
        AttendanceRecord(customerId: 'c1', customerName: 'あ 一郎', dateKey: _dk),
      ]);
      await expectLater(_svc.markPresent(customerId: 'c1', date: _today),
          throwsA(isA<AttendanceConflictException>()
              .having((e) => e.current, 'current', AttendanceStatus.departed)));
      expect((await _stored('c1'))!['status'], 'departed');
      expect(_svc.getRecord('c1', _today)!.status, AttendanceStatus.departed,
          reason: '画面を最新の状態に合わせる');
    });

    test('2 台が同時に入室を押しても、入室時刻は最初の 1 回のまま', () async {
      await _svc.markPresent(
          customerId: 'c1', date: _today, time: DateTime(2026, 1, 1, 10, 0));
      // もう一方の端末の画面は「予定」のまま押した（同じ状態への操作は何もしない）
      _svc.debugSetCache([
        AttendanceRecord(customerId: 'c1', customerName: 'あ 一郎', dateKey: _dk),
      ]);
      await _svc.markPresent(
          customerId: 'c1', date: _today, time: DateTime(2026, 1, 1, 10, 5));
      final d = (await _stored('c1'))!;
      expect((d['checkInTime'] as Timestamp).toDate(), DateTime(2026, 1, 1, 10, 0));
    });

    test('他の端末で既に退室済みなら、退室時刻と記録者を上書きしない', () async {
      await _svc.markPresent(customerId: 'c1', date: _today);
      await _otherDevice('c1', {
        'status': 'departed',
        'checkOutTime': Timestamp.fromDate(DateTime(2026, 1, 1, 15)),
        'checkOutByStaffName': '別端末',
      });
      _svc.debugSetCache([
        _svc.getRecord('c1', _today)!..status = AttendanceStatus.present,
      ]);
      expect(await _svc.markDeparted(customerId: 'c1', date: _today),
          DepartResult.success);
      final d = (await _stored('c1'))!;
      expect((d['checkOutTime'] as Timestamp).toDate(), DateTime(2026, 1, 1, 15));
      expect(d['checkOutByStaffName'], '別端末');
    });

    test('他の端末で先に欠席になっていたら、理由を上書きせず競合を返す', () async {
      await _otherDevice('c2', {'status': 'absent', 'absenceReason': '体調不良'});
      _svc.debugSetCache([
        AttendanceRecord(customerId: 'c2', customerName: 'い 花子', dateKey: _dk),
      ]);
      await expectLater(
          _svc.markAbsent(customerId: 'c2', date: _today, reason: '家庭の都合'),
          throwsA(isA<AttendanceConflictException>()));
      expect((await _stored('c2'))!['absenceReason'], '体調不良');
    });

    test('欠席の取り消しは、他の端末で入室済みになっていたら状態を戻さない', () async {
      await _svc.markAbsent(customerId: 'c3', date: _today, reason: '体調不良');
      await _otherDevice('c3', {
        'status': 'present',
        'absenceReason': null,
        'checkInTime': Timestamp.fromDate(DateTime(2026, 1, 1, 11)),
      });
      _svc.debugSetCache([
        _svc.getRecord('c3', _today)!..status = AttendanceStatus.absent,
      ]);
      await expectLater(_svc.resetAbsent(customerId: 'c3', date: _today),
          throwsA(isA<AttendanceConflictException>()));
      expect((await _stored('c3'))!['status'], 'present');
    });

    test('欠席理由を選んでいる間に他の端末で入室されたら、欠席を記録しない', () async {
      // 画面に「予定」が出ている状態で欠席ダイアログを開いた
      final shownStatus = _svc.getRecord('c2', _today)!.status;
      // その間に別の端末が入室を記録し、この端末にも届いた
      await _otherDevice('c2', {
        'status': 'present',
        'checkInTime': Timestamp.fromDate(DateTime(2026, 1, 1, 10)),
      });
      await _settle();
      expect(_svc.getRecord('c2', _today)!.status, AttendanceStatus.present);
      await expectLater(
          _svc.markAbsent(
              customerId: 'c2', date: _today, reason: '体調不良', expected: shownStatus),
          throwsA(isA<AttendanceConflictException>()));
      expect((await _stored('c2'))!['status'], 'present');
    });

    test('欠席 → 取り消しで予定に戻る', () async {
      await _svc.markAbsent(customerId: 'c3', date: _today, reason: '体調不良');
      await _svc.resetAbsent(customerId: 'c3', date: _today);
      final d = (await _stored('c3'))!;
      expect(d['status'], 'scheduled');
      expect(d['absenceReason'], isNull);
    });

    test('通信できないときは入室・退室を記録しない（理由を返す）', () async {
      _svc.debugTransactionError =
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
      await expectLater(_svc.markPresent(customerId: 'c1', date: _today),
          throwsA(isA<AttendanceUnavailableException>()));
      expect(_svc.getRecord('c1', _today)!.status, AttendanceStatus.scheduled);
      expect((await _stored('c1'))!['status'], 'scheduled');
      // 通信が戻れば記録できる
      _svc.debugTransactionError = null;
      await _svc.markPresent(customerId: 'c1', date: _today);
      expect((await _stored('c1'))!['status'], 'present');
    });

    test('担当者が未選択なら入室を止め、何も変えない', () async {
      StaffSession.instance.debugSet(
          facilityId: FakeBackend.defaultFacilityId, staffId: null);
      await expectLater(_svc.markPresent(customerId: 'c1', date: _today),
          throwsA(isA<StaffNotSelectedException>()));
      expect((await _stored('c1'))!['status'], 'scheduled');
    });

    test('他の端末の変更が開き直さずに届き、変更通知が出る', () async {
      var notified = 0;
      void onChange() => notified++;
      _svc.addListener(onChange);
      addTearDown(() => _svc.removeListener(onChange));
      await _otherDevice('c2', {'status': 'absent', 'absenceReason': '体調不良'});
      await _settle();
      expect(_svc.getRecord('c2', _today)!.status, AttendanceStatus.absent);
      expect(notified, greaterThan(0));
    });
  });
}
