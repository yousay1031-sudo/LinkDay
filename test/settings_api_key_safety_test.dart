import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linkday_app/screens/settings_screen.dart';
import 'package:linkday_app/services/settings_service.dart';

import 'support/fake_backend.dart';

/// 回帰テスト: APIキーの読込に失敗している間、読めていない既存値を
/// 空値で上書き・削除しないこと。他の設定項目は引き続き保存できること。
/// （値そのものは出力しない。ダミー文字列のみ使用）
void main() {
  late Directory tmp;
  const dummyKey = 'AIzaDUMMY-not-a-real-key';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({'gmaps_js_key': dummyKey});
    tmp = await Directory.systemTemp.createTemp('linkday_apikey_safety_');
    Hive.init(tmp.path);
    await SettingsService.instance.init();
    // 設定は Firestore（段階7）。偽の保存先と担当者（山田）で接続する
    await FakeBackend.attachWithStaff();
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  Future<String?> storedKey() async =>
      (await SharedPreferences.getInstance()).getString('gmaps_js_key');

  Future<void> open(WidgetTester tester,
      Future<String?> Function() loader) async {
    await tester.binding.setSurfaceSize(const Size(900, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(debugLoadJsApiKey: loader)));
  }

  bool enabled(WidgetTester tester, Key k) {
    final w = tester.widget<ButtonStyleButton>(find.byKey(k));
    return w.onPressed != null;
  }

  String badge(WidgetTester tester) {
    final texts = tester.widgetList<Text>(find.descendant(
        of: find.byKey(const Key('apiKeyStatusBadge')),
        matching: find.byType(Text)));
    return texts.map((t) => t.data).join();
  }

  testWidgets('読込中は保存・テスト・クリアが無効で、バッジは「読込中」', (t) async {
    final gate = Completer<String?>();
    await open(t, () => gate.future);
    await t.pump();
    expect(enabled(t, const Key('apiKeySaveButton')), isFalse);
    expect(enabled(t, const Key('apiKeyTestButton')), isFalse);
    expect(enabled(t, const Key('apiKeyClearButton')), isFalse);
    expect(badge(t), contains('読込中'));
    gate.complete(dummyKey);
    await t.pump(const Duration(milliseconds: 500));
    expect(enabled(t, const Key('apiKeySaveButton')), isTrue);
    expect(badge(t), contains('設定済み'));
  });

  testWidgets('読込失敗: 3操作が無効・バッジは「読込失敗」（未設定と区別）・既存値は不変',
      (t) async {
    await open(t, () async => throw StateError('boom'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('errorRetryMessage')), findsOneWidget);
    expect(badge(t), contains('読込失敗'));
    expect(badge(t), isNot(contains('未設定')));
    expect(enabled(t, const Key('apiKeySaveButton')), isFalse);
    expect(enabled(t, const Key('apiKeyTestButton')), isFalse);
    expect(enabled(t, const Key('apiKeyClearButton')), isFalse);
    // 無効のクリアが赤文字のまま「押せそう」に見えない
    final clearLabel = t.widget<Text>(find.descendant(
        of: find.byKey(const Key('apiKeyClearButton')),
        matching: find.text('クリア')));
    expect(clearLabel.style?.color, isNull);

    // 無効ボタンを押しても保存値は変わらない
    await t.tap(find.byKey(const Key('apiKeySaveButton')),
        warnIfMissed: false);
    await t.tap(find.byKey(const Key('apiKeyClearButton')),
        warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('APIキーをクリア'), findsNothing);
    expect(await t.runAsync(storedKey), dummyKey);
  });

  testWidgets('読込失敗中も他の設定(車両)は保存でき、APIキーは変わらない', (t) async {
    await open(t, () async => throw StateError('boom'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(enabled(t, const Key('saveVehiclesButton')), isTrue);
    await t.runAsync(() async {
      await t.tap(find.byKey(const Key('saveVehiclesButton')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('車両設定を保存しました'), findsOneWidget);
    expect(await t.runAsync(storedKey), dummyKey);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('再試行成功で操作可能へ戻り、バッジが実状態になる', (t) async {
    var fail = true;
    await open(t, () async {
      if (fail) throw StateError('boom');
      return dummyKey;
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(enabled(t, const Key('apiKeySaveButton')), isFalse);
    fail = false;
    await t.tap(find.byKey(const Key('errorRetryButton')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('errorRetryMessage')), findsNothing);
    expect(enabled(t, const Key('apiKeySaveButton')), isTrue);
    expect(enabled(t, const Key('apiKeyTestButton')), isTrue);
    expect(enabled(t, const Key('apiKeyClearButton')), isTrue);
    expect(badge(t), contains('設定済み'));
    expect(badge(t), isNot(contains('読込失敗')));
  });

  testWidgets('エラー通知は liveRegion の Semantics を持つ', (t) async {
    final handle = t.ensureSemantics();
    await open(t, () async => throw StateError('boom'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    final node =
        t.getSemantics(find.byKey(const Key('errorRetryMessage')));
    expect(node.label, contains('APIキーを読み込めませんでした'));
    // ignore: deprecated_member_use
    expect(node.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
    handle.dispose();
  });
}
