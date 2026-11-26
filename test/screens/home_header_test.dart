import 'dart:io';

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/screens/home_screen.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ホームの上のバーの事業所名（設定の事業所名から出す）
Future<void> _ms(WidgetTester t, int ms) async {
  var left = ms;
  while (left > 0) {
    final step = left > 16 ? 16 : left;
    await t.pump(Duration(milliseconds: step));
    left -= step;
  }
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_home_header_');
    Hive.init(tmp.path);
    await FakeBackend.attachWithStaff();
    await SettingsService.instance.init();
    SlotService.instance.remoteEnabled = false;
    AppMotion.debugDisableLooping = true;
  });

  tearDownAll(() async {
    AppMotion.debugDisableLooping = false;
    await Future.any<Object?>([
      Hive.close(),
      Future<Object?>.delayed(const Duration(seconds: 3)),
    ]);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> setName(WidgetTester t, String name) => t.runAsync(() async {
        final b = FakeBackend.current;
        await b.db
            .collection(FsPaths.facilities)
            .doc(b.facilityId)
            .collection(FsPaths.settings)
            .doc(FsPaths.settingsDocId)
            .set({'facilityName': name}, SetOptions(merge: true));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

  test('事業所名が空（空白だけを含む）なら「事業所名 未設定」', () {
    expect(HomeScreen.facilityLabel(AppSettings(facilityName: '')), '事業所名 未設定');
    expect(
        HomeScreen.facilityLabel(AppSettings(facilityName: '　 ')), '事業所名 未設定');
    expect(HomeScreen.facilityLabel(AppSettings(facilityName: ' 架空の事業所 ')),
        '架空の事業所');
  });

  testWidgets('上のバーに設定の事業所名が出て、他の端末で変わると開き直さずに変わる', (t) async {
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await setName(t, '架空の事業所');
    await t.pumpWidget(
        MaterialApp(theme: AppTheme.lightTheme, home: const HomeScreen()));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await _ms(t, 1500);
    Text label() => t.widget<Text>(find.byKey(const Key('homeFacilityName')));
    expect(label().data, '架空の事業所');
    expect(find.text('サンプル施設'), findsNothing);

    await setName(t, '');
    await _ms(t, 100);
    expect(label().data, '事業所名 未設定');

    await setName(t, '別の架空の事業所');
    await _ms(t, 100);
    expect(label().data, '別の架空の事業所');
    await t.pumpWidget(const SizedBox.shrink());
    await _ms(t, 3000);
  });
}
