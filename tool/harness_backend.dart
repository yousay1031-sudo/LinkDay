// ハーネス用（本番ビルドには含まれない）: メモリ上の偽の Firestore に接続し、
// 担当者「ハーネス」を選んだ状態にする（顧客は Firestore 保存のため）。
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';

import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/services/staff_service.dart';

Future<void> attachHarnessBackend() async {
  final db = FakeFirebaseFirestore();
  FacilityContext.instance.attach(db, 'harness');
  // 職員の登録は管理者だけになったため、偽の保存先へ直接置く
  const staff = Staff(id: 'harness-staff', name: 'ハーネス');
  await FacilityContext.instance
      .col(FsPaths.staff)
      .doc(staff.id)
      .set({...staff.toCreateMap(), 'updatedByStaffName': 'ハーネス'});
  await StaffService.instance.attach();
  await StaffSession.instance.select(StaffService.instance.getById(staff.id)!);
}
