import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 段階7: 設定を Firestore（settings/app）に移したことの確認
SettingsService get _svc => SettingsService.instance;
DocumentReference<Map<String, dynamic>> _doc() =>
    FacilityContext.instance.col(FsPaths.settings).doc(FsPaths.settingsDocId);
Future<Map<String, dynamic>?> _stored() async => (await _doc().get()).data();
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FakeBackend.attachWithStaff();
  });
  tearDown(FakeBackend.detach);

  test('保存先にまだ無い間は既定値。最初の保存で作られ、担当者が残る', () async {
    expect(await _stored(), isNull);
    expect(_svc.getSettings().vehicleCount, AppSettings().vehicleCount);
    await _svc.updateVehicles(3, ['車両A', '車両B', '車両C'], [6, 6, 4]);
    await _settle();
    final d = (await _stored())!;
    expect(d['vehicleCount'], 3);
    expect(d['vehicleCapacities'], [6, 6, 4]);
    expect(d['updatedByStaffName'], '職員 冬子');
    expect(d['createdAt'], isA<Timestamp>());
    expect(d['staffPinEnabled'], isFalse, reason: '暗証番号は予約のみ（常に false）');
  });

  test('Maps の API キーは Firestore に置かない（端末の SharedPreferences のまま）', () async {
    await _svc.saveJsApiKey('dummy-key-for-test');
    await _svc.updateFacility('見本の事業所', '帯広市（見本）');
    await _settle();
    final d = (await _stored())!;
    expect(d.keys.where((k) => k.toLowerCase().contains('key')), isEmpty);
    expect(d.values.whereType<String>().where((v) => v.contains('dummy-key')), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gmaps_js_key'), 'dummy-key-for-test');
  });

  test('保存先の内容を読み直しても変わらない', () async {
    await _svc.updateFacility('見本の事業所', '帯広市（見本）');
    await _svc.saveFacilityGeocode(42.92, 143.19);
    await _svc.updateSlotTtlHours(8);
    expect(await _svc.updateAdminLineUserId('U1234567890abcdef1234567890abcdef'), isTrue);
    await _settle();
    final before = _svc.getSettings().toFirestoreData();
    await _svc.detach();
    await _svc.attach();
    expect(_svc.getSettings().toFirestoreData(), before);
    expect(_svc.getSettings().facilityLat, 42.92);
  });

  test('変わった項目だけを書く（他の端末が変えた別の項目を上書きしない）', () async {
    await _svc.updateFacility('見本の事業所', '帯広市（見本）');
    await _settle();
    // 別の端末が通知文面を変えた（この端末の購読に届く前）
    await _doc().update({'vacancyMessageTemplate': '他端末の文面', 'updatedByStaffName': '別端末'});
    _svc.debugSetSettings(AppSettings(facilityName: '見本の事業所', facilityAddress: '帯広市（見本）'));
    await _svc.updateVehicles(1, ['1号車'], [8]);
    await _settle();
    final d = (await _stored())!;
    expect(d['vehicleNames'], ['1号車']);
    expect(d['vacancyMessageTemplate'], '他端末の文面');
  });

  test('値が変わっていなければ書かない', () async {
    await _svc.updateSlotTtlHours(8);
    await _settle();
    StaffSession.instance.debugSet(
        facilityId: FakeBackend.defaultFacilityId, staffId: FakeBackend.staffB.id);
    await _svc.updateSlotTtlHours(8);
    await _settle();
    expect((await _stored())!['updatedByStaffName'], '職員 冬子');
  });

  test('担当者が未選択なら保存しない', () async {
    StaffSession.instance.debugSet(
        facilityId: FakeBackend.defaultFacilityId, staffId: null);
    await expectLater(_svc.updateSlotTtlHours(12),
        throwsA(isA<StaffNotSelectedException>()));
    expect(_svc.getSettings().slotTtlHours, AppSettings.defaultSlotTtlHours);
    expect(await _stored(), isNull);
  });

  test('別の端末の変更が開き直さずに届き、変更通知が出る', () async {
    await _svc.updateSlotTtlHours(8);
    await _settle();
    var notified = 0;
    void onChange() => notified++;
    _svc.addListener(onChange);
    addTearDown(() => _svc.removeListener(onChange));
    await _doc().update({'maxStudentsPerDay': 25, 'updatedByStaffName': '別端末'});
    await _settle();
    expect(_svc.getSettings().maxStudentsPerDay, 25);
    expect(notified, greaterThan(0));
  });
}
