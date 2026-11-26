@Timeout(Duration(seconds: 150))
library;

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/day_ticker.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/next_day_booking_screen.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ4 段階2: 翌日予約選択の画面
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    DayTicker.instance.debugReset();
    WeeklyScheduleService.instance.debugCreateError = null;
    await FakeBackend.detach();
  });

  const stamp = AuditStamp(staffId: 's-a', staffName: '職員 冬子');
  // 今日は 2026-12-01（火）。明日 12-02（水）
  final today = DateTime(2026, 12, 1);
  final wed = DateTime(2026, 12, 2);

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return v;
      })) as T;

  Future<void> setUpData(WidgetTester t,
          {int count = 3, String? currentStaffId = 's-a', int capacity = 10}) =>
      io(t, () async {
        DayTicker.instance.now = () => today.add(const Duration(hours: 16));
        await FakeBackend.attach(
            staff: const [FakeBackend.staffA, FakeBackend.staffB],
            currentStaffId: currentStaffId);
        await CustomerService.instance.addCustomer(
            Customer(
                id: 'c1',
                name: '架空 一',
                nameKana: 'カクウ イチ',
                regularDays: [1, 3],
                transportLocations: ['架空の家']),
            stamp: stamp);
        for (var i = 2; i <= count; i++) {
          await CustomerService.instance.addCustomer(
              Customer(
                  id: 'c$i',
                  name: '架空 児童$i',
                  nameKana: 'カクウ ジドウ${i.toString().padLeft(2, '0')}',
                  regularDays: [3]),
              stamp: stamp);
        }
        await CustomerService.instance.addCustomer(
            Customer(
                id: 'x1',
                name: '架空 追加',
                nameKana: 'カクウ ツイカ',
                regularDays: [2],
                monthlyAvailableDays: 1),
            stamp: stamp);
        final s = SettingsService.instance.getSettings();
        SettingsService.instance.debugSetSettings(AppSettings(
            facilityName: s.facilityName, maxStudentsPerDay: capacity));
      });

  Future<void> open(WidgetTester t,
      {Size size = const Size(1280, 900), DateTime? date}) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: NextDayBookingScreen(initialDate: date)));
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

  Future<String?> storedStatus(WidgetTester t, String cid) => io(
      t,
      () async => (await FakeBackend.current.db
              .collection(FsPaths.facilities)
              .doc(FakeBackend.current.facilityId)
              .collection(FsPaths.scheduleEntries)
              .doc(WeeklyScheduleService.entryDocId(wed, cid))
              .get())
          .data()?['status'] as String?);

  testWidgets('開くと明日（週はまだ無ければ作る）。週間利用計画のとおりに並び、人数が出る', (t) async {
    await setUpData(t);
    await open(t);
    expect(text(t, 'nextDayDate'), '2026年12月2日（水）');
    expect(find.byKey(const Key('nextDayCard_c1')), findsOneWidget);
    expect(find.byKey(const Key('nextDayCard_c2')), findsOneWidget);
    expect(find.byKey(const Key('nextDayCard_x1')), findsNothing); // 火曜の児童
    expect(text(t, 'nextDayUsing'), '3人');
    expect(text(t, 'nextDayAbsent'), '0人');
    expect(text(t, 'nextDayFree'), '7人');
    expect(text(t, 'nextDayTimeText_c1'), '時間未定　通常');
    expect(text(t, 'nextDayTransport_c1'), '送迎：架空の家');
    expect(text(t, 'nextDayTransport_c2'), '送迎なし');
  });

  testWidgets('いつもどおりの日は何も押さずに済む（開いただけでは何も書かない）', (t) async {
    await setUpData(t);
    await open(t);
    final docs = await io(
        t,
        () async => (await FakeBackend.current.db
                .collection(FsPaths.facilities)
                .doc(FakeBackend.current.facilityId)
                .collection(FsPaths.scheduleEntries)
                .get())
            .docs);
    // 週の自動作成（「自動」の記録）だけ
    expect(docs.every((d) => d.data()['updatedByStaffName'] == '自動'), isTrue);
  });

  testWidgets('お休み → 週間利用計画でキャンセル・人数が変わる。利用するで元に戻る', (t) async {
    await setUpData(t);
    await open(t);
    await tap(t, find.byKey(const Key('nextDayAbsent_c1')));
    expect(await storedStatus(t, 'c1'), 'cancelled');
    expect(text(t, 'nextDayUsing'), '2人');
    expect(text(t, 'nextDayAbsent'), '1人');
    expect(text(t, 'nextDayTimeText_c1'), contains('お休み'));
    await tap(t, find.byKey(const Key('nextDayUse_c1')));
    expect(await storedStatus(t, 'c1'), 'planned');
    expect(text(t, 'nextDayUsing'), '3人');
  });

  testWidgets('続けて「お休み」を押しても並びは動かず、押した児童だけが変わる。開き直すと整う', (t) async {
    await setUpData(t, count: 6);
    await open(t);
    final ids = ['c1', 'c2', 'c3', 'c4', 'c5', 'c6'];
    Map<String, Offset> pos() => {
          for (final id in ids)
            id: t.getTopLeft(find.byKey(Key('nextDayCard_$id')))
        };
    final before = pos();
    // 同じ場所（先頭の児童の「お休み」）を続けて押す → 先頭の児童のまま
    final firstAbsent = t.getCenter(find.byKey(const Key('nextDayAbsent_c1')));
    await t.tapAt(firstAbsent);
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(pos(), before, reason: '押した直後に並びが動いた');
    await t.tapAt(firstAbsent); // もう一度押しても同じ児童（お休みのまま）
    await io(t, () async {});
    await t.pumpAndSettle();
    for (final id in ['c3', 'c5']) {
      await tap(t, find.byKey(Key('nextDayAbsent_$id')));
      expect(pos(), before, reason: '$id を押した後に並びが動いた');
    }
    expect(await storedStatus(t, 'c1'), 'cancelled');
    expect(await storedStatus(t, 'c3'), 'cancelled');
    expect(await storedStatus(t, 'c5'), 'cancelled');
    for (final id in ['c2', 'c4', 'c6']) {
      expect(await storedStatus(t, id), 'planned', reason: id);
    }
    // 他の端末からの変更でも並びは動かない
    await io(
        t,
        () => FakeBackend.current.db
            .collection(FsPaths.facilities)
            .doc(FakeBackend.current.facilityId)
            .collection(FsPaths.scheduleEntries)
            .doc(WeeklyScheduleService.entryDocId(wed, 'c2'))
            .update({'status': 'cancelled'}));
    await t.pumpAndSettle();
    expect(pos(), before);
    expect(text(t, 'nextDayAbsent'), '4人');
    // 開き直すと、利用する人が先に整う
    await t.pumpWidget(const SizedBox.shrink());
    await open(t);
    final y = pos();
    for (final using in ['c4', 'c6']) {
      for (final absent in ['c1', 'c2', 'c3', 'c5']) {
        final a = y[using]!, b = y[absent]!;
        expect(a.dy < b.dy || (a.dy == b.dy && a.dx < b.dx), isTrue,
            reason: '$using が $absent より前に来ていない');
      }
    }
  });

  testWidgets('担当者が未選択なら直せず、選ぶと記録に担当者が残る', (t) async {
    await setUpData(t, currentStaffId: null);
    var choose = false;
    StaffSession.instance.prompter =
        () async => choose ? FakeBackend.staffB : null;
    await open(t);
    await tap(t, find.byKey(const Key('nextDayAbsent_c2')));
    expect(find.text('担当者を選ぶと保存できます'), findsOneWidget);
    expect(await storedStatus(t, 'c2'), 'planned');
    choose = true;
    await t.pumpAndSettle(const Duration(seconds: 5));
    await tap(t, find.byKey(const Key('nextDayAbsent_c2')));
    expect(await storedStatus(t, 'c2'), 'cancelled');
    final by = await io(
        t,
        () async => (await FakeBackend.current.db
                .collection(FsPaths.facilities)
                .doc(FakeBackend.current.facilityId)
                .collection(FsPaths.scheduleEntries)
                .doc(WeeklyScheduleService.entryDocId(wed, 'c2'))
                .get())
            .data()!['updatedByStaffName']);
    expect(by, FakeBackend.staffB.name);
  });

  testWidgets('時間の変更: その日の予定の時間だけを直す', (t) async {
    await setUpData(t);
    await open(t);
    // 時間の変更は、枠と時計の印のボタン（縦横 48 以上）
    final btn = find.byKey(const Key('nextDayTimeBtn_c2'));
    expect(t.getSize(btn).height, greaterThanOrEqualTo(48));
    expect(t.getSize(btn).width, greaterThanOrEqualTo(48));
    expect(find.descendant(of: btn, matching: find.byIcon(Icons.schedule)),
        findsOneWidget);
    // カードの他の場所を押しても開かない（押せる所をはっきりさせる）
    await tap(t, find.byKey(const Key('nextDayTimeText_c2')));
    expect(find.byKey(const Key('nextDayTimeSave')), findsNothing);
    await tap(t, btn);
    await tap(t, find.byKey(const Key('nextDayTime_start')));
    await tap(t, find.text('決定'));
    await tap(t, find.byKey(const Key('nextDayTime_end')));
    await tap(t, find.text('決定'));
    await tap(t, find.byKey(const Key('nextDayTimeSave')));
    expect(text(t, 'nextDayTimeText_c2'), '14:00〜17:00　通常');
  });

  testWidgets('時間のボタン: お休みの児童・今日は押せない（押せない見た目）', (t) async {
    await setUpData(t);
    await open(t);
    OutlinedButton b(String id) =>
        t.widget<OutlinedButton>(find.byKey(Key('nextDayTimeBtn_$id')));
    expect(b('c1').onPressed, isNotNull);
    await tap(t, find.byKey(const Key('nextDayAbsent_c1')));
    expect(b('c1').onPressed, isNull);
    expect(b('c2').onPressed, isNotNull);
    await tap(t, find.byKey(const Key('nextDayUse_c1')));
    expect(b('c1').onPressed, isNotNull);
    await tap(t, find.byKey(const Key('nextDayPrev'))); // 今日
    expect(b('x1').onPressed, isNull);
  });

  testWidgets('児童を追加: 利用可能日数を超える見込みなら知らせ、追加すると「追加」で並ぶ', (t) async {
    await setUpData(t);
    await open(t);
    await tap(t, find.byKey(const Key('nextDayAdd')));
    expect(find.byKey(const Key('nextDayAddPick_c1')),
        findsNothing); // 予定がある児童は出ない
    // ダイアログのボタン・選ぶ行も高さ 48 以上
    expect(t.getSize(find.widgetWithText(TextButton, 'やめる')).height,
        greaterThanOrEqualTo(48));
    expect(t.getSize(find.byKey(const Key('nextDayAddPick_x1'))).height,
        greaterThanOrEqualTo(48));
    await tap(t, find.byKey(const Key('nextDayAddPick_x1')));
    expect(find.text('今月の支給日数を超過する見込みです'), findsOneWidget);
    await tap(t, find.byKey(const Key('nextDayAddOverOk')));
    expect(find.byKey(const Key('nextDayCard_x1')), findsOneWidget);
    expect(text(t, 'nextDayTimeText_x1'), contains('追加'));
    expect(text(t, 'nextDayUsing'), '4人');
    expect(await storedStatus(t, 'x1'), 'additional');
  });

  testWidgets('定員を超えたら超えている人数を強い色で出す（操作は止めない）', (t) async {
    await setUpData(t, count: 4, capacity: 3);
    await open(t);
    expect(text(t, 'nextDayOver'), '1人超えています');
    expect(t.widget<Text>(find.byKey(const Key('nextDayOver'))).style!.color,
        AppColors.error);
    await tap(t, find.byKey(const Key('nextDayAbsent_c4')));
    expect(find.byKey(const Key('nextDayOver')), findsNothing);
    expect(text(t, 'nextDayFree'), '0人');
  });

  testWidgets('今日は表示だけで出席管理への案内、過去の日も表示だけ', (t) async {
    await setUpData(t);
    await open(t);
    await tap(t, find.byKey(const Key('nextDayPrev')));
    expect(text(t, 'nextDayDate'), '2026年12月1日（火）');
    expect(find.text('今日の分は出席管理で扱います（この画面では直せません）'), findsOneWidget);
    expect(find.byKey(const Key('nextDayOpenAttendance')), findsOneWidget);
    expect(find.byKey(const Key('nextDayAdd')), findsNothing);
    expect(
        t
            .widget<OutlinedButton>(find.byKey(const Key('nextDayAbsent_x1')))
            .onPressed,
        isNull);
    await tap(t, find.byKey(const Key('nextDayPrev')));
    expect(find.text('過ぎた日は表示だけです'), findsOneWidget);
  });

  testWidgets('他の端末（週間利用計画の画面を含む）で直した内容が開き直さずに届く', (t) async {
    await setUpData(t);
    await open(t);
    await io(t, () async {
      await FakeBackend.current.db
          .collection(FsPaths.facilities)
          .doc(FakeBackend.current.facilityId)
          .collection(FsPaths.scheduleEntries)
          .doc(WeeklyScheduleService.entryDocId(wed, 'c2'))
          .update({'status': 'cancelled', 'plannedStartTime': '15:00'});
    });
    await t.pumpAndSettle();
    expect(text(t, 'nextDayAbsent'), '1人');
    expect(text(t, 'nextDayTimeText_c2'), contains('15:00'));
  });

  testWidgets('週を作れない（通信できない）ときは、週間利用計画と同じ案内と再試行', (t) async {
    await setUpData(t);
    WeeklyScheduleService.instance.debugCreateError = Exception('offline');
    await open(t, date: wed);
    expect(find.textContaining('この週の計画を作成でき'), findsOneWidget);
    WeeklyScheduleService.instance.debugCreateError = null;
    await tap(t, find.byKey(const Key('nextDayRetry')));
    expect(find.byKey(const Key('nextDayCard_c1')), findsOneWidget);
  });

  for (final size in const [Size(1280, 900), Size(820, 1180), Size(530, 900)]) {
    testWidgets('幅 ${size.width.toInt()} で崩れない。ボタンは高さ 48 以上', (t) async {
      await setUpData(t, count: 16);
      await open(t, size: size);
      expect(t.takeException(), isNull);
      for (final k in [
        'nextDayUse_c1',
        'nextDayAbsent_c1',
        'nextDayPrev',
        'nextDayAdd'
      ]) {
        expect(t.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48),
            reason: k);
      }
      if (size.width == 820) {
        // タブレット幅で 1 画面に 10 人以上
        final visible =
            List.generate(16, (i) => 'nextDayCard_c${i + 1}').where((k) {
          final f = find.byKey(Key(k));
          if (f.evaluate().isEmpty) return false;
          return t.getRect(f).bottom <= size.height;
        }).length;
        expect(visible, greaterThanOrEqualTo(10));
      }
    });
  }
}
