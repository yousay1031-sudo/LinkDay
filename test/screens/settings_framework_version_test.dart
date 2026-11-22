import 'dart:convert';
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

/// 設定のアプリ情報: Flutter の版は、実際に使っている SDK の版と同じ（手で書いた値ではない）
void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_fw_version_');
    Hive.init(tmp.path);
    await SettingsService.instance.init();
    await FakeBackend.attachWithStaff();
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  /// 実行中の Flutter SDK の版（SDK 自身の記録から読む）
  String sdkVersion() {
    final root = Platform.environment['FLUTTER_ROOT'];
    expect(root, isNotNull, reason: 'flutter test は FLUTTER_ROOT を設定する');
    final f = File('$root/bin/cache/flutter.version.json');
    return (jsonDecode(f.readAsStringSync()) as Map)['frameworkVersion']
        as String;
  }

  test('表示する版は、実行中の SDK の版と同じ', () {
    expect(frameworkVersionLabel, 'Flutter ${sdkVersion()}');
    expect(frameworkVersionLabel, isNot(contains('不明')));
  });

  testWidgets('設定画面のアプリ情報に表示される', (t) async {
    await t.binding.setSurfaceSize(const Size(900, 4000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Flutter ${sdkVersion()}'), findsOneWidget);
    expect(find.text('Flutter 3.35.4'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
