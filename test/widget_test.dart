// LinkDay - ウィジェットテスト基盤
//
// 各機能の実装に合わせてテストを追加していきます。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:linkday_app/screens/login_screen.dart';
import 'package:linkday_app/theme/app_theme.dart';

/// ログイン画面の起動テスト
///
/// 【LinkDayApp 全体を pump しない理由】
/// LinkDayApp は AuthGate → AuthService.authStateChanges（Firebase Auth）に
/// 依存しており、VM テストでは Firebase.initializeApp() が実行されないため
/// FirebaseException が送出される。Firebase 初期化のモックは
/// プラットフォームチャネルの広範なスタブが必要で費用対効果が低いため、
/// 認証ゲートを介さず LoginScreen 単体を直接検証する方針とした。
/// （LoginScreen は build 時に Firebase を触らず、ログインボタン押下時のみ
///   AuthService を呼ぶため、描画検証は VM で安全に実行できる）
void main() {
  testWidgets('ログイン画面が表示され、主要要素が揃っている', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: const LoginScreen(),
    ));
    await tester.pump();

    // 初回 build で例外が出ないこと
    expect(tester.takeException(), isNull);

    // ログイン画面の要素が表示されることを確認
    expect(find.text('LinkDay'), findsWidgets);
    expect(find.text('放課後等デイサービス管理システム'), findsOneWidget);
    expect(find.text('ログイン'), findsWidgets);
  });

  testWidgets('メールアドレス・パスワード入力欄が存在する', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: const LoginScreen(),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // TextFormField が 2 つ（メール / パスワード）
    expect(find.byType(TextFormField), findsNWidgets(2));
  });
}
