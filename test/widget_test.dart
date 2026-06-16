// LinkDay - ウィジェットテスト基盤
//
// 各機能の実装に合わせてテストを追加していきます。

import 'package:flutter_test/flutter_test.dart';

import 'package:linkday_app/main.dart';

void main() {
  testWidgets('LinkDay アプリが起動してログイン画面が表示される', (WidgetTester tester) async {
    // アプリを起動
    await tester.pumpWidget(const LinkDayApp());
    await tester.pumpAndSettle();

    // ログイン画面の要素が表示されることを確認
    expect(find.text('LinkDay'), findsWidgets);
    expect(find.text('放課後等デイサービス管理システム'), findsOneWidget);
    expect(find.text('ログイン'), findsOneWidget);
  });
}
