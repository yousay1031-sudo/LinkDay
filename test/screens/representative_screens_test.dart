import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/transport_plan.dart';
import 'package:linkday_app/screens/attendance_screen.dart';
import 'package:linkday_app/screens/customer_management_screen.dart';
import 'package:linkday_app/screens/transport_screen.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/monthly_usage_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/services/transport_plan_service.dart';
import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/widgets/skeletons/screen_skeletons.dart';

import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/utils/week_util.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import '../support/fake_backend.dart';

/// 代表画面（出席管理・顧客一覧・送迎計画）の
/// 初期読込 / 正常 / 空 / エラー / 再試行 / 日付切替（古い結果の破棄）を、
/// 共通部品ではなく「実画面」への接続として検証する。
///
/// 実行: flutter test test/screens/representative_screens_test.dart
/// 実顧客データは使わない（一時ディレクトリの Hive にダミーのみ）。
///
/// 【Hive 実 I/O と FakeAsync】
/// Hive の書込みは実ファイル I/O のため、FakeAsync 内の pump では完了しない。
/// データ投入は tester.runAsync で行い、画面内で書込みが起きるテストでは
/// runAsync の実時間待ちで書込みを完了させる。

final _sunday = DateTime(2026, 3, 1);
final _monday = DateTime(2026, 3, 2);

typedef _T = WidgetTester;

Future<void> _ms(_T t, int ms) async {
  var left = ms;
  while (left > 0) {
    final step = left > 16 ? 16 : left;
    await t.pump(Duration(milliseconds: step));
    left -= step;
  }
}

/// Hive など実 I/O を完了させる
Future<void> _real(_T t, [int ms = 250]) async {
  for (var i = 0; i < 3; i++) {
    await t
        .runAsync(() => Future<void>.delayed(Duration(milliseconds: ms ~/ 3)));
    await t.pump();
  }
}

bool _skeletonVisible(_T t, Type type) {
  final f = find.byWidgetPredicate((w) => w.runtimeType == type);
  if (f.evaluate().isEmpty) return false;
  final ops = t.widgetList<Opacity>(
      find.ancestor(of: f.first, matching: find.byType(Opacity)));
  return ops.every((o) => o.opacity > 0);
}

/// 画面を外し、FakeAsync 内で開始された Hive 書込みの完了を待つ。
/// （書込みの継続は実 I/O 完了後に pump しないと進まず、未完了のまま次のテストの
///  Hive 操作が同じボックスのロックで待たされるのを防ぐ）
Future<void> _unmount(_T t) async {
  await t.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 4; i++) {
    await t
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await t.pump();
  }
}

Customer _cust(String name, {List<int> days = const []}) => Customer(
      name: name,
      nameKana: 'カナ$name',
      regularDays: days,
      recipientCertNumber: 'D-$name',
    );

