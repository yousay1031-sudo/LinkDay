import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/screens/settings_screen.dart';
import 'package:linkday_app/services/settings_service.dart';

/// Day 14: 設定画面「LINE応募の受付時間」の操作テスト
void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_ttl_ui_');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(7)) {
      Hive.registerAdapter(AppSettingsAdapter());
    }
    await SettingsService.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// タップを実時間ゾーン(runAsync)内で行う。
  /// onPressed が FakeAsync ゾーンで Hive 書き込みを開始すると、
  /// 継続が fake のマイクロタスクに積まれたまま残り、tearDownAll の
  /// Hive.close が永久に待つ。実時間ゾーンで開始すれば普通に完了する。
  Future<void> tapReal(WidgetTester tester, Key key) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(key));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> settle(WidgetTester tester) async {
    // Hive の書き込みは複数段の実 IO を挟み、各段の継続は FakeAsync の
    // マイクロタスクとして積まれる。実時間待ちと pump を交互に繰り返さないと
    // 完了せず、次テストの Hive.put が永久に詰まる。
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('既定の 6 時間が表示される', (tester) async {
    await tester.runAsync(
        () => SettingsService.instance.updateSlotTtlHours(6));
    await open(tester);
    expect(find.text('LINE応募の受付時間'), findsOneWidget);
    expect(find.text('6 時間'), findsOneWidget);
  });

  testWidgets('＋で 1 時間延び、AppSettings に保存される', (tester) async {
    await tester.runAsync(
        () => SettingsService.instance.updateSlotTtlHours(6));
    await open(tester);
    await tapReal(tester, const Key('slotTtlPlus'));

    expect(find.text('7 時間'), findsOneWidget);
    expect(SettingsService.instance.getSettings().slotTtlHours, 7);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

  testWidgets('－で 1 時間縮む', (tester) async {
    await tester.runAsync(
        () => SettingsService.instance.updateSlotTtlHours(6));
    await open(tester);
    await tapReal(tester, const Key('slotTtlMinus'));

    expect(find.text('5 時間'), findsOneWidget);
    expect(SettingsService.instance.getSettings().slotTtlHours, 5);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

  testWidgets('下限(1時間)で － が無効になる', (tester) async {
    await tester.runAsync(
        () => SettingsService.instance.updateSlotTtlHours(1));
    await open(tester);
    final minus = tester.widget<IconButton>(find.byKey(const Key('slotTtlMinus')));
    expect(minus.onPressed, isNull);
    expect(find.text('1 時間'), findsOneWidget);
  });

  testWidgets('上限(24時間)で ＋ が無効になる', (tester) async {
    await tester.runAsync(
        () => SettingsService.instance.updateSlotTtlHours(24));
    await open(tester);
    final plus = tester.widget<IconButton>(find.byKey(const Key('slotTtlPlus')));
    expect(plus.onPressed, isNull);
    expect(find.text('24 時間'), findsOneWidget);
  });

  testWidgets('再度画面を開いても保存済みの値が表示される', (tester) async {
    await tester.runAsync(
        () => SettingsService.instance.updateSlotTtlHours(11));
    await open(tester);
    expect(find.text('11 時間'), findsOneWidget);
  });
}
