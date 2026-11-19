import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/data_session.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/widgets/staff_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

Future<void> _startSession() async {
  final db = FakeFirebaseFirestore();
  await db.collection('memberships').doc('u1').set({'facilityId': 'fac-1'});
  final staff = db.collection('facilities').doc('fac-1').collection('staff');
  await staff.doc('s1').set({'name': '山田', 'isActive': true});
  await staff.doc('s2').set({'name': '佐藤', 'isActive': true});
  await staff.doc('s3').set({'name': '退職者', 'isActive': false});
  await DataSession.instance.start('u1', db: db);
}

Widget _app(GlobalKey<NavigatorState> navKey) => MaterialApp(
      navigatorKey: navKey,
      builder: (context, child) =>
          StaffBarScope(navigatorKey: navKey, child: child!),
      home: const Scaffold(body: Text('本文')),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  testWidgets('ログイン前（未接続）は担当者の帯を出さない', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_app(navKey));
    expect(find.byKey(const Key('staffBar')), findsNothing);
    expect(find.text('本文'), findsOneWidget);
  });

  testWidgets('未選択なら注意表示 → タップで在籍中の職員だけが出て、選ぶと帯に名前が出る',
      (tester) async {
    await tester.runAsync(_startSession);
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_app(navKey));
    await tester.pump();

    expect(find.text('担当者が選ばれていません（タップして選択）'), findsOneWidget);
    // 回帰: 帯が読み上げ・操作補助（セマンティクス）から消えないこと。
    // Navigator 内の BlockSemantics に、先に描いた帯が捨てられていた。
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('担当者が選ばれていません')), findsOneWidget);
    semantics.dispose();

    await tester.tap(find.byKey(const Key('staffBar')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('staffPickerDialog')), findsOneWidget);
    expect(find.text('山田'), findsOneWidget);
    expect(find.text('佐藤'), findsOneWidget);
    expect(find.text('退職者'), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('staffPick_s2')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('staffPickerDialog')), findsNothing);
    expect(find.text('担当：佐藤'), findsOneWidget);
    expect(StaffSession.instance.current?.id, 's2');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(StaffSession.prefsKey('fac-1')), 's2');
  });
}
