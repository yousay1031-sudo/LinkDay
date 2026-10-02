import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/screens/settings_screen.dart';
import 'package:linkday_app/services/settings_service.dart';

/// 回帰テスト: SettingsScreen 初回 build で
/// "Null check operator used on a null value" / RangeError が出ないこと。
///
/// 原因: 車両コントローラが postFrameCallback で遅延生成されていたため、
///       初回 build で _vehicleNameCtrls[i] が範囲外アクセスになっていた。
///
/// 実行: flutter test test/settings_screen_null_safety_test.dart
///
/// 【Hive.init / hive パッケージを使う理由】
/// Hive.initFlutter()（hive_flutter）は path_provider 経由で
/// getApplicationDocumentsDirectory() を呼ぶため、VM テストでは
/// MissingPluginException になる。一時ディレクトリを明示指定する
/// Hive.init(path) を使うことで VM 上でも実行可能にしている。
void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_settings_test_');
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

  testWidgets('SettingsScreen 初回 build が空データ状態で例外なく完了する',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    // 初回フレーム（旧コードではここで NullError が発生していた）
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);

    // 車両台数デフォルト 2 → 車両名フィールドが 2 件描画される
    expect(find.text('車両1の名前'), findsOneWidget);
    expect(find.text('車両2の名前'), findsOneWidget);
    expect(find.text('車両管理'), findsOneWidget);
  });
}
