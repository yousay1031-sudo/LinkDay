import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:linkday_app/data/data_session.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/services/staff_service.dart';

/// テスト用の保存先（エミュレータ不要のメモリ上の Firestore）。
///
/// 本番と同じ facilities/{facilityId}/... の形でデータを持ち、
/// 各サービスを attach する。担当者 [currentStaffId] を選択済みにできる。
class FakeBackend {
  FakeBackend._(this.db, this.facilityId);

  final FakeFirebaseFirestore db;
  final String facilityId;

  static const String defaultFacilityId = 'f-test';

  static Future<FakeBackend> attach({
    String facilityId = defaultFacilityId,
    List<Staff> staff = const [],
    String? currentStaffId,
  }) async {
    final db = FakeFirebaseFirestore();
    final backend = FakeBackend._(db, facilityId);
    for (final s in staff) {
      await backend.staffCol.doc(s.id).set({
        ...s.toCreateMap(),
        Staff.fIsActive: s.isActive,
        'createdAt': DateTime(2026, 1, 1).add(Duration(minutes: staff.indexOf(s))),
        'updatedByStaffId': null,
        'updatedByStaffName': 'テスト',
      });
    }
    FacilityContext.instance.attach(db, facilityId);
    await StaffService.instance.attach();
    StaffSession.instance.debugSet(facilityId: facilityId, staffId: currentStaffId);
    return backend;
  }

  /// テストで使う標準の職員 2 名
  static const Staff staffA = Staff(id: 's-a', name: '山田');
  static const Staff staffB = Staff(id: 's-b', name: '佐藤');

  /// 職員 2 名・山田を選択済みで接続する（多くのテストの既定）
  static Future<FakeBackend> attachWithStaff({String facilityId = defaultFacilityId}) =>
      attach(facilityId: facilityId, staff: const [staffA, staffB], currentStaffId: staffA.id);

  CollectionReference<Map<String, dynamic>> get staffCol => db
      .collection(FsPaths.facilities)
      .doc(facilityId)
      .collection(FsPaths.staff);

  static Future<void> detach() async {
    StaffSession.instance.prompter = null;
    await DataSession.instance.stop();
    DataSession.instance.debugReset();
  }
}
