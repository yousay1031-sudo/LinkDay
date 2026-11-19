import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/screens/attendance_screen.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/theme/app_motion.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 段階5: 通信できないときは入室を記録せず、理由と「再試行」を出す
Future<void> _ms(WidgetTester t, int ms) async {
  var left = ms;
  while (left > 0) {
    final step = left > 16 ? 16 : left;
    await t.pump(Duration(milliseconds: step));
    left -= step;
  }
}

Future<void> _real(WidgetTester t, [int ms = 300]) async {
  for (var i = 0; i < 3; i++) {
    await t
        .runAsync(() => Future<void>.delayed(Duration(milliseconds: ms ~/ 3)));
    await t.pump();
  }
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_att_offline_');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(7)) Hive.registerAdapter(AppSettingsAdapter());
    await FakeBackend.attachWithStaff();
    await SettingsService.instance.init();
    SlotService.instance.remoteEnabled = false;
    AppMotion.debugDisableLooping = true;
  });

  tearDownAll(() async {
    AttendanceService.instance.debugTransactionError = null;
    AppMotion.debugDisableLooping = false;
    await Future.any<Object?>([
      Hive.close(),
      Future<Object?>.delayed(const Duration(seconds: 3)),
    ]);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('通信できないと入室を記録せず「再試行」を出す。通信が戻れば再試行で記録できる',
      (t) async {
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final key = AttendanceRecord.makeDateKey(DateTime.now());
    await t.runAsync(() async {
      await FakeBackend.resetAttendance();
      await FakeBackend.resetCustomers();
      await AttendanceService.instance.upsertRecord(AttendanceRecord(
          customerId: 'c-wait', customerName: '予定 二郎', dateKey: key));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await t.pumpWidget(const MaterialApp(home: AttendanceScreen()));
    await _ms(t, 1500);
    expect(find.text('予定 二郎'), findsOneWidget);

    AttendanceService.instance.debugTransactionError =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    final presentButton = find.ancestor(
      of: find.text('入室'),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    );
    expect(presentButton, findsOneWidget);
    await t.tap(presentButton);
    await _real(t);
    await _ms(t, 500);
    expect(find.byKey(const Key('attendanceOfflineSnack')), findsOneWidget);
    expect(find.textContaining('通信できないため記録できませんでした'), findsOneWidget);
    expect(find.text('再試行'), findsOneWidget);
    expect(
        AttendanceService.instance
            .getRecord('c-wait', DateTime.now())!
            .status,
        AttendanceStatus.scheduled,
        reason: 'オフラインでは記録しない');

    // 通信が戻った → 再試行で記録できる
    AttendanceService.instance.debugTransactionError = null;
    await t.tap(find.text('再試行'));
    await _real(t);
    await _ms(t, 500);
    expect(
        AttendanceService.instance
            .getRecord('c-wait', DateTime.now())!
            .status,
        AttendanceStatus.present);
    await t.pumpWidget(const SizedBox.shrink());
    await _ms(t, 3000);
  });
}
