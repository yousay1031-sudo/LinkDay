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
  testWidgets('最初の画面の組み立て中に開始しても、組み立て中の更新が起きない（回帰）', (tester) async {
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

  // 回帰（ステップ2 段階4）: 職員管理などを開いたまま在籍終了にされると、
  // 「事業所に登録されていません」が上の画面に隠れて見えなかった。
  testWidgets('開いたまま在籍終了にされると、上の画面を閉じて「登録されていません」を出す', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // ホーム画面のダッシュボードのカード（幅 259・高さ 92）が、テスト用のフォントでは
    // 2 ピクセルはみ出す（この変更とは別の既存の事柄。範囲外として報告）。
    // このテストはゲートの切り替えを見るため、そのはみ出しの警告だけを除く。
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d
          .exceptionAsString()
          .contains('A RenderFlex overflowed by 2.0 pixels')) {
        return;
      }
      prev?.call(d);
    };
    addTearDown(() => FlutterError.onError = prev);
    final db = FakeFirebaseFirestore();
    await tester.runAsync(() async {
      await db
          .collection('memberships')
          .doc('g-natsu')
          .set({'facilityId': 'f1', 'kind': 'personal', 'staffId': 'natsu'});
      await db
          .collection('facilities')
          .doc('f1')
          .collection('staff')
          .doc('natsu')
          .set({'name': '職員 夏男', 'isActive': true, 'loginEnabled': true});
    });
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: FacilityGate(uid: 'g-natsu', db: db),
    ));
    for (var i = 0; i < 20 && !DataSession.instance.isReady; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(DataSession.instance.isReady, isTrue);
    navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('上に開いた画面'))));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('上に開いた画面'), findsOneWidget);

    // 管理者が別の端末で在籍終了にした
    await tester.runAsync(() async {
      await db
          .collection('facilities')
          .doc('f1')
          .collection('staff')
          .doc('natsu')
          .update({'isActive': false});
    });
    for (var i = 0; i < 20 && DataSession.instance.isReady; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    // 上の画面を閉じるアニメーションが終わるまで進める
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(DataSession.instance.status, DataSessionStatus.notMember);
    expect(navKey.currentState!.canPop(), isFalse);
    expect(find.text('上に開いた画面'), findsNothing);
    expect(find.byKey(const Key('facilityGateNotMember')), findsOneWidget);
  });
}
