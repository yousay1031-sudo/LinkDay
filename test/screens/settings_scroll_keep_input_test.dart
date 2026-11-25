import 'dart:io';

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linkday_app/screens/settings_screen.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 設定画面: 保存する前に、入力中の欄を画面の外までスクロールして戻っても入力が消えないこと。
///
/// ブラウザ（読み上げ有効）では、入力中の欄が画面外から戻ると、Flutter Web が
/// 空の内容を「入力された内容」として送り返し、入力が消えていた。
/// テストではその送り返しを testTextInput で再現する（入力の接続が開いたままなら送られる）。
void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_settings_scroll_');
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

  Future<void> roundTrip(WidgetTester t, Finder field, String value,
      {Size size = const Size(900, 700)}) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await t.pump(const Duration(milliseconds: 500));
    final list = find.byType(Scrollable).first;
    await t.scrollUntilVisible(field, 200, scrollable: list);
    await t.pumpAndSettle();
    await t.tap(field);
    await t.enterText(field, value);
    await t.pump();
    final ctrl = editable(t, field).controller;
    expect(ctrl.text, value);
    expect(t.testTextInput.hasAnyClients, isTrue, reason: '入力中');

    // 画面の外まで（上の端へ）→ また入力欄まで
    await t.drag(list, const Offset(0, 12000));
    await t.pumpAndSettle();
    final view = t.getRect(list);
    final r = t.getRect(field);
    expect(r.top >= view.bottom || r.bottom <= view.top, isTrue,
        reason: '上の端へ戻したとき、入力欄が画面の外にあること（テストの前提）');
    await t.scrollUntilVisible(field, 200, scrollable: list);
    await t.pumpAndSettle();

    // Flutter Web（読み上げ有効）の動き: 入力の接続が開いたままだと、
    // 新しく作られた空の <input> の内容が送り返される
    if (t.testTextInput.hasAnyClients) {
      t.testTextInput.updateEditingValue(TextEditingValue.empty);
      await t.pump();
    }
    expect(ctrl.text, value, reason: 'スクロールで画面の外に出て戻っても入力が残る');
    expect(editable(t, field).focusNode.hasFocus, isFalse,
        reason: '画面の外に出た時点でフォーカスが外れる');
    await t.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('1日の最大利用者数', (t) async {
    await roundTrip(t, find.widgetWithText(TextFormField, '1日の最大利用者数'), '15');
  });

  testWidgets('車両の定員', (t) async {
    // 設定画面から職員の欄を職員管理へ移したため、定員の欄が上に寄った。
    // 上の端へ戻したときに画面の外へ出るよう、画面の高さを低くする
    await roundTrip(t, find.widgetWithText(TextFormField, '定員（名）').last, '9',
        size: const Size(900, 420));
  });

  testWidgets('管理者 LINE userId', (t) async {
    await roundTrip(t, find.byKey(const Key('adminLineUserIdField')), 'Uabc');
  });

  testWidgets('事業所名（画面の一番上の欄。下へスクロールして戻る）', (t) async {
    await t.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await t.pump(const Duration(milliseconds: 500));
    final field = find.widgetWithText(TextFormField, '事業所名');
    final list = find.byType(Scrollable).first;
    await t.tap(field);
    await t.enterText(field, '検証の事業所');
    await t.pump();
    final ctrl = editable(t, field).controller;
    await t.drag(list, const Offset(0, -6000));
    await t.pumpAndSettle();
    await t.drag(list, const Offset(0, 12000));
    await t.pumpAndSettle();
    if (t.testTextInput.hasAnyClients) {
      t.testTextInput.updateEditingValue(TextEditingValue.empty);
      await t.pump();
    }
    expect(ctrl.text, '検証の事業所');
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('画面の中でスクロールしただけではフォーカスは外れない', (t) async {
    await t.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await t.pump(const Duration(milliseconds: 500));
    final field = find.widgetWithText(TextFormField, '事業所名');
    await t.tap(field);
    await t.enterText(field, '検証の事業所');
    await t.pump();
    await t.drag(find.byType(Scrollable).first, const Offset(0, -40));
    await t.pumpAndSettle();
    expect(editable(t, field).focusNode.hasFocus, isTrue);
    expect(t.testTextInput.hasAnyClients, isTrue);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
