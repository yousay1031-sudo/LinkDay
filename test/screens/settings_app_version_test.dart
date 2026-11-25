import 'dart:convert';
import 'dart:io';

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linkday_app/screens/settings_screen.dart';
import 'package:linkday_app/services/app_version.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 設定のアプリ情報: 「バージョン」は pubspec.yaml の version（手で書いた値ではない）。
///
/// Web ビルドでは flutter が pubspec.yaml から version.json を作る。ここでは
/// flutter と同じ形の version.json（pubspec.yaml から作る）を返す通信に差し替えて確かめる。
void main() {
  late Directory tmp;

  /// pubspec.yaml の version（例: 1.0.0+6）
  String pubspecVersion() {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    return line.substring('version:'.length).trim();
  }

  /// flutter build web が作る version.json と同じ形
  String versionJsonFromPubspec() {
    final v = pubspecVersion().split('+');
    return jsonEncode({
      'app_name': 'linkday_app',
      'version': v[0],
      if (v.length > 1) 'build_number': v[1],
      'package_name': 'linkday_app',
    });
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_app_version_');
    Hive.init(tmp.path);
    await SettingsService.instance.init();
    await FakeBackend.attachWithStaff();
  });

  tearDown(AppVersion.debugReset);

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  test('version.json から pubspec.yaml と同じ書き方の版を作る', () async {
    final asked = <Uri>[];
    AppVersion.debugClient = MockClient((req) async {
      asked.add(req.url);
      return http.Response(versionJsonFromPubspec(), 200);
    });
    expect(await AppVersion.load(), pubspecVersion());
    expect(asked.single.path, endsWith('/version.json'));
  });

  test('読めないときは null（画面では「（不明）」）', () async {
    AppVersion.debugClient = MockClient((_) async => http.Response('', 404));
    expect(await AppVersion.load(), isNull);
    expect(AppVersion.label('1.2.3', null), '1.2.3');
    expect(AppVersion.label(null, '6'), isNull);
  });

  testWidgets('設定画面のアプリ情報に pubspec.yaml の版が出る', (t) async {
    AppVersion.debugClient =
        MockClient((_) async => http.Response(versionJsonFromPubspec(), 200));
    await t.binding.setSurfaceSize(const Size(900, 4000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.runAsync(() async {
      await t.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await AppVersion.load();
    });
    await t.pump(const Duration(milliseconds: 500));
    final text = t.widget<Text>(find.byKey(const Key('appVersionText')));
    expect(text.data, pubspecVersion());
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('読めないときは「（不明）」', (t) async {
    AppVersion.debugClient = MockClient((_) async => http.Response('', 500));
    await t.binding.setSurfaceSize(const Size(900, 4000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.runAsync(() async {
      await t.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await AppVersion.load();
    });
    await t.pump(const Duration(milliseconds: 500));
    expect(
        t.widget<Text>(find.byKey(const Key('appVersionText'))).data, '（不明）');
    await t.pumpWidget(const SizedBox.shrink());
  });
}
