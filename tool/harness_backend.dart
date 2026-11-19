// ハーネス用（本番ビルドには含まれない）: メモリ上の偽の Firestore に接続し、
// 担当者「ハーネス」を選んだ状態にする（顧客は Firestore 保存のため）。
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';

import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/services/staff_service.dart';

Future<void> attachHarnessBackend() async {
  FacilityContext.instance.attach(FakeFirebaseFirestore(), 'harness');
  final staff = await StaffService.instance.addStaff('ハーネス');
  await StaffSession.instance.select(staff);
}
