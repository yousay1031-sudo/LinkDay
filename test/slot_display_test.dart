import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/notification_log.dart';
import 'package:linkday_app/models/slot_info.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/screens/attendance_screen.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/services/vacancy_notification_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/widgets/slot_status_panel.dart';

/// Day 14: 出席画面の「LINE応募」表示と、応募受付時間の設定
///
/// 検証の柱:
///  1. status=filled のとき応募者名＋応募時刻が出る
///  2. 選択中の日付の slots だけを購読し、日付変更で購読を張り直す
///  3. 取得エラーを「応募なし」と誤認させない
///  4. 受付時間(slotTtlHours)が AppSettings で変更でき、他の設定を壊さない
void main() {
  late Directory tmp;
  final now = DateTime(2026, 10, 5, 12, 0);

  String? names(String id) => const {
        'absent1': '山田 太郎',
        'taker1': '佐藤 花子',
      }[id];

  SlotInfo slot({
    String id = '2026-10-05_absent1',
    String dateKey = '2026-10-05',
    String status = 'open',
    DateTime? expiresAt,
    Map<String, dynamic>? claimedBy,
    List<dynamic>? notified,
  }) =>
      SlotInfo.fromMap(id, {
        'dateKey': dateKey,
        'sourceAbsent': 'absent1',
        'status': status,
        'expiresAt': expiresAt ?? now.add(const Duration(hours: 3)),
        'claimedBy': claimedBy,
        'notifiedList': notified ?? [1, 2, 3],
      });

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_day14_');
    Hive.init(tmp.path);
    void reg<T>(int id, TypeAdapter<T> a) {
      if (!Hive.isAdapterRegistered(id)) Hive.registerAdapter(a);
    }

    reg(0, CustomerAdapter());
    reg(1, AttendanceRecordAdapter());
    reg(2, AttendanceStatusAdapter());
    reg(3, WeeklyScheduleAdapter());
    reg(4, DailySlotAdapter());
    reg(5, ScheduleStatusAdapter());
    reg(6, ScheduleEntryAdapter());
    reg(7, AppSettingsAdapter());
    reg(11, NotificationLogAdapter());
    reg(12, NotificationStatusAdapter());
    await CustomerService.instance.init();
    await AttendanceService.instance.init();
    await WeeklyScheduleService.instance.init();
    await SettingsService.instance.init();
    await VacancyNotificationService.instance.init(remoteEnabled: false);
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });


  // ══════════════════════════════════════════════════════════════
  group('SlotInfo.stateAt: 状態判定', () {
    test('open で期限内 → open', () {
      expect(slot().stateAt(now), SlotState.open);
    });

    test('open でも期限を過ぎていれば expired（読み出し時判定）', () {
      final s = slot(expiresAt: now.subtract(const Duration(minutes: 1)));
      expect(s.stateAt(now), SlotState.expired);
    });

    test('期限ちょうど(同時刻)も expired（サーバーの <= 判定と一致）', () {
      expect(slot(expiresAt: now).stateAt(now), SlotState.expired);
    });

    test('filled は期限を過ぎても filled のまま', () {
      final s = slot(
        status: 'filled',
        expiresAt: now.subtract(const Duration(hours: 5)),
        claimedBy: {
          'customerId': 'taker1',
          'claimedAt': now.subtract(const Duration(hours: 4)),
        },
      );
      expect(s.stateAt(now), SlotState.filled);
    });

    test('filled なのに確定者が欠けていれば確定と断定せず unknown', () {
      expect(slot(status: 'filled').stateAt(now), SlotState.unknown);
    });

    test('released は期限内なら released・期限後は expired', () {
      expect(slot(status: 'released').stateAt(now), SlotState.released);
      expect(
        slot(
                status: 'released',
                expiresAt: now.subtract(const Duration(minutes: 1)))
            .stateAt(now),
        SlotState.expired,
      );
    });

    test('未知の status は unknown（確定扱いにしない）', () {
      expect(slot(status: 'weird').stateAt(now), SlotState.unknown);
      expect(slot(status: '').stateAt(now), SlotState.unknown);
    });

    test('型が崩れたデータでも例外を投げない', () {
      final s = SlotInfo.fromMap('x', const <String, dynamic>{
        'dateKey': 123,
        'status': null,
        'claimedBy': 'oops',
        'notifiedList': 'bad',
        'expiresAt': 42,
      });
      expect(s.stateAt(now), SlotState.unknown);
      expect(s.notifiedCount, 0);
      expect(s.claimedBy, isNull);
    });
  });

  // ══════════════════════════════════════════════════════════════
  group('SlotRowView: 表示内容', () {
    test('filled は 応募者名 と 応募時刻(HH:mm) を出す', () {
      final s = slot(
        status: 'filled',
        claimedBy: {
          'customerId': 'taker1',
          'claimedAt': DateTime(2026, 10, 5, 9, 7),
        },
      );
      final v = SlotRowView.from(s, now: now, nameOf: names);
      expect(v.label, '確定');
      expect(v.detail, contains('佐藤 花子'));
      expect(v.detail, contains('09:07'));
      expect(v.absentName, '山田 太郎');
    });

    test('応募者が顧客マスタに無くても ID を画面に出さない', () {
      final s = slot(
        status: 'filled',
        claimedBy: {'customerId': 'secret_internal_id_999', 'claimedAt': now},
      );
      final v = SlotRowView.from(s, now: now, nameOf: names);
      expect(v.detail, contains('利用者情報なし'));
      expect(v.detail, isNot(contains('secret_internal_id_999')));
    });

    test('open は「募集中」で通知人数と締切時刻', () {
      final v = SlotRowView.from(slot(), now: now, nameOf: names);
      expect(v.label, '募集中');
      expect(v.detail, contains('通知 3 名'));
      expect(v.detail, contains('15:00'));
    });

    test('expired は「受付終了」', () {
      final v = SlotRowView.from(
        slot(expiresAt: now.subtract(const Duration(hours: 1))),
        now: now,
        nameOf: names,
      );
      expect(v.label, '受付終了');
    });

    test('released は「再募集中」でキャンセルを明示', () {
      final v = SlotRowView.from(slot(status: 'released'),
          now: now, nameOf: names);
      expect(v.label, '再募集中');
      expect(v.detail, contains('キャンセル'));
    });
  });

  // ══════════════════════════════════════════════════════════════
  group('SlotService.parse: 選択日のみ', () {
    test('dateKey が違う枠は取り除かれる', () {
      final out = SlotService.parse([
        {'__id': 'a', 'dateKey': '2026-10-05', 'status': 'open'},
        {'__id': 'b', 'dateKey': '2026-10-04', 'status': 'filled'},
        {'__id': 'c', 'dateKey': '2026-10-06', 'status': 'open'},
        {'__id': 'd', 'status': 'open'}, // dateKey 欠落
      ], '2026-10-05');
      expect(out.map((e) => e.id), ['a']);
    });

    test('watchByDate は選択日の dateKey でクエリを発行する', () async {
      final asked = <String>[];
      SlotService.instance.runnerOverride = (k) {
        asked.add(k);
        return Stream.value([
          {'__id': 'x', 'dateKey': k, 'status': 'open'},
        ]);
      };
      addTearDown(() => SlotService.instance.runnerOverride = null);

      final r = await SlotService.instance
          .watchByDate(DateTime(2026, 10, 5))
          .first;
      expect(asked, ['2026-10-05']);
      expect(r, hasLength(1));
    });

    test('取得エラーは空リストにせず error として伝わる', () async {
      SlotService.instance.runnerOverride =
          (_) => Stream.error(StateError('permission-denied'));
      addTearDown(() => SlotService.instance.runnerOverride = null);

      expect(
        SlotService.instance.watchByDate(DateTime(2026, 10, 5)).first,
        throwsA(isA<StateError>()),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════
  group('SlotStatusPanel / SlotChip ウィジェット', () {
    Widget wrap(Widget w) => MaterialApp(home: Scaffold(body: w));

    testWidgets('枠が無く正常ならパネルは出ない（画面を汚さない）',
        (tester) async {
      await tester.pumpWidget(wrap(
          SlotStatusPanel(slots: const [], now: now, nameOf: names)));
      expect(find.byKey(const Key('slotStatusPanel')), findsNothing);
    });

    testWidgets('filled のとき 応募者名・時刻・確定バッジ が出る',
        (tester) async {
      final s = slot(
        status: 'filled',
        claimedBy: {
          'customerId': 'taker1',
          'claimedAt': DateTime(2026, 10, 5, 10, 23),
        },
      );
      await tester.pumpWidget(wrap(
          SlotStatusPanel(slots: [s], now: now, nameOf: names)));
      expect(find.text('LINE応募'), findsOneWidget);
      expect(find.text('確定'), findsOneWidget);
      expect(find.textContaining('佐藤 花子さん'), findsOneWidget);
      expect(find.textContaining('10:23'), findsOneWidget);
      expect(find.textContaining('山田 太郎さんの欠席枠'), findsOneWidget);
    });

    testWidgets('エラー時は「応募なし」ではなくエラーを明示する',
        (tester) async {
      await tester.pumpWidget(wrap(SlotStatusPanel(
        slots: const [],
        now: now,
        nameOf: names,
        error: '通信または権限のエラー',
      )));
      expect(find.byKey(const Key('slotStatusError')), findsOneWidget);
      expect(find.textContaining('取得できませんでした'), findsOneWidget);
    });

    testWidgets('SlotChip: 確定は応募者名まで、募集中はラベルのみ',
        (tester) async {
      final filled = SlotRowView.from(
        slot(
          status: 'filled',
          claimedBy: {
            'customerId': 'taker1',
            'claimedAt': DateTime(2026, 10, 5, 8, 5),
          },
        ),
        now: now,
        nameOf: names,
      );
      await tester.pumpWidget(wrap(SlotChip(view: filled)));
      expect(find.textContaining('LINE応募: 確定'), findsOneWidget);
      expect(find.textContaining('佐藤 花子'), findsOneWidget);

      final open = SlotRowView.from(slot(), now: now, nameOf: names);
      await tester.pumpWidget(wrap(SlotChip(view: open)));
      expect(find.textContaining('LINE応募: 募集中'), findsOneWidget);
      expect(find.textContaining('佐藤 花子'), findsNothing);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // 出席画面そのものを描画して検証（実画面の統合テスト）
  // ══════════════════════════════════════════════════════════════
  group('AttendanceScreen: LINE応募の実画面統合', () {
    final today = DateTime.now();
    String keyOf(DateTime d) => NotificationLog.makeDateKey(d);

    setUp(() async {
      await Hive.box<Customer>('customers').clear();
      await Hive.box<AttendanceRecord>('attendance_records').clear();
      await Hive.box<WeeklySchedule>('weekly_schedules').clear();
      for (final (id, name) in [('absent1', '山田 太郎'), ('taker1', '佐藤 花子')]) {
        await CustomerService.instance.addCustomer(Customer(
          id: id,
          name: name,
          nameKana: 'テスト',
          monthlyAvailableDays: 23,
          // 定期曜日なし: 日付変更時に出席レコードの自動生成(Hive書き込み)を
          // 走らせない。本テストの関心は slots の購読であり出席生成ではない。
          regularDays: const [],
        ));
      }
      // 山田さんを今日欠席にする
      await AttendanceService.instance.upsertRecord(AttendanceRecord(
        customerId: 'absent1',
        customerName: '山田 太郎',
        dateKey: AttendanceRecord.makeDateKey(today),
        status: AttendanceStatus.absent,
        absenceReason: '体調不良',
      ));
    });

    tearDown(() => SlotService.instance.runnerOverride = null);

    Map<String, dynamic> filledDoc(String dateKey) => {
          '__id': '${dateKey}_absent1',
          'dateKey': dateKey,
          'sourceAbsent': 'absent1',
          'status': 'filled',
          'expiresAt': DateTime.now().add(const Duration(hours: 3)),
          'notifiedList': [1, 2],
          'claimedBy': {
            'customerId': 'taker1',
            'claimedAt': DateTime(today.year, today.month, today.day, 10, 23),
          },
        };

    testWidgets('filled の枠: パネルに応募者名＋時刻、欠席カードにチップが出る',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SlotService.instance.runnerOverride =
          (k) => Stream.value([filledDoc(k)]);

      await tester.pumpWidget(const MaterialApp(home: AttendanceScreen()));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      // ① 集計バー直下のパネル
      expect(find.byKey(const Key('slotStatusPanel')), findsOneWidget);
      expect(find.textContaining('佐藤 花子さん'), findsWidgets);
      expect(find.textContaining('10:23'), findsWidgets);
      // ② 欠席カード内のチップ
      expect(find.byKey(const Key('slotChip')), findsOneWidget);
      expect(find.textContaining('LINE応募: 確定'), findsOneWidget);
    });

    testWidgets('購読するのは今日の dateKey のみ', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final asked = <String>[];
      SlotService.instance.runnerOverride = (k) {
        asked.add(k);
        return Stream.value(const []);
      };

      await tester.pumpWidget(const MaterialApp(home: AttendanceScreen()));
      await tester.pump(const Duration(milliseconds: 300));

      expect(asked, [keyOf(today)]);
    });

    testWidgets('他日の枠がストリームに混ざっても表示しない', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final other = keyOf(today.subtract(const Duration(days: 1)));
      SlotService.instance.runnerOverride =
          (k) => Stream.value([filledDoc(other)]);

      await tester.pumpWidget(const MaterialApp(home: AttendanceScreen()));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('slotStatusPanel')), findsNothing);
      expect(find.byKey(const Key('slotChip')), findsNothing);
    });

    testWidgets('日付を変えると購読が張り直され、旧日付の購読は解除される',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final asked = <String>[];
      final cancelled = <String>[];
      SlotService.instance.runnerOverride = (k) {
        asked.add(k);
        late StreamController<List<Map<String, dynamic>>> c;
        c = StreamController<List<Map<String, dynamic>>>(
          onListen: () => c.add([filledDoc(k)]),
          onCancel: () => cancelled.add(k),
        );
        return c.stream;
      };

      await tester.pumpWidget(const MaterialApp(home: AttendanceScreen()));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('slotStatusPanel')), findsOneWidget);

      // 日付ピッカーで「今日と別の日」を選ぶ（今日が1日なら2日、それ以外は1日）
      await tester.tap(find.byIcon(Icons.calendar_today_outlined));
      await tester.pump(const Duration(milliseconds: 400));
      final target = today.day == 1 ? 2 : 1;
      await tester.tap(find.text('$target').last);
      await tester.tap(find.text('決定'));
      // 日付変更で Hive への実ファイル書き込みが走る。FakeAsync 内では
      // 完了しないため runAsync で実時間を進めてから描画する。
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(asked.length, 2);
      expect(asked.first, keyOf(today));
      expect(asked.last, isNot(keyOf(today)));
      expect(asked.last.endsWith('-${target.toString().padLeft(2, '0')}'),
          isTrue);
      // 旧日付の購読は解除されている
      expect(cancelled, contains(keyOf(today)));

      // 画面を破棄して、保留中の Hive 書き込みを実時間で完了させる
      // （残すと tearDownAll の Hive.close が待ち続ける）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      // 破棄後は両方の購読が解除されていること（リーク防止）
      expect(cancelled.toSet(), containsAll(asked));
    });

    testWidgets('取得エラー時は「応募状況を取得できませんでした」を出す',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SlotService.instance.runnerOverride =
          (_) => Stream.error(StateError('permission-denied'));

      await tester.pumpWidget(const MaterialApp(home: AttendanceScreen()));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('slotStatusError')), findsOneWidget);
      // 出席管理そのものは動き続ける
      expect(find.text('山田 太郎'), findsWidgets);
    });

    testWidgets('枠が無い日は何も出ない（従来画面と同じ）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SlotService.instance.runnerOverride = (_) => Stream.value(const []);

      await tester.pumpWidget(const MaterialApp(home: AttendanceScreen()));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('slotStatusPanel')), findsNothing);
      expect(find.byKey(const Key('slotChip')), findsNothing);
    });
  });

  // ══════════════════════════════════════════════════════════════
  group('AppSettings.slotTtlHours: 受付時間の設定', () {
    test('既定は 6 時間（サーバー既定値と一致）', () {
      expect(AppSettings().slotTtlHours, 6);
      expect(AppSettings.defaultSlotTtlHours, 6);
    });

    test('範囲外・null は丸められる', () {
      expect(AppSettings(slotTtlHours: 0).slotTtlHours, 1);
      expect(AppSettings(slotTtlHours: -3).slotTtlHours, 1);
      expect(AppSettings(slotTtlHours: 99).slotTtlHours, 24);
      expect(AppSettings(slotTtlHours: null).slotTtlHours, 6);
      expect(AppSettings(slotTtlHours: 12).slotTtlHours, 12);
    });

    test('Hive の旧データ(field15 なし)読み込みでも既定 6 時間', () {
      // アダプタは fields[15] as int? → null → コンストラクタで既定化
      final s = AppSettings(slotTtlHours: null);
      expect(s.slotTtlHours, AppSettings.defaultSlotTtlHours);
    });

    test('adjustedForVehicleCount が受付時間を引き継ぐ', () {
      final s = AppSettings(slotTtlHours: 9).adjustedForVehicleCount(3);
      expect(s.slotTtlHours, 9);
    });
  });

  group('SettingsService.updateSlotTtlHours', () {
    test('変更が保存され、他の設定を壊さない', () async {
      final svc = SettingsService.instance;
      await svc.updateVacancyNotice(deadline: '11:30', template: '本文{date}');
      await svc.updateFacility('テスト事業所', '帯広市1-1');
      await svc.updateSlotTtlHours(3);

      final s = svc.getSettings();
      expect(s.slotTtlHours, 3);
      expect(s.facilityName, 'テスト事業所');
      expect(s.vacancyReplyDeadline, '11:30');
      expect(s.vacancyMessageTemplate, '本文{date}');
    });

    test('他の更新系メソッドを呼んでも受付時間が既定値に戻らない', () async {
      final svc = SettingsService.instance;
      await svc.updateSlotTtlHours(8);
      await svc.updateFacility('A', 'B');
      expect(svc.getSettings().slotTtlHours, 8);
      await svc.updateVehicles(2, ['x', 'y'], [4, 4]);
      expect(svc.getSettings().slotTtlHours, 8);
      await svc.updateOperatingHours('08:00', '17:00', 9);
      expect(svc.getSettings().slotTtlHours, 8);
      await svc.saveFacilityGeocode(42.9, 143.2);
      expect(svc.getSettings().slotTtlHours, 8);
      await svc.updateVacancyNotice(deadline: '12:00', template: 'テンプレ');
      expect(svc.getSettings().slotTtlHours, 8);
    });

    test('範囲外を保存しようとしても 1〜24 に丸まる', () async {
      final svc = SettingsService.instance;
      await svc.updateSlotTtlHours(500);
      expect(svc.getSettings().slotTtlHours, 24);
      await svc.updateSlotTtlHours(0);
      expect(svc.getSettings().slotTtlHours, 1);
    });
  });
}
