import 'dart:io';

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/screens/attendance_screen.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ4 仕上げ: 出席管理の空き枠は、定員を超えているとき「空き枠 0」ではなく
/// 超えている人数を「定員超過」として出す
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
  const stamp = AuditStamp(staffId: 's-a', staffName: '職員 冬子');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_over_cap_');
    Hive.init(tmp.path);
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
  tearDown(FakeBackend.detach);

  Future<void> seed(WidgetTester t, {required int capacity}) =>
      t.runAsync(() async {
        await FakeBackend.attachWithStaff();
        await SettingsService.instance
            .updateOperatingHours('08:00', '17:00', capacity);
        final key = AttendanceRecord.makeDateKey(DateTime.now());
        for (var i = 0; i < 3; i++) {
          await AttendanceService.instance.upsertRecord(
              AttendanceRecord(
                  customerId: 'a$i', customerName: '架空 予定$i', dateKey: key),
              stamp: stamp);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

  Future<void> open(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme, home: const AttendanceScreen()));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await _ms(t, 1500);
  }

  testWidgets('予定 3 人・定員 1 人: 「定員超過 2」を出し、「空き枠」は出さない', (t) async {
    await seed(t, capacity: 1);
    await open(t);
    final over = find.byKey(const Key('attendanceOverCapacity'));
    expect(over, findsOneWidget);
    expect(
        find.descendant(of: over, matching: find.text('定員超過')), findsOneWidget);
    expect(find.descendant(of: over, matching: find.text('2')), findsOneWidget);
    expect(find.byKey(const Key('attendanceFreeSlots')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    await _ms(t, 3000);
  });

  testWidgets('定員内なら従来どおり「空き枠」', (t) async {
    await seed(t, capacity: 10);
    await open(t);
    final free = find.byKey(const Key('attendanceFreeSlots'));
    expect(free, findsOneWidget);
    expect(find.descendant(of: free, matching: find.text('7')), findsOneWidget);
    expect(find.byKey(const Key('attendanceOverCapacity')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    await _ms(t, 3000);
  });
}
