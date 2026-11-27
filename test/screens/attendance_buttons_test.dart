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
import 'package:linkday_app/widgets/attendance_time_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 出席管理: 「入室」「退室」「欠席」「欠席を取り消す」と入室・退室の時刻は、詰めた表示（PC のブラウザ）
/// でも、どの状態のカードでも高さ 48 以上で、カードの中に収まる
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
    tmp = await Directory.systemTemp.createTemp('linkday_att_btn_');
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

  Future<void> seed(WidgetTester t) => t.runAsync(() async {
        await FakeBackend.attachWithStaff();
        await SettingsService.instance
            .updateOperatingHours('08:00', '17:00', 10);
        final now = DateTime.now();
        final key = AttendanceRecord.makeDateKey(now);
        final at = DateTime(now.year, now.month, now.day, 9, 30);
        final rs = [
          AttendanceRecord(
              customerId: 'a0', customerName: '架空 予定', dateKey: key),
          AttendanceRecord(
              customerId: 'a1',
              customerName: '架空 在室',
              dateKey: key,
              status: AttendanceStatus.present,
              checkInTime: at),
          AttendanceRecord(
              customerId: 'a2',
              customerName: '架空 退室',
              dateKey: key,
              status: AttendanceStatus.departed,
              checkInTime: at,
              checkOutTime: at.add(const Duration(hours: 5))),
          AttendanceRecord(
              customerId: 'a3',
              customerName: '架空 欠席',
              dateKey: key,
              status: AttendanceStatus.absent,
              absenceReason: '体調不良のため本日はお休みします。保護者より連絡あり'),
        ];
        for (final r in rs) {
          await AttendanceService.instance.upsertRecord(r, stamp: stamp);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

  Future<void> open(WidgetTester t, Size size) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme
            .copyWith(visualDensity: VisualDensity.compact),
        home: const AttendanceScreen()));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await _ms(t, 1500);
  }

  final card = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_AttendanceCard');

  for (final size in const [Size(1280, 900), Size(820, 1180), Size(530, 900)]) {
    testWidgets('幅 ${size.width.toInt()}: 4 つのボタンが高さ 48 以上でカードに収まる',
        (t) async {
      await seed(t);
      await open(t, size);
      expect(t.takeException(), isNull, reason: 'はみ出しの警告が出ていない');
      for (final label in const ['入室', '欠席', '退室', '欠席を取り消す']) {
        final b = find.ancestor(
            of: find.descendant(of: card, matching: find.text(label)),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
        expect(b, findsOneWidget, reason: label);
        final r = t.getRect(b);
        expect(r.height, greaterThanOrEqualTo(47.9), reason: label);
        final c = t.getRect(find.ancestor(of: b, matching: card));
        expect(r.bottom, lessThanOrEqualTo(c.bottom + 0.1), reason: '$label がカードに収まる');
        expect(r.top, greaterThanOrEqualTo(c.top - 0.1), reason: label);
      }
      // 入室・退室の時刻（押すと時刻を直せる）も高さ 48 以上
      final chips = find.byType(AttendanceTimeChip);
      expect(chips, findsNWidgets(6), reason: '欠席以外の 3 枚 × 入室・退室');
      for (final e in chips.evaluate()) {
        final r = t.getRect(find.byWidget(e.widget));
        expect(r.height, greaterThanOrEqualTo(47.9),
            reason: '${(e.widget as AttendanceTimeChip).label} の時刻');
      }
      await t.pumpWidget(const SizedBox.shrink());
      await _ms(t, 3000);
    });
  }
}
