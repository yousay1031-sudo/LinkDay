@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/day_ticker.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/support_plan.dart';
import 'package:linkday_app/screens/home_screen.dart';
import 'package:linkday_app/screens/support_plan_history_screen.dart';
import 'package:linkday_app/screens/support_plan_list_screen.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/services/support_plan_service.dart';
import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ3 段階5: 更新時期の知らせ（ホームの印・一覧・日付が変わったとき・消える条件）
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
    tmp = await Directory.systemTemp.createTemp('linkday_plan_alerts_');
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

  SupportPlan plan(String id, String cid, DateTime created) => SupportPlan(
        id: id,
        customerId: cid,
        customerName: '架空 $cid',
        createdOn: created,
        managerName: '職員 冬子',
        explainedOn: created,
        agreedOn: created,
      );

  /// [customers] の児童と [plans] の計画を置き、今日を [today] にする
  Future<void> setUpData(WidgetTester t,
      {required List<String> customers,
      List<SupportPlan> plans = const [],
      required DateTime today}) async {
    DayTicker.instance.now = () => today.add(const Duration(hours: 10));
    await io(t, () async {
      await FakeBackend.attachWithStaff();
      await SettingsService.instance.init();
      for (final id in customers) {
        await CustomerService.instance.addCustomer(
            Customer(id: id, name: '架空 $id', nameKana: 'カクウ $id'),
            stamp: stamp);
      }
      for (final p in plans) {
        // 状態は同意を得た日から決まる（ここでは同意済み）。行が無くても置けるよう直接書く
        await FakeBackend.current.db
            .collection(FsPaths.facilities)
            .doc(FakeBackend.current.facilityId)
            .collection(FsPaths.supportPlans)
            .doc(p.id)
            .set({
          ...p.toFirestoreData(),
          'status': 'agreed',
          'updatedByStaffName': '検証データ',
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  }

  Future<void> openHome(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
        MaterialApp(theme: AppTheme.lightTheme, home: const HomeScreen()));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await _ms(t, 1500);
  }

  Future<void> closeHome(WidgetTester t) async {
    await t.pumpWidget(const SizedBox.shrink());
    await _ms(t, 3000);
  }

  String badgeText(WidgetTester t) => t
      .widget<Text>(find.descendant(
          of: find.byKey(const Key('homePlanBadge')),
          matching: find.byType(Text)))
      .data!;

  // 作成 2026-05-01 → 期限 2026-11-01
  final created = DateTime(2026, 5, 1);

  testWidgets('ホーム: 個別支援計画のタイルに件数の印。過ぎた期限があれば強い色。押すと期限の近い順の一覧', (t) async {
    await setUpData(t,
        customers: ['none', 'near', 'over', 'ok'],
        plans: [
          plan('p-near', 'near', created), // 期限 11/1
          plan('p-over', 'over', DateTime(2026, 4, 1)), // 期限 10/1
          plan('p-ok', 'ok', DateTime(2026, 10, 1)), // 期限 4/1
        ],
        today: DateTime(2026, 10, 25));
    await openHome(t);
    expect(badgeText(t), '3');
    expect(
        t.widget<Container>(find.byKey(const Key('homePlanBadge'))).decoration,
        isA<BoxDecoration>().having((d) => d.color, 'color', AppColors.error));
    expect(find.byKey(const Key('homePlanAlertButton')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('homeMenu_/support-plan')));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await _ms(t, 1500);
    expect(find.byType(SupportPlanListScreen), findsOneWidget);
    final ys = [
      for (final id in ['none', 'over', 'near'])
        t.getTopLeft(find.byKey(Key('planAlertText_$id'))).dy
    ];
    expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue, reason: '$ys');
    expect(find.text('架空 noneさん：個別支援計画がまだありません'), findsOneWidget);
    expect(find.text('架空 overさん：計画の更新期限を過ぎています'), findsOneWidget);
    expect(
        t
            .widget<Text>(find.byKey(const Key('planAlertText_over')))
            .style!
            .color,
        AppColors.error);
    expect(find.text('架空 nearさん：計画の更新期限が近づいています'), findsOneWidget);
    expect(find.byKey(const Key('planAlertText_ok')), findsNothing);
    await closeHome(t);
  });

  testWidgets('画面を開いたまま日付が変わると、新しい日付で計算し直す（ホームと一覧）', (t) async {
    // 46 日前（知らせなし）→ 日付が変わって 45 日前（アセスメントの時期）
    var today = DateTime(2026, 9, 16);
    await setUpData(t,
        customers: ['a'], plans: [plan('p1', 'a', created)], today: today);
    DayTicker.instance.now = () => today.add(const Duration(hours: 23));
    await openHome(t);
    expect(find.byKey(const Key('homePlanBadge')), findsNothing);
    today = DateTime(2026, 9, 17);
    DayTicker.instance.now = () => today.add(const Duration(minutes: 1));
    DayTicker.instance.check();
    await _ms(t, 200);
    expect(badgeText(t), '1');
    expect(
        t.widget<Container>(find.byKey(const Key('homePlanBadge'))).decoration,
        isA<BoxDecoration>()
            .having((d) => d.color, 'color', AppColors.warning));
    await closeHome(t);

    // 一覧も
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme, home: const SupportPlanListScreen()));
    await _ms(t, 500);
    expect(find.text('架空 aさん：アセスメントの時期です（更新期限 11月1日）'), findsOneWidget);
    today = DateTime(2026, 10, 18); // 14 日前
    DayTicker.instance.check();
    await _ms(t, 200);
    expect(find.text('架空 aさん：計画の更新期限が近づいています'), findsOneWidget);
    expect(find.textContaining('アセスメント未実施'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('アセスメントを実施した日を入れると「アセスメントの時期です」が消える（同意後の修正にはならない）', (t) async {
    await setUpData(t,
        customers: ['a'],
        plans: [plan('p1', 'a', created)],
        today: DateTime(2026, 10, 1));
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme, home: const SupportPlanListScreen()));
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(find.byKey(const Key('planAlertText_a')), findsOneWidget);
    await t.tap(find.byKey(const Key('planAlert_a')));
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(find.byType(SupportPlanHistoryScreen), findsOneWidget);
    expect(find.text('アセスメントを実施した日：未入力'), findsOneWidget);
    await t.tap(find.byKey(const Key('planAssessmentPick')));
    await t.pumpAndSettle();
    await t.tap(find.text('決定'));
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(find.textContaining('アセスメントを実施した日：20'), findsOneWidget);
    final d = (await io(
            t,
            () => FakeBackend.current.db
                .collection(FsPaths.facilities)
                .doc(FakeBackend.current.facilityId)
                .collection(FsPaths.supportPlans)
                .doc('p1')
                .get()))
        .data()!;
    expect(d['assessmentDoneOn'], isNotNull);
    expect(d['status'], 'agreed');
    expect(d[SupportPlan.fRevisedAt], isNull);
    expect(SupportPlanService.instance.getById('p1')!.revisedAfterAgreement,
        isFalse);
    await t.pageBack();
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(find.byKey(const Key('planAlertText_a')), findsNothing);
    expect(find.byKey(const Key('planAlertsNone')), findsOneWidget);
  });
}
