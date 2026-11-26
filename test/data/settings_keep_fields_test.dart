import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 回帰: 設定のどの項目を保存しても、ほかの項目が既定値に戻らない。
///
/// 以前は、事業所情報・車両・時間・受付時間・管理者の LINE・空き枠通知の保存が、
/// 予約の項目 `staffPinEnabled` を引き継がずに既定値（false）へ戻していた
/// （保存は「変わった項目だけを書く」ので、戻った値が「変わった項目」として書かれる）。
DocumentReference<Map<String, dynamic>> _doc() =>
    FacilityContext.instance.col(FsPaths.settings).doc(FsPaths.settingsDocId);
Future<Map<String, dynamic>> _stored() async => (await _doc().get()).data()!;
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

/// すべての項目を既定値と違う値にした設定
final Map<String, dynamic> _nonDefault = {
  'facilityName': '架空の事業所',
  'facilityAddress': '架空の住所',
  'facilityLat': 42.5,
  'facilityLng': 143.5,
  'vehicleCount': 3,
  'vehicleNames': ['車1', '車2', '車3'],
  'vehicleCapacities': [4, 5, 6],
  'maxStudentsPerDay': 17,
  'defaultPickupStart': '09:15',
  'defaultDropoffEnd': '17:45',
  'vacancyReplyDeadline': '11:30',
  'vacancyMessageTemplate': '架空の文面',
  'slotTtlHours': 9,
  'adminLineUserId': 'U${'a' * 32}',
  'staffPinEnabled': true,
  'journalActivityOptions': ['架空の内容'],
};

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FakeBackend.attachWithStaff();
    await _doc().set({..._nonDefault, 'updatedByStaffName': '検証データ'});
    await _settle();
  });
  tearDown(FakeBackend.detach);

  final svc = SettingsService.instance;

  // 保存の処理ごとに、変える項目と、その保存
  final cases = <String, (Set<String>, Future<void> Function())>{
    '事業所情報（住所は同じ）': (
      {'facilityName'},
      () => svc.updateFacility('別の架空の事業所', '架空の住所'),
    ),
    '車両': (
      {'vehicleCount', 'vehicleNames', 'vehicleCapacities'},
      () => svc.updateVehicles(2, ['車A', '車B'], [3, 3]),
    ),
    '送迎の時間・定員': (
      {'defaultPickupStart', 'defaultDropoffEnd', 'maxStudentsPerDay'},
      () => svc.updateOperatingHours('08:00', '16:00', 12),
    ),
    '事業所の位置': (
      {'facilityLat', 'facilityLng'},
      () => svc.saveFacilityGeocode(42.9, 143.2),
    ),
    'LINE 応募の受付時間': ({'slotTtlHours'}, () => svc.updateSlotTtlHours(4)),
    '管理者の LINE': (
      {'adminLineUserId'},
      () => svc.updateAdminLineUserId('U${'b' * 32}').then((_) {}),
    ),
    '空き枠通知': (
      {'vacancyReplyDeadline', 'vacancyMessageTemplate'},
      () => svc.updateVacancyNotice(deadline: '12:00', template: '別の文面'),
    ),
    '業務日誌の選択肢': (
      {'journalActivityOptions'},
      () => svc.updateJournalActivityOptions(['別の内容']),
    ),
  };

  for (final MapEntry(key: name, value: (changed, save)) in cases.entries) {
    test('$name を保存しても、ほかの項目（staffPinEnabled を含む）は変わらない', () async {
      expect(svc.getSettings().staffPinEnabled, isTrue); // 前提: 読み込めている
      await save();
      await _settle();
      final d = await _stored();
      for (final k in _nonDefault.keys) {
        if (changed.contains(k)) {
          expect(d[k], isNot(_nonDefault[k]), reason: '$k は変わるはず');
        } else {
          expect(d[k], _nonDefault[k], reason: '$k が変わった');
        }
      }
      expect(svc.getSettings().staffPinEnabled, isTrue);
    });
  }
}
