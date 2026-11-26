@Timeout(Duration(seconds: 150))
library;

import 'dart:io';

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/day_ticker.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/home_screen.dart';
import 'package:linkday_app/screens/next_day_booking_screen.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/day_confirmation_service.dart';
import 'package:linkday_app/services/next_day_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ4 段階3: 確認の記録・「確認後に変更あり」・ホームの「未確認」の印
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
  // 今日は 2026-12-01（火）。明日 12-02（水）
  final today = DateTime(2026, 12, 1);
  final wed = DateTime(2026, 12, 2);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_next_day_');
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
  tearDown(() async {
    DayTicker.instance.debugReset();
    await FakeBackend.detach();
  });

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return v;
      })) as T;

  Future<void> setUpData(WidgetTester t, {bool withEntries = true}) =>
      io(t, () async {
        DayTicker.instance.now = () => today.add(const Duration(hours: 16));
        await FakeBackend.attachWithStaff();
        await SettingsService.instance.init();
        for (var i = 1; i <= 3; i++) {
          await CustomerService.instance.addCustomer(
              Customer(
                  id: 'c$i',
                  name: '架空 児童$i',
                  nameKana: 'カクウ ジドウ$i',
                  regularDays: withEntries ? [3] : []),
              stamp: stamp);
        }
      });

  CollectionReference<Map<String, dynamic>> confCol() => FakeBackend.current.db
      .collection(FsPaths.facilities)
      .doc(FakeBackend.current.facilityId)
      .collection(FsPaths.dayConfirmations);

  Future<void> openScreen(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme, home: const NextDayBookingScreen()));
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  String text(WidgetTester t, String key) =>
      t.widget<Text>(find.byKey(Key(key))).data ?? '';

  testWidgets('「この内容で確認した」で、確認した人・時刻・人数が記録される', (t) async {
    await setUpData(t);
    await openScreen(t);
    expect(text(t, 'nextDayConfirmStatus'), 'まだ確認していません');
    await tap(t, find.byKey(const Key('nextDayConfirm')));
    final d = (await io(t, () => confCol().doc('2026-12-02').get())).data()!;
    expect(d['date'], '2026-12-02');
    expect(d['confirmedByStaffName'], '職員 冬子');
    expect(d['confirmedByStaffId'], 's-a');
    expect(d['usingCount'], 3);
    expect(d['absentCount'], 0);
    expect(d['updatedByStaffName'], '職員 冬子');
    expect(d.containsKey('confirmedAt'), isTrue);
    expect(text(t, 'nextDayConfirmStatus'), startsWith('確認済み：職員 冬子'));
    expect(find.byKey(const Key('nextDayChangedAfter')), findsNothing);
    expect(find.text('もう一度確認する'), findsOneWidget);
  });

  testWidgets('確認の後に直すと「確認後に変更あり」。もう一度確認すると消える。予定は固定しない', (t) async {
    await setUpData(t);
    await openScreen(t);
    await tap(t, find.byKey(const Key('nextDayConfirm')));
    await io(t, () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tap(t, find.byKey(const Key('nextDayAbsent_c1')));
    expect(find.byKey(const Key('nextDayChangedAfter')), findsOneWidget);
    expect(find.text('この内容で確認した'), findsOneWidget);
    await tap(t, find.byKey(const Key('nextDayConfirm')));
    expect(find.byKey(const Key('nextDayChangedAfter')), findsNothing);
    final d = (await io(t, () => confCol().doc('2026-12-02').get())).data()!;
    expect([d['usingCount'], d['absentCount']], [2, 1]);
  });

  test('確認後の変更: 他の端末で予定が更新された（更新時刻）・人数が違う（予定を消した）', () async {
    await FakeBackend.attachWithStaff();
    final conf = DayConfirmation(
      dateKey: '2026-12-02',
      confirmedAt: DateTime(2026, 12, 1, 17, 0),
      confirmedByStaffId: 's-a',
      confirmedByStaffName: '職員 冬子',
      usingCount: 3,
      absentCount: 0,
    );
    // 予定の更新時刻が無い（読み込んでいない）・人数が同じ → 変更なし
    expect(DayConfirmationService.changedAfter(conf, wed, 3), isFalse);
    // 人数が違う（週間利用計画の画面で予定を消したなど）
    expect(DayConfirmationService.changedAfter(conf, wed, 2), isTrue);
  });

  group('ホームの「未確認」の印', () {
    Future<void> openHome(WidgetTester t) async {
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
          MaterialApp(theme: AppTheme.lightTheme, home: const HomeScreen()));
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 600)));
      await _ms(t, 1500);
    }

    Future<void> closeHome(WidgetTester t) async {
      await t.pumpWidget(const SizedBox.shrink());
      await _ms(t, 3000);
    }

    testWidgets('明日に予定があり確認していなければ印。他の端末で確認すると消える（ホームは週を作らない）', (t) async {
      await setUpData(t);
      await openHome(t);
      expect(find.byKey(const Key('homeNextDayBadge')), findsOneWidget);
      expect(WeeklyScheduleService.instance.hasWeekFor(wed), isFalse);
      // 他の端末が確認した
      await io(t, () async {
        await confCol().doc('2026-12-02').set({
          'date': '2026-12-02',
          'confirmedByStaffName': '職員 夏男',
          'usingCount': 3,
          'absentCount': 0,
        });
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await _ms(t, 600);
      expect(find.byKey(const Key('homeNextDayBadge')), findsNothing);
      await closeHome(t);
    });

    testWidgets('予定が 1 件も無ければ印を出さない', (t) async {
      await setUpData(t, withEntries: false);
      await openHome(t);
      expect(
          await io(t,
              () => NextDayService.findTargetDate(today, createWeeks: false)),
          wed);
      expect(find.byKey(const Key('homeNextDayBadge')), findsNothing);
      await closeHome(t);
    });

    testWidgets('「翌日予約選択」を押すと画面が開き、「準備中です」は出ない', (t) async {
      await setUpData(t);
      await openHome(t);
      await t.tap(find.byKey(const ValueKey('homeMenu_/next-day-booking')));
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await _ms(t, 1500);
      expect(find.byType(NextDayBookingScreen), findsOneWidget);
      expect(find.textContaining('準備中です'), findsNothing);
      await closeHome(t);
    });
  });
}
