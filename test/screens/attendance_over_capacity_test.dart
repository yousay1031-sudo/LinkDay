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

  /// 数字の色と、そのすぐ後ろの丸の色
  (Color?, Color?) digitAndPill(WidgetTester t, Finder chip, String n) {
    final digit = find.descendant(of: chip, matching: find.text(n));
    final text = t.widget<Text>(digit);
    final style = DefaultTextStyle.of(t.element(digit)).style.merge(text.style);
    final pill = t
        .widgetList<Container>(
            find.ancestor(of: digit, matching: find.byType(Container)))
        .firstWhere((c) => c.decoration is BoxDecoration);
    return (style.color, (pill.decoration! as BoxDecoration).color);
  }

  testWidgets('予定 3 人・定員 1 人: 「定員超過 2」を出し、「空き枠」は出さない', (t) async {
    await seed(t, capacity: 1);
    await open(t);
    final over = find.byKey(const Key('attendanceOverCapacity'));
    expect(over, findsOneWidget);
    expect(
        find.descendant(of: over, matching: find.text('定員超過')), findsOneWidget);
    expect(find.descendant(of: over, matching: find.text('2')), findsOneWidget);
    // 人数の数字が、後ろの丸と違う色で出ている（白に白で読めない不具合）
    final (digit, pill) = digitAndPill(t, over, '2');
    expect(digit, isNot(pill));
    expect(digit, AppColors.error);
    expect(pill, Colors.white);
    expect(find.byKey(const Key('attendanceFreeSlots')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    await _ms(t, 3000);
  });

  // 人数の帯: 横に流さず、狭い幅では折り返して「定員超過」「空き枠」まで見える
  for (final (w, capacity, key) in const [
    (1280.0, 1, 'attendanceOverCapacity'),
    (530.0, 1, 'attendanceOverCapacity'),
    (390.0, 1, 'attendanceOverCapacity'),
    (390.0, 10, 'attendanceFreeSlots'),
  ]) {
    testWidgets('幅 ${w.toInt()}・定員 $capacity: 人数の帯が画面の中に全部見える',
        (t) async {
      await seed(t, capacity: capacity);
      await t.binding.setSurfaceSize(Size(w, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme
              .copyWith(visualDensity: VisualDensity.compact),
          home: const AttendanceScreen()));
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await _ms(t, 1500);
      expect(t.takeException(), isNull);
      final bar = find.byKey(const Key('attendanceSummaryBar'));
      expect(
          find.ancestor(of: bar, matching: find.byType(SingleChildScrollView)),
          findsNothing,
          reason: '横に流す作りではない');
      final chips = [
        for (final l in const ['予定', '在室中', '退室済', '欠席'])
          find.ancestor(
              of: find.descendant(of: bar, matching: find.text(l)),
              matching: find.byType(Container)).first,
        find.byKey(Key(key)),
      ];
      final rects = [for (final c in chips) t.getRect(c)];
      for (final r in rects) {
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(w), reason: '画面の右端で切れない');
      }
      // 段の数（同じ段の中では中心の高さがほぼ揃う）
      final centers = rects.map((r) => r.center.dy).toList()..sort();
      final rows = <double>[];
      for (final c in centers) {
        if (rows.isEmpty || c - rows.last > 10) rows.add(c);
      }
      if (w >= 1000) {
        expect(rows.length, 1, reason: '広い幅では 1 段');
      } else {
        expect(rows.length, lessThanOrEqualTo(2), reason: '狭い幅では 2 段まで');
      }
      // 段どうしが重ならない
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].intersect(rects[j]).isEmpty ||
              rects[i].intersect(rects[j]).width <= 0 ||
              rects[i].intersect(rects[j]).height <= 0, isTrue);
        }
      }
      await t.pumpWidget(const SizedBox.shrink());
      await _ms(t, 3000);
    });
  }

  testWidgets('定員内なら従来どおり「空き枠」', (t) async {
    await seed(t, capacity: 10);
    await open(t);
    final free = find.byKey(const Key('attendanceFreeSlots'));
    expect(free, findsOneWidget);
    expect(find.descendant(of: free, matching: find.text('7')), findsOneWidget);
    // 空き枠の見た目は変えない（主色の丸に白い数字）
    final (digit, pill) = digitAndPill(t, free, '7');
    expect(digit, Colors.white);
    expect(pill, AppColors.primary);
    expect(find.byKey(const Key('attendanceOverCapacity')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    await _ms(t, 3000);
  });
}