void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_rep_screens_');
    Hive.init(tmp.path);
    // 型引数を保つため 1 つずつ登録する（List<TypeAdapter<dynamic>> 経由だと
    // Hive が全て dynamic として登録してしまう）

    await FakeBackend.attachWithStaff();
    // 週間利用計画は Firestore（FakeBackend.attachWithStaff で接続済み）
    // 出席は Firestore（FakeBackend.attachWithStaff で接続済み）
    await SettingsService.instance.init();
    // 送迎計画は Firestore（FakeBackend.attachWithStaff で接続済み）
    SlotService.instance.remoteEnabled = false;
  });

  tearDownAll(() async {
    await Future.any<Object?>([
      Hive.close(),
      Future<Object?>.delayed(const Duration(seconds: 3)),
    ]);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() => AppMotion.debugDisableLooping = true);
  tearDown(() => AppMotion.debugDisableLooping = false);

  // ════════════════════════════════════════════════════════════
  // 出席管理
  // ════════════════════════════════════════════════════════════
  group('出席管理画面', () {
    final gates = <String, Completer<void>>{};
    final failures = <String>{};
    String keyOf(DateTime d) => AttendanceRecord.makeDateKey(d);

    Future<void> hook(DateTime d) async {
      final k = keyOf(d);
      if (failures.contains(k)) throw StateError('boom $k');
      final g = gates[k];
      if (g != null) await g.future;
    }

    setUp(() {
      gates.clear();
      failures.clear();
    });

    Future<void> seed(_T t) => t.runAsync(() async {
          final att = AttendanceService.instance;
          await FakeBackend.resetAttendance();
          await FakeBackend.resetCustomers();
          // 日付ごとに別の名前（旧日付の取り違え検出用）
          for (final n in ['今日 一郎', '今日 二郎']) {
            await att.upsertRecord(AttendanceRecord(
                customerId: 'c-$n',
                customerName: n,
                dateKey: keyOf(DateTime.now())));
          }
          for (final n in ['月曜 花子', '月曜 太郎']) {
            await att.upsertRecord(AttendanceRecord(
                customerId: 'm-$n', customerName: n, dateKey: keyOf(_monday)));
          }
        }) as Future<void>;

    Future<void> pump(_T t) async {
      await seed(t);
      await t.pumpWidget(
          MaterialApp(home: AttendanceScreen(afterEnsureHook: hook)));
    }

    dynamic st(_T t) => t.state(find.byType(AttendanceScreen));

    testWidgets('初期読込: 120ms 猶予→骨格→完了後に内容（旧表示の残留なし）', (t) async {
      gates[keyOf(DateTime.now())] = Completer<void>();
      await pump(t);
      await _ms(t, 80);
      expect(_skeletonVisible(t, AttendanceSkeleton), isFalse,
          reason: '猶予内は骨格を出さない');
      expect(find.text('今日 一郎'), findsNothing);
      await _ms(t, 100);
      expect(_skeletonVisible(t, AttendanceSkeleton), isTrue);
      gates[keyOf(DateTime.now())]!.complete();
      await _ms(t, 400);
      await _ms(t, 400);
      expect(find.text('今日 一郎'), findsOneWidget);
      expect(find.text('今日 二郎'), findsOneWidget);
      expect(_skeletonVisible(t, AttendanceSkeleton), isFalse);
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('空: 利用予定者がいない日は空状態と「日付を変更」導線', (t) async {
      await pump(t);
      await _ms(t, 600);
      expect(find.text('今日 一郎'), findsOneWidget);
      await (st(t).debugSelectDate(_sunday) as Future<void>);
      await _ms(t, 700);
      expect(find.text('本日の利用予定者はいません'), findsOneWidget);
      expect(find.text('日付を変更'), findsOneWidget);
      expect(find.text('今日 一郎'), findsNothing);
      await _unmount(t);
    });

    testWidgets('エラー→再試行: 失敗は固まらずエラー表示、再試行で内容に復帰', (t) async {
      final today = keyOf(DateTime.now());
      failures.add(today);
      await pump(t);
      await _ms(t, 300);
      expect(find.byKey(const Key('errorRetryMessage')), findsOneWidget);
      expect(find.text('出席情報の読み込みに失敗しました'), findsOneWidget);
      expect(find.text('今日 一郎'), findsNothing);
      expect(_skeletonVisible(t, AttendanceSkeleton), isFalse,
          reason: '失敗後に骨格のまま固まらない');
      // 再試行（まだ失敗する）→ 再びエラー
      await t.tap(find.byKey(const Key('errorRetryButton')));
      await _ms(t, 700);
      expect(find.byKey(const Key('errorRetryMessage')), findsOneWidget);
      // 原因解消後の再試行 → 内容
      failures.clear();
      await t.tap(find.byKey(const Key('errorRetryButton')));
      await _ms(t, 800);
      expect(find.byKey(const Key('errorRetryMessage')), findsNothing);
      expect(find.text('今日 一郎'), findsOneWidget);
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('日付切替: 切替中に旧日付の名前を新日付として見せない / 新日付の内容が出る', (t) async {
      await pump(t);
      await _ms(t, 600);
      expect(find.text('今日 一郎'), findsOneWidget);
      gates[keyOf(_monday)] = Completer<void>();
      unawaited(st(t).debugSelectDate(_monday) as Future<void>);
      await t.pump();
      expect(find.text('今日 一郎'), findsNothing, reason: '日付変更直後から旧日付のデータを出さない');
      await _ms(t, 300);
      expect(find.text('今日 一郎'), findsNothing);
      expect(find.text('月曜 花子'), findsNothing);
      gates[keyOf(_monday)]!.complete();
      await _ms(t, 800);
      expect(find.text('月曜 花子'), findsOneWidget);
      expect(find.text('今日 一郎'), findsNothing);
      await _unmount(t);
    });

    testWidgets('動作軽減: 骨格→内容がフェードなしで切り替わる（読込・エラー導線は同じ）', (t) async {
      gates[keyOf(DateTime.now())] = Completer<void>();
      await seed(t);
      await t.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: AttendanceScreen(afterEnsureHook: hook),
        ),
      ));
      await _ms(t, 200);
      expect(_skeletonVisible(t, AttendanceSkeleton), isTrue);
      gates[keyOf(DateTime.now())]!.complete();
      await _ms(t, 300); // minDisplay(250ms) 経過
      await _ms(t, 32);
      expect(find.text('今日 一郎'), findsOneWidget);
      expect(_skeletonVisible(t, AttendanceSkeleton), isFalse);
      await _unmount(t);
    });

    testWidgets(
        '古い読込結果の破棄: 遅れて完了した旧日付が新日付を上書きせず、'
        '旧日付の保存（レコード生成）は中断されない', (t) async {
      // 月曜の児童（定期利用: 月）→ 月曜を開くと scheduled レコードが生成される
      await pump(t);
      await t.runAsync(() =>
          CustomerService.instance.addCustomer(_cust('月曜 生成', days: [1])));
      await _ms(t, 600);

      gates[keyOf(_monday)] = Completer<void>();
      // 出席は Firestore（端末内の記録で確かめる。旧: Hive の box.containsKey）
      final genId = CustomerService.instance.getAllCustomers().first.id;
      bool generated() =>
          AttendanceService.instance.getRecord(genId, _monday) != null;
      expect(generated(), isFalse);

      // A=月曜（保存後に保留）→ すぐ B=日曜へ切替
      unawaited(st(t).debugSelectDate(_monday) as Future<void>);
      await t.pump();
      await _real(t); // 月曜側の保存（Hive 実 I/O）を完了させる
      expect(generated(), isTrue, reason: '表示結果を捨てる前に、必要な保存は完了している');

      await (st(t).debugSelectDate(_sunday) as Future<void>);
      await _ms(t, 700);
      expect(find.text('本日の利用予定者はいません'), findsOneWidget);

      // 遅れて A が完了しても B の表示を上書きしない
      gates[keyOf(_monday)]!.complete();
      await _ms(t, 700);
      expect(find.text('本日の利用予定者はいません'), findsOneWidget);
      expect(find.text('月曜 花子'), findsNothing);
      expect(find.text('月曜 生成'), findsNothing);
      expect(generated(), isTrue, reason: '生成済みレコードは残る');
      await _unmount(t);
    });
  });

  // ════════════════════════════════════════════════════════════
  // 顧客一覧
  // ════════════════════════════════════════════════════════════
  group('顧客一覧画面', () {
    Completer<List<MonthlyUsage>>? gate;
    bool fail = false;

    Future<List<MonthlyUsage>> loader() {
      if (fail) return Future.error(StateError('usage boom'));
      final g = gate;
      return g != null ? g.future : Future.value(const <MonthlyUsage>[]);
    }

    setUp(() {
      gate = null;
      fail = false;
    });

    Future<void> seed(_T t, List<Customer> list) => t.runAsync(() async {
          await FakeBackend.resetCustomers();
          for (final c in list) {
            await CustomerService.instance.addCustomer(c);
          }
        }) as Future<void>;

    Future<void> pump(_T t) => t.pumpWidget(
        MaterialApp(home: CustomerManagementScreen(usageLoader: loader)));

    testWidgets('初期読込: 骨格→内容 / 50 件超でも一覧が出る', (t) async {
      await seed(t, [
        for (var i = 0; i < 55; i++) _cust('顧客${i.toString().padLeft(2, '0')}')
      ]);
      gate = Completer<List<MonthlyUsage>>();
      await pump(t);
      await _ms(t, 80);
      expect(_skeletonVisible(t, CustomerListSkeleton), isFalse);
      await _ms(t, 100);
      expect(_skeletonVisible(t, CustomerListSkeleton), isTrue);
      expect(find.text('顧客00'), findsNothing);
      gate!.complete(const []);
      await _ms(t, 800);
      expect(_skeletonVisible(t, CustomerListSkeleton), isFalse);
      expect(find.text('顧客00'), findsOneWidget);
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('空: 顧客 0 件は空状態と登録導線 / 検索不一致は別の空状態', (t) async {
      await seed(t, []);
      await pump(t);
      await _ms(t, 800);
      expect(find.text('顧客がまだ登録されていません'), findsOneWidget);
      expect(find.text('Excel一括登録'), findsOneWidget);
      await _unmount(t);

      await seed(t, [_cust('検索 太郎')]);
      await pump(t);
      await _ms(t, 800);
      expect(find.text('検索 太郎'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'zzz存在しない');
      await _ms(t, 600);
      expect(find.textContaining('に一致する顧客が見つかりません'), findsOneWidget);
      expect(find.text('検索を消す'), findsOneWidget);
      await _unmount(t);
    });

    testWidgets('エラー→再試行: 失敗時はエラー表示、再試行で一覧に復帰', (t) async {
      await seed(t, [_cust('復帰 太郎')]);
      fail = true;
      await pump(t);
      await _ms(t, 500);
      expect(find.text('顧客情報の読み込みに失敗しました'), findsOneWidget);
      expect(find.text('復帰 太郎'), findsNothing);
      await t.tap(find.byKey(const Key('errorRetryButton')));
      await _ms(t, 700);
      expect(find.byKey(const Key('errorRetryMessage')), findsOneWidget,
          reason: '再試行も失敗すれば再びエラー（骨格で固まらない）');
      fail = false;
      await t.tap(find.byKey(const Key('errorRetryButton')));
      await _ms(t, 900);
      expect(find.byKey(const Key('errorRetryMessage')), findsNothing);
      expect(find.text('復帰 太郎'), findsOneWidget);
      expect(t.takeException(), isNull);
      await _unmount(t);
    });
  });

  // ════════════════════════════════════════════════════════════
  // 送迎計画
  // ════════════════════════════════════════════════════════════
  group('送迎計画画面', () {
    final gates = <String, Completer<List<Customer>>>{};
    final failures = <String>{};
    String keyOf(DateTime d) => AttendanceRecord.makeDateKey(d);

    Future<List<Customer>> loader(DateTime d) {
      final k = keyOf(d);
      if (failures.contains(k)) return Future.error(StateError('route boom'));
      final g = gates[k];
      return g != null ? g.future : Future.value(<Customer>[_cust('予定 太郎')]);
    }

    setUp(() {
      gates.clear();
      failures.clear();
    });

    Future<void> seed(_T t, {required bool routeToday}) => t.runAsync(() async {
          await FakeBackend.resetTransport();
          if (routeToday) {
            await TransportPlanService.instance.saveRoute(TransportVehicleRoute(
              vehicleName: '車両テスト号',
              vehicleIndex: 0,
              transportType: TransportType.pickup,
              dateKey: keyOf(DateTime.now()),
              stops: [
                TransportStop(
                    customerId: 'x',
                    customerName: '送迎 太郎',
                    address: '帯広市テスト1-1')
              ],
            ));
          }
        }) as Future<void>;

    Future<void> pump(_T t) => t.pumpWidget(
        MaterialApp(home: TransportScreen(scheduledCustomersLoader: loader)));

    testWidgets('初期読込→正常: 骨格のあとルート（車両名・停留所）が出る', (t) async {
      await seed(t, routeToday: true);
      gates[keyOf(DateTime.now())] = Completer<List<Customer>>();
      await pump(t);
      await _ms(t, 80);
      expect(_skeletonVisible(t, TransportSkeleton), isFalse);
      await _ms(t, 100);
      expect(_skeletonVisible(t, TransportSkeleton), isTrue);
      expect(find.text('車両テスト号'), findsNothing);
      gates[keyOf(DateTime.now())]!.complete([_cust('予定 太郎')]);
      await _ms(t, 900);
      expect(_skeletonVisible(t, TransportSkeleton), isFalse);
      expect(find.text('車両テスト号'), findsOneWidget);
      expect(find.text('送迎 太郎'), findsOneWidget);
      expect(find.text('利用予定 1 名'), findsOneWidget);
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('お休みになった児童の停留所に「お休み」と出る（ルートからは外さない。ステップ4）', (t) async {
      await seed(t, routeToday: true);
      await t.runAsync(() async {
        final today = DateTime.now();
        final w = WeeklyScheduleService.instance;
        await w.getOrCreateSchedule(WeekUtil.weekStartFromDate(today), [
          Customer(
              id: 'x',
              name: '送迎 太郎',
              nameKana: 'ソウゲイ タロウ',
              regularDays: [today.weekday])
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await pump(t);
      await _ms(t, 900);
      expect(find.text('送迎 太郎'), findsOneWidget);
      expect(find.text('お休み'), findsNothing);
      await t.runAsync(() async {
        final today = DateTime.now();
        await WeeklyScheduleService.instance.updateEntryStatus(
            WeekUtil.weekKeyFromDate(today),
            today.weekday,
            'x',
            ScheduleStatus.cancelled);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await _ms(t, 300);
      expect(find.text('お休み'), findsOneWidget);
      expect(find.text('送迎 太郎'), findsOneWidget); // 自動では外さない
      expect(t.takeException(), isNull);
      await t.runAsync(() => FakeBackend.resetSchedules());
      await _unmount(t);
    });

    testWidgets('定員を超えた車は「満員」ではなく「定員超過 7名」、車が足りないことを画面の上にも出す', (t) async {
      await t.runAsync(() async {
        await FakeBackend.resetTransport();
        final day = keyOf(DateTime.now());
        TransportStop stop(int i) => TransportStop(
            customerId: 'c$i', customerName: '送迎 児童$i', address: '帯広市テスト$i');
        await TransportPlanService.instance.saveRoute(TransportVehicleRoute(
          vehicleName: '車両A',
          vehicleIndex: 0,
          transportType: TransportType.pickup,
          dateKey: day,
          capacity: 6,
          stops: [for (var i = 0; i < 13; i++) stop(i)],
        ));
        // ちょうど定員の車は従来どおり「満員」
        await TransportPlanService.instance.saveRoute(TransportVehicleRoute(
          vehicleName: '車両B',
          vehicleIndex: 1,
          transportType: TransportType.pickup,
          dateKey: day,
          capacity: 2,
          stops: [stop(20), stop(21)],
        ));
      });
      await pump(t);
      await _ms(t, 900);
      expect(find.text('13/6名'), findsOneWidget);
      expect(find.text('定員超過 7名'), findsOneWidget);
      expect(find.text('2/2名'), findsOneWidget);
      expect(find.text('満員'), findsOneWidget); // 車両B だけ
      // 定員超過の印は強い色（赤地に白い文字）
      final over = t.widget<Text>(find.text('定員超過 7名'));
      expect(over.style!.color, Colors.white);
      final banner = find.byKey(const Key('transportShortage'));
      expect(banner, findsOneWidget);
      expect(
          find.descendant(
              of: banner, matching: find.text('お迎え：車が足りません。乗れない人数 7名')),
          findsOneWidget);
      // 画面の上（タブより上）に出る
      expect(t.getTopLeft(banner).dy,
          lessThan(t.getTopLeft(find.byType(TabBar)).dy));
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('お休みの児童は、タブと車ごとの人数に入れない。お休みが何人含まれているかも出す', (t) async {
      final today = DateTime.now();
      await t.runAsync(() async {
        await FakeBackend.resetTransport();
        await WeeklyScheduleService.instance
            .getOrCreateSchedule(WeekUtil.weekStartFromDate(today), [
          for (final id in ['p', 'q', 'r'])
            Customer(
                id: id,
                name: '送迎 $id',
                nameKana: 'ソウゲイ $id',
                regularDays: [today.weekday])
        ]);
        await TransportPlanService.instance.saveRoute(TransportVehicleRoute(
          vehicleName: '車両A',
          vehicleIndex: 0,
          transportType: TransportType.pickup,
          dateKey: keyOf(today),
          capacity: 2,
          stops: [
            for (final id in ['p', 'q', 'r'])
              TransportStop(
                  customerId: id, customerName: '送迎 $id', address: '帯広市テスト')
          ],
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await pump(t);
      await _ms(t, 900);
      String tab() =>
          t.widget<Text>(find.byKey(const Key('transportTabPickup'))).data!;
      expect(tab(), 'お迎え（3名）');
      expect(find.text('3/2名'), findsOneWidget);
      expect(find.text('定員超過 1名'), findsOneWidget);
      // q をお休みにする: 人数から引き、お休みの人数を出す。定員超過も消える
      await t.runAsync(() async {
        await WeeklyScheduleService.instance.updateEntryStatus(
            WeekUtil.weekKeyFromDate(today),
            today.weekday,
            'q',
            ScheduleStatus.cancelled);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await _ms(t, 300);
      expect(tab(), 'お迎え（2名・お休み1）');
      expect(find.text('2/2名'), findsOneWidget);
      expect(find.text('お休み 1名'), findsOneWidget);
      expect(find.text('定員超過 1名'), findsNothing);
      expect(find.text('満員'), findsOneWidget);
      expect(find.text('送迎 q'), findsOneWidget); // ルートからは外さない
      expect(t.takeException(), isNull);
      await t.runAsync(() => FakeBackend.resetSchedules());
      await _unmount(t);
    });

    testWidgets('空: ルートが無い日は空状態（お迎え・お送りとも）', (t) async {
      await seed(t, routeToday: false);
      await pump(t);
      await _ms(t, 900);
      expect(find.text('お迎え ルートがありません'), findsOneWidget);
      await _unmount(t);
    });

    testWidgets('エラー→再試行: 失敗はエラー表示、再試行で復帰', (t) async {
      await seed(t, routeToday: true);
      failures.add(keyOf(DateTime.now()));
      await pump(t);
      await _ms(t, 500);
      expect(find.byKey(const Key('errorRetryMessage')), findsOneWidget);
      expect(find.textContaining('読み込みエラー'), findsWidgets);
      expect(find.text('車両テスト号'), findsNothing);
      expect(_skeletonVisible(t, TransportSkeleton), isFalse);
      failures.clear();
      await t.tap(find.byKey(const Key('errorRetryButton')));
      await _ms(t, 900);
      expect(find.byKey(const Key('errorRetryMessage')), findsNothing);
      expect(find.text('車両テスト号'), findsOneWidget);
      expect(t.takeException(), isNull);
      await _unmount(t);
    });

    testWidgets('日付切替: 切替中は旧日付のルートを見せず、遅れて完了した古い結果は破棄', (t) async {
      await seed(t, routeToday: true);
      await pump(t);
      await _ms(t, 900);
      expect(find.text('車両テスト号'), findsOneWidget);

      // 前日へ（保留）→ 旧日付（今日）のルートは即座に消える
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      gates[keyOf(yesterday)] = Completer<List<Customer>>();
      await t.tap(find.byIcon(Icons.chevron_left));
      await t.pump();
      expect(find.text('車両テスト号'), findsNothing, reason: '日付変更直後から旧日付のルートを出さない');
      await _ms(t, 300);
      expect(find.text('車両テスト号'), findsNothing);

      // すぐ翌日（=今日）へ戻す → 今日のルートが出る
      await t.tap(find.byIcon(Icons.chevron_right));
      await _ms(t, 900);
      expect(find.text('車両テスト号'), findsOneWidget);

      // 前日の古い読込が遅れて完了しても、表示（今日）を上書きしない
      gates[keyOf(yesterday)]!.complete([]);
      await _ms(t, 600);
      expect(find.text('車両テスト号'), findsOneWidget);
      expect(find.byKey(const Key('errorRetryMessage')), findsNothing);
      await _unmount(t);
    });
  });
}

// ignore: unused_element
