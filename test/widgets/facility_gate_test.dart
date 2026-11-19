import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/data_session.dart';
import 'package:linkday_app/widgets/facility_gate.dart';
import 'package:linkday_app/widgets/staff_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  // 回帰: 再読み込み直後（ログイン済みで最初の画面を組み立てるとき）に
  // 担当者の帯が出なかった。ゲートが組み立て中に DataSession を開始し、
  // その通知で上位の帯（StaffBarScope）を組み立て中に更新しようとしていた。
  testWidgets('最初の画面の組み立て中に開始しても、組み立て中の更新が起きない（回帰）',
      (tester) async {
    final db = FakeFirebaseFirestore();
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      builder: (c, child) => StaffBarScope(navigatorKey: navKey, child: child!),
      home: FacilityGate(uid: 'u-none', db: db),
    ));
    expect(tester.takeException(), isNull);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(DataSession.instance.status, DataSessionStatus.notMember);
    expect(find.byKey(const Key('facilityGateNotMember')), findsOneWidget);
  });
}
