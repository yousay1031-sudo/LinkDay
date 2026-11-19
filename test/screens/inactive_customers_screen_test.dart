// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/inactive_customers_screen.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

Widget _app() => MaterialApp(
      // 本番と同じテーマ（ボタンの minimumSize が無限幅でも壊れないこと）
      theme: AppTheme.lightTheme,
      home: const InactiveCustomersScreen(),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      await FakeBackend.attachWithStaff();
      for (final (id, name, kana) in [
        ('a', '在籍 一郎', 'ザイセキ イチロウ'),
        ('b', '退所 花子', 'タイショ ハナコ'),
      ]) {
        await CustomerService.instance
            .addCustomer(Customer(id: id, name: name, nameKana: kana));
      }
      await CustomerService.instance.deleteCustomer('b');
      // 偽の保存先は書き込みごとに通知するため、最後の通知まで待つ
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  }

  testWidgets('在籍終了の顧客だけを一覧に出す', (tester) async {
    await seed(tester);
    await tester.pumpWidget(_app());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('退所 花子'), findsOneWidget);
    expect(find.text('在籍 一郎'), findsNothing);
    expect(find.textContaining('在籍終了 1 名'), findsOneWidget);
  });

  testWidgets('「在籍に戻す」→確認で在籍中に戻り、一覧から消える', (tester) async {
    await seed(tester);
    await tester.pumpWidget(_app());
    await tester.pump();

    await tester.tap(find.byKey(const Key('restoreCustomer_b')));
    await tester.pumpAndSettle();
    expect(find.text('「退所 花子」を在籍に戻しますか？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('restoreCustomerConfirm')));
    await tester.pumpAndSettle();

    expect(CustomerService.instance.getCustomerById('b')!.isActive, isTrue);
    expect(find.text('在籍終了の顧客はいません'), findsOneWidget);
    expect(find.text('「退所 花子」を在籍に戻しました'), findsOneWidget);
  });

  testWidgets('確認でキャンセルすると何も変えない', (tester) async {
    await seed(tester);
    await tester.pumpWidget(_app());
    await tester.pump();
    await tester.tap(find.byKey(const Key('restoreCustomer_b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(CustomerService.instance.getCustomerById('b')!.isActive, isFalse);
    expect(find.text('退所 花子'), findsOneWidget);
  });
}
