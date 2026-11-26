import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/transport_plan.dart';
import 'package:linkday_app/services/transport_plan_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 段階6: 送迎計画の保存先を Firestore に移したことの確認（ルート作成の中身は範囲外）
const _date = '2026-11-25';

TransportVehicleRoute _route({int v = 0, TransportType type = TransportType.pickup}) =>
    TransportVehicleRoute(
      id: 'r-$v-${type.name}',
      vehicleName: '車両${'ABC'[v]}',
      vehicleIndex: v,
      transportType: type,
      dateKey: _date,
      capacity: 6,
      stops: [
        TransportStop(
            customerId: 'c1', customerName: 'あ 一郎', address: '帯広市（見本）1',
            lat: 42.92, lng: 143.19, orderIndex: 0, scheduledTime: '09:05',
            distanceFromPrevMeters: 800, durationFromPrevSeconds: 240),
        TransportStop(
            customerId: 'c2', customerName: 'い 花子', address: '帯広市（見本）2',
            orderIndex: 1),
      ],
      totalDistanceMeters: 4200,
      totalDurationSeconds: 1500,
      optimizedAt: DateTime(2026, 11, 25, 8, 30),
    );

TransportPlanService get _svc => TransportPlanService.instance;
CollectionReference<Map<String, dynamic>> _col() =>
    FacilityContext.instance.col(FsPaths.transportRoutes);
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FakeBackend.attachWithStaff();
    await _svc.ensureDate(_date);
  });
  tearDown(FakeBackend.detach);

  test('1 ルート = {日付}_{お迎え/お送り}_{車両} の 1 ドキュメント。読み直しで内容が変わらない', () async {
    await _svc.saveRoute(_route());
    await _svc.saveRoute(_route(v: 1, type: TransportType.dropoff));
    await _settle();
    final ids = (await _col().get()).docs.map((d) => d.id).toSet();
    expect(ids, {'${_date}_pickup_0', '${_date}_dropoff_1'});
    final d = (await _col().doc('${_date}_pickup_0').get()).data()!;
    expect(d['updatedByStaffName'], '職員 冬子');
    expect((d['stops'] as List).length, 2, reason: '停留所の並びはルートの中に持つ');

    await FakeBackend.reloadTransport();
    await _svc.ensureDate(_date);
    final r = _svc.getPickupRoutes(_date).single;
    expect(r.toFirestoreData(), _route().toFirestoreData());
    expect(r.stops.map((s) => s.customerName), ['あ 一郎', 'い 花子']);
    expect(r.stops.first.lat, 42.92);
    expect(r.optimizedAt, DateTime(2026, 11, 25, 8, 30));
    expect(_svc.getDropoffRoutes(_date).single.vehicleName, '車両B');
  });

  test('更新しても作成日時は残り、記録者は更新した担当者になる', () async {
    await _svc.saveRoute(_route());
    await _settle();
    final created = (await _col().doc('${_date}_pickup_0').get()).data()!['createdAt'];
    StaffSession.instance.debugSet(
        facilityId: FakeBackend.defaultFacilityId, staffId: FakeBackend.staffB.id);
    final r = _svc.getPickupRoutes(_date).single..stops.removeAt(1);
    await _svc.saveRoute(r);
    await _settle();
    final d = (await _col().doc('${_date}_pickup_0').get()).data()!;
    expect(d['createdAt'], created);
    expect(d['updatedByStaffName'], '佐藤');
    expect((d['stops'] as List).length, 1);
  });

  test('担当者が未選択なら保存せず、画面のルートを保存先の内容に戻す', () async {
    await _svc.saveRoute(_route());
    await _settle();
    StaffSession.instance.debugSet(
        facilityId: FakeBackend.defaultFacilityId, staffId: null);
    final r = _svc.getPickupRoutes(_date).single;
    r.stops.removeAt(0); // 画面で並びを変えた（まだ保存していない）
    await expectLater(_svc.saveRoute(r), throwsA(isA<StaffNotSelectedException>()));
    expect(r.stops.length, 2, reason: '画面の内容を元に戻す');
    expect(((await _col().doc('${_date}_pickup_0').get()).data()!['stops'] as List).length, 2);
  });

  test('ルートの削除・日付ごとの全削除', () async {
    await _svc.saveRoute(_route());
    await _svc.saveRoute(_route(v: 1));
    await _svc.deleteRoute(_date, 0, TransportType.pickup);
    await _settle();
    expect(_svc.getPickupRoutes(_date).map((r) => r.vehicleIndex), [1]);
    expect((await _col().get()).docs.map((d) => d.id), ['${_date}_pickup_1']);
    await _svc.clearDate(_date);
    await _settle();
    expect(_svc.getRoutesByDate(_date), isEmpty);
    expect((await _col().get()).docs, isEmpty);
  });

  test('別の端末の変更が開き直さずに届き、変更通知が出る', () async {
    var notified = 0;
    void onChange() => notified++;
    _svc.addListener(onChange);
    addTearDown(() => _svc.removeListener(onChange));
    await _col().doc('${_date}_dropoff_0').set({
      ..._route(type: TransportType.dropoff).toFirestoreData(),
      'vehicleName': '他端末の車',
      'updatedByStaffName': '別端末',
    });
    await _settle();
    expect(_svc.getDropoffRoutes(_date).single.vehicleName, '他端末の車');
    expect(notified, greaterThan(0));
  });
}
