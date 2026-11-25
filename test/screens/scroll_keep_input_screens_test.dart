import 'dart:io';

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/customer_edit_screen.dart';
import 'package:linkday_app/screens/login_screen.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/vacancy_notification_service.dart';
import 'package:linkday_app/widgets/vacancy_notice_dialog.dart';
import 'package:linkday_app/widgets/unfocus_offscreen_text_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 設定以外の縦にスクロールする入力画面（顧客の新規登録・編集、ログイン）でも、
/// 入力中の欄が画面の外に出たらフォーカスを外す部品（UnfocusOffscreenTextField）が効き、
/// 入力が残ること。
///
/// テストでは、入力の接続が開いたまま欄が画面の外から戻ったときに Flutter Web（読み上げ有効）が
/// 空の内容を送り返す動き（設定画面で起きていたもの）を testTextInput で再現する。
void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_scroll_keep_');
    Hive.init(tmp.path);
    await SettingsService.instance.init();
    await FakeBackend.attachWithStaff();
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  EditableText editable(WidgetTester t, Finder f) => t.widget<EditableText>(
      find.descendant(of: f, matching: find.byType(EditableText)));

  /// [field] に入力 → [away] だけドラッグして画面の外へ → 戻る
  Future<void> roundTrip(
      WidgetTester t, Widget screen, Finder field, String value, double away,
      {Future<void> Function()? prepare}) async {
    await t.pumpWidget(MaterialApp(home: screen));
    await t.pump(const Duration(milliseconds: 500));
    await prepare?.call();
    expect(find.byType(UnfocusOffscreenTextField), findsWidgets);
    final list = find.byType(Scrollable).first;
    await t.scrollUntilVisible(field, 200, scrollable: list);
    await t.pumpAndSettle();
    await t.tap(field);
    await t.enterText(field, value);
    await t.pump();
    final ctrl = editable(t, field).controller;
    expect(ctrl.text, value);

    await t.drag(list, Offset(0, away));
    await t.pumpAndSettle();
    final r = t.getRect(field);
    final vp = t.getRect(list); // スクロールの表示範囲（ダイアログでは画面より狭い）
    expect(r.bottom <= vp.top || r.top >= vp.bottom, isTrue,
        reason: '欄が表示範囲の外に出ている');
    expect(editable(t, field).focusNode.hasFocus, isFalse,
        reason: '画面の外に出た時点でフォーカスが外れる');
    await t.drag(list, Offset(0, -away));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(field, 200, scrollable: list);
    await t.pumpAndSettle();
    if (t.testTextInput.hasAnyClients) {
      t.testTextInput.updateEditingValue(TextEditingValue.empty);
      await t.pump();
    }
    expect(ctrl.text, value, reason: 'スクロールで画面の外に出て戻っても入力が残る');
    await t.pumpWidget(const SizedBox.shrink());
  }

  group('顧客の新規登録・編集', () {
    testWidgets('新規登録: 氏名（一番上の欄。下へスクロールして戻る）', (t) async {
      await t.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await roundTrip(t, const CustomerEditScreen(),
          find.widgetWithText(TextFormField, '氏名 *'), '検証 太郎', -3000);
    });

    testWidgets('新規登録: 備考（一番下の欄。上へスクロールして戻る）', (t) async {
      await t.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await roundTrip(t, const CustomerEditScreen(),
          find.widgetWithText(TextFormField, '備考'), '検証の備考', 6000);
    });

    testWidgets('編集: 電話番号', (t) async {
      await t.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = Customer(id: 'c-scroll', name: '仮名 一郎', nameKana: 'カメイ イチロウ');
      await roundTrip(t, CustomerEditScreen(customer: c),
          find.widgetWithText(TextFormField, '電話番号'), '0000', -3000);
    });
  });

  testWidgets('空き枠の LINE 通知ダイアログ: 今回だけ編集する本文', (t) async {
    await t.binding.setSurfaceSize(const Size(600, 380));
    addTearDown(() => t.binding.setSurfaceSize(null));
    // 既存の候補の行（ListTile を色付きの DecoratedBox で包んでいる）がデバッグ時に出す
    // 警告だけは無視する（この確認とは別の、前からある表示上の注意。報告済み）
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.exceptionAsString().contains('ListTile background color')) return;
      original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);
    final dialog = VacancyNoticeDialog(
      candidates: VacancyCandidateResult(
          date: DateTime(2026, 11, 25),
          absentCustomerIds: const [],
          linked: const [
            // ダミーの候補（送信はしない。本文の欄を出すため）
            VacancyCandidate(
                customerId: 'c-dummy',
                childName: '仮名 花子',
                lineUserId: 'dummy-line-id',
                remainingProjected: 3,
                regularDays: [1]),
          ],
          unlinked: const []),
      absentChildName: '仮名 一郎',
    );
    await roundTrip(t, Scaffold(body: Center(child: dialog)),
        find.byType(TextField).first, '今回だけの本文', 3000, prepare: () async {
      final edit = find.text('今回だけ編集');
      await t.scrollUntilVisible(edit, 100,
          scrollable: find.byType(Scrollable).first);
      await t.tap(edit);
      await t.pumpAndSettle();
    });
  });

  testWidgets('ログイン: メールアドレス（小さい画面でスクロールする）', (t) async {
    await t.binding.setSurfaceSize(const Size(380, 260));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await roundTrip(t, const LoginScreen(), find.byType(TextFormField).first,
        'zz@example.invalid', -800);
  });
}
