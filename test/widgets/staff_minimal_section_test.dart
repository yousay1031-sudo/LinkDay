// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/services/staff_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:linkday_app/widgets/staff_minimal_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

Widget _app() => MaterialApp(
      // 本番と同じテーマで描く（ボタンの minimumSize が横並びで壊れないことを確かめる）
      theme: AppTheme.lightTheme,
      home: const Scaffold(
        body: SingleChildScrollView(child: StaffMinimalSection()),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  testWidgets('未接続（ログイン前）なら何も表示しない', (tester) async {
    await tester.pumpWidget(_app());
    expect(find.byKey(const Key('staffMinimalSection')), findsNothing);
  });

  testWidgets('本番テーマで入力欄と追加ボタンが横並びで描ける（回帰）', (tester) async {
    await tester.runAsync(FakeBackend.attachWithStaff);
    await tester.pumpWidget(_app());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('staffNameField')), findsOneWidget);
    expect(find.byKey(const Key('staffAddButton')), findsOneWidget);
    expect(find.text('山田'), findsOneWidget);
    expect(find.text('佐藤'), findsOneWidget);
  });

  testWidgets('名前を入れて追加すると一覧に出る・同名は追加できない', (tester) async {
    await tester.runAsync(FakeBackend.attachWithStaff);
    await tester.pumpWidget(_app());
    await tester.pump();

    await tester.enterText(find.byKey(const Key('staffNameField')), '鈴木');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('staffAddButton')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(StaffService.instance.getActiveStaff().map((s) => s.name), contains('鈴木'));

    await tester.enterText(find.byKey(const Key('staffNameField')), '山田');
    await tester.tap(find.byKey(const Key('staffAddButton')));
    await tester.pump();
    expect(find.text('同じ名前の職員がすでにいます'), findsOneWidget);
  });
}
