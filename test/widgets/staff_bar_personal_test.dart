// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/screens/login_screen.dart';
import 'package:linkday_app/services/staff_service.dart';
import 'package:linkday_app/widgets/staff_bar.dart';

/// ステップ2 段階3: 担当者の帯（個人アカウント）とログイン画面の Google ボタン
void main() {
  tearDown(() {
    StaffSession.instance.debugSet();
    StaffService.instance.debugSetCache(const []);
  });

  Future<void> pumpBar(WidgetTester t) async {
    final key = GlobalKey<NavigatorState>();
    await t.pumpWidget(MaterialApp(
      navigatorKey: key,
      home: Scaffold(body: StaffBar(navigatorKey: key)),
    ));
    await t.pump();
  }

  testWidgets('個人アカウント: 「担当：本人」だけを出し、「変更」は出さず押しても何も開かない', (t) async {
    StaffService.instance.debugSetCache(const [
      Staff(id: 'haru', name: '職員 春子', loginEnabled: true),
      Staff(id: 'natsu', name: '職員 夏男'),
    ]);
    StaffSession.instance.debugSet(facilityId: 'f', fixedStaffId: 'haru');
    await pumpBar(t);
    expect(find.text('担当：職員 春子'), findsOneWidget);
    expect(find.text('変更'), findsNothing);
    expect(find.text('選択'), findsNothing);
    await t.tap(find.byKey(const Key('staffBar')));
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('共用端末: 従来どおり「変更」が出て、押すと選択画面が開く', (t) async {
    StaffService.instance
        .debugSetCache(const [Staff(id: 'natsu', name: '職員 夏男')]);
    StaffSession.instance.debugSet(facilityId: 'f', staffId: 'natsu');
    await pumpBar(t);
    expect(find.text('担当：職員 夏男'), findsOneWidget);
    expect(find.text('変更'), findsOneWidget);
    await t.tap(find.byKey(const Key('staffBar')));
    await t.pumpAndSettle();
    expect(find.text('担当者を選んでください'), findsOneWidget);
  });

  testWidgets('ログイン画面: メールアドレスのログインを残し、Googleでログインを足す（高さ48以上）', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(const MaterialApp(home: LoginScreen()));
    await t.pump();
    expect(find.byKey(const Key('loginButton')), findsOneWidget);
    final g = find.byKey(const Key('googleLoginButton'));
    expect(g, findsOneWidget);
    expect(find.text('Googleでログイン'), findsOneWidget);
    expect(t.getSize(g).height, greaterThanOrEqualTo(48));
  });
}
