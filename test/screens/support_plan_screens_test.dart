@Timeout(Duration(seconds: 180))
library;

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/models/support_plan.dart';
import 'package:linkday_app/models/support_plan_form.dart';
import 'package:linkday_app/screens/support_plan_edit_screen.dart';
import 'package:linkday_app/screens/support_plan_history_screen.dart';
import 'package:linkday_app/screens/support_plan_list_screen.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/support_plan_pdf_service.dart';
import 'package:linkday_app/services/support_plan_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ3 段階3: 個別支援計画の一覧・履歴・入力
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  const fuyuko = Staff(
      id: 's-a', name: '職員 冬子', role: StaffRole.childDevManager, workDays: [1]);
  const sato = Staff(id: 's-b', name: '佐藤');
  const stamp = AuditStamp(staffId: 's-a', staffName: '職員 冬子');
  final today = DateTime(2026, 11, 26);
  DateTime now0() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return v;
      })) as T;

  CollectionReference<Map<String, dynamic>> col() {
    final b = FakeBackend.current;
    return b.db
        .collection(FsPaths.facilities)
        .doc(b.facilityId)
        .collection(FsPaths.supportPlans);
  }

  Customer cust(String id, String name, String kana,
          {List<int> days = const [1, 3], bool active = true}) =>
      Customer(
          id: id,
          name: name,
          nameKana: kana,
          birthday: DateTime(2019, 4, 30),
          regularDays: days,
          isActive: active);

  SupportPlanRow row(List<String> cats, String goal,
          {List<String> domains = const []}) =>
      SupportPlanRow(
          categories: cats,
          texts: {SupportPlanForm.rGoal: goal},
          domains: domains);

  SupportPlan plan(String id, String customerId, DateTime createdOn,
      {bool agreed = false}) {
    final p = SupportPlan(
      id: id,
      customerId: customerId,
      customerName: '架空 $customerId',
      birthday: DateTime(2019, 4, 30),
      createdOn: createdOn,
      managerStaffId: 's-a',
      managerName: '職員 冬子',
      texts: const {SupportPlanForm.kIntention: '架空の意向（前回）'},
      rows: [
        row(['self'], '架空の本人支援の目標', domains: ['health', 'motor']),
        row(['family'], '架空の家族支援の目標'),
        row(['transition'], '架空の移行支援の目標'),
      ],
    );
    return agreed
        ? p.copyWith(explainedOn: () => createdOn, agreedOn: () => createdOn)
        : p;
  }

  Future<void> setUpData(WidgetTester t,
          {List<SupportPlan> plans = const []}) =>
      io(t, () async {
        await FakeBackend.attach(
            staff: const [fuyuko, sato], currentStaffId: 's-a');
        for (final c in [
          cust('a', '架空 あ子', 'カクウ アコ'),
          cust('b', '架空 い太', 'カクウ イタ'),
          cust('c', '架空 う美', 'カクウ ウミ'),
          cust('d', '架空 退所', 'カクウ タイショ', active: false),
        ]) {
          await CustomerService.instance.addCustomer(c, stamp: stamp);
        }
        for (final p in plans) {
          await SupportPlanService.instance
              .save(p, exists: false, stamp: stamp);
        }
      });

  Future<void> open(WidgetTester t, Widget home,
      {Size size = const Size(1280, 1000)}) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(theme: AppTheme.lightTheme, home: home));
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

  Future<void> type(WidgetTester t, Finder f, String text) async {
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.enterText(f, text);
    await t.pumpAndSettle();
  }

  /// 日付の欄を押して、出てきた日付（初期値）のまま「決定」
  Future<void> pickDefaultDate(WidgetTester t, Key field) async {
    await tap(t, find.byKey(field));
    await tap(t, find.text('決定'));
  }

  Future<Map<String, dynamic>?> stored(WidgetTester t, String id) =>
      io(t, () async => (await col().doc(id).get()).data());

  testWidgets('一覧: 在籍中の児童が期限の近い順。計画の無い児童がいちばん上、過ぎた期限は強い色', (t) async {
    await setUpData(t, plans: [
      plan('pb', 'b', DateTime(2026, 6, 1), agreed: true), // 期限 12/1
      plan('pc', 'c', DateTime(2026, 3, 1)), // 作成中だけ: 期限 9/1（過ぎている）
    ]);
    await open(t, SupportPlanListScreen(today: today));
    final ys = {
      for (final id in ['a', 'b', 'c'])
        id: t.getTopLeft(find.byKey(Key('planEntry_$id'))).dy
    };
    expect(ys['a']! < ys['c']! && ys['c']! < ys['b']!, isTrue, reason: '$ys');
    expect(find.byKey(const Key('planEntry_d')), findsNothing); // 在籍終了
    Text txt(String k) => t.widget<Text>(find.byKey(Key(k)));
    expect(
        find.descendant(
            of: find.byKey(const Key('planStatus_a')),
            matching: find.text('計画なし')),
        findsOneWidget);
    expect(txt('planDue_a').data, '—');
    expect(txt('planDue_b').data, '2026/12/1');
    expect(txt('planDue_c').data, '2026/9/1');
    expect(txt('planDue_c').style!.color, AppColors.error);
    expect(find.text('86日過ぎています'), findsOneWidget);
    expect(find.text('あと5日'), findsOneWidget);
  });

  testWidgets('新しい計画（空から）: 顧客・提供時間・児発管が初期値に入り、足りない点が出る。作成中で保存できる', (t) async {
    await setUpData(t);
    await open(t, const SupportPlanHistoryScreen(customerId: 'a'));
    expect(find.textContaining('個別支援計画がまだありません'), findsOneWidget);
    await tap(t, find.byKey(const Key('planNew')));
    expect(find.byType(SupportPlanEditScreen), findsOneWidget);
    expect(find.text('利用児氏名：架空 あ子'), findsOneWidget);
    expect(find.textContaining('2019年4月30日生：7歳'), findsOneWidget);
    final std = t.widget<TextField>(
        find.byKey(const Key('planText_${SupportPlanForm.kStandardTime}')));
    expect(std.controller!.text, startsWith('月・水曜日'));
    expect(
        t
            .widget<DropdownButtonFormField<String>>(
                find.byKey(const Key('planManager')))
            .initialValue,
        's-a');
    // 足りない点
    expect(find.byKey(const Key('planCheckPanel')), findsOneWidget);
    expect(find.textContaining('「本人支援」の行がありません'), findsOneWidget);
    expect(find.textContaining('「家族支援」の行がありません'), findsOneWidget);
    expect(find.textContaining('「移行支援」の行がありません'), findsOneWidget);
    // 同意を得た日は入れられない
    expect(
        t.widget<InkWell>(find.byKey(const Key('planAgreedOn'))).onTap, isNull);
    expect(find.text('足りない点があるため、同意を得た日は入れられません'), findsOneWidget);

    await type(t, find.byKey(const Key('planText_intention')), '架空の意向');
    await tap(t, find.byKey(const Key('planSave')));
    final docs = await io(t, () => col().get());
    final d = docs.docs.single.data();
    expect(d['status'], 'draft');
    expect(d['customerId'], 'a');
    expect(d['createdOn'], isNotNull);
    expect(d['texts']['intention'], '架空の意向');
    expect(d['updatedByStaffName'], '職員 冬子');
    // 履歴に出る
    await t.pageBack();
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(find.text('作成中'), findsOneWidget);
  });

  testWidgets('必須の行を入れ、説明した日・同意を得た日を入れると同意済み。選ばれていない 5 領域は確かめてから', (t) async {
    await setUpData(t);
    final p = plan('p1', 'a', now0()).copyWith(rows: const [], texts: const {});
    await open(t, SupportPlanEditScreen(plan: p, isNew: true));
    // 行を 3 つ足す（本人支援＋移行支援の併記、家族支援、地域支援・地域連携）
    for (var i = 0; i < 3; i++) {
      await tap(t, find.byKey(const Key('planAddRow')));
    }
    await tap(t, find.byKey(const Key('planRow_0_cat_self')));
    await tap(t, find.byKey(const Key('planRow_0_cat_transition')));
    await type(t, find.byKey(const Key('planRow_0_goal')), '架空の目標1');
    await tap(t, find.byKey(const Key('planRow_0_dom_health')));
    await tap(t, find.byKey(const Key('planRow_0_period_3か月後')));
    await tap(t, find.byKey(const Key('planRow_0_staff_s-b')));
    await tap(t, find.byKey(const Key('planRow_1_cat_family')));
    await type(t, find.byKey(const Key('planRow_1_content')), '架空の家族支援');
    await tap(t, find.byKey(const Key('planRow_2_cat_community')));
    await type(t, find.byKey(const Key('planRow_2_goal')), '架空の連携');
    expect(find.textContaining('の行がありません'), findsNothing);
    expect(find.byKey(const Key('planMissingDomains')), findsOneWidget);
    // 説明した日の前は同意を得た日を入れられない
    expect(find.text('先に説明した日を入れてください'), findsOneWidget);
    await pickDefaultDate(t, const Key('planExplainedOn'));
    await pickDefaultDate(t, const Key('planAgreedOn'));
    expect(find.text('5領域のうち選ばれていない領域があります'), findsOneWidget);
    expect(find.textContaining('・運動・感覚'), findsOneWidget);
    await tap(t, find.byKey(const Key('planDomainsBack')));
    expect(find.text('保存する（作成中）'), findsOneWidget); // 同意を得た日は入っていない
    await pickDefaultDate(t, const Key('planAgreedOn'));
    await tap(t, find.byKey(const Key('planDomainsOk')));
    expect(find.text('保存する（同意済み）'), findsOneWidget);
    await tap(t, find.byKey(const Key('planSave')));
    final d = (await stored(t, 'p1'))!;
    expect(d['status'], 'agreed');
    expect(d['agreedOn'], d['explainedOn']);
    final rows = (d['rows'] as List).cast<Map>();
    expect(rows[0]['categories'], ['self', 'transition']);
    expect(rows[0]['domains'], ['health']);
    expect(rows[0]['texts']['period'], '3か月後');
    expect(rows[0]['staff'], [
      {'staffId': 's-b', 'name': '佐藤'}
    ]);
    expect(rows[1]['domains'], isEmpty); // 本人支援でない行は 5 領域を持たない
    expect(rows[1]['priority'], isNull);
    // 同意済みになったので、そのままでは書き換えられない
    expect(find.byKey(const Key('planLockedBanner')), findsOneWidget);
  });

  testWidgets('同意済みの計画: 編集の前に確かめ、軽い修正なら同意済みのまま「同意後に修正あり」', (t) async {
    await setUpData(t,
        plans: [plan('p1', 'b', DateTime(2026, 6, 1), agreed: true)]);
    await open(t, const SupportPlanHistoryScreen(customerId: 'b'));
    await tap(t, find.byKey(const Key('planCard_p1')));
    expect(find.byKey(const Key('planLockedBanner')), findsOneWidget);
    expect(
        t
            .widget<TextField>(find.byKey(const Key('planText_intention')))
            .enabled,
        isFalse);
    await tap(t, find.byKey(const Key('planStartEdit')));
    expect(find.text('同意済みの計画を直します'), findsOneWidget);
    await tap(t, find.byKey(const Key('planEditLight')));
    expect(find.byKey(const Key('planEditModeBanner')), findsOneWidget);
    // 軽い修正では日付を変えられない
    expect(
        t.widget<InkWell>(find.byKey(const Key('planAgreedOn'))).onTap, isNull);
    await type(t, find.byKey(const Key('planText_intention')), '誤字を直した意向');
    await tap(t, find.byKey(const Key('planSave')));
    final d = (await stored(t, 'p1'))!;
    expect(d['status'], 'agreed');
    expect(d['agreedOn'], '2026-06-01');
    expect(d[SupportPlan.fRevisedByName], '職員 冬子');
    expect(d[SupportPlan.fRevisedAt], isNotNull);
    expect(find.textContaining('同意後に修正あり'), findsWidgets);
    await t.pageBack();
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(find.byKey(const Key('planCardRevised_p1')), findsOneWidget);
  });

  testWidgets('同意済みの計画: 内容を変えるなら作成中に戻り、説明した日・同意を得た日が空になる', (t) async {
    await setUpData(t,
        plans: [plan('p1', 'b', DateTime(2026, 6, 1), agreed: true)]);
    await open(
        t,
        SupportPlanEditScreen(
            plan: SupportPlanService.instance.getById('p1')!, isNew: false));
    await tap(t, find.byKey(const Key('planStartEdit')));
    await tap(t, find.byKey(const Key('planEditRevert')));
    expect(find.text('作成中に戻して保存した後に、もう一度入れられます'), findsOneWidget);
    await type(t, find.byKey(const Key('planRow_0_goal')), '目標を変えた');
    await tap(t, find.byKey(const Key('planSave')));
    final d = (await stored(t, 'p1'))!;
    expect(d['status'], 'draft');
    expect(d['explainedOn'], isNull);
    expect(d['agreedOn'], isNull);
    expect((d['rows'] as List)[0]['texts']['goal'], '目標を変えた');
    // 作成中になったので、日付をまた入れられる
    expect(find.byKey(const Key('planLockedBanner')), findsNothing);
    expect(t.widget<InkWell>(find.byKey(const Key('planExplainedOn'))).onTap,
        isNotNull);
  });

  testWidgets('前回の内容を写して作る: 内容は写り、日付と同意は空。元の計画は残る', (t) async {
    await setUpData(t,
        plans: [plan('p1', 'b', DateTime(2026, 6, 1), agreed: true)]);
    await open(t, const SupportPlanHistoryScreen(customerId: 'b'));
    await tap(t, find.byKey(const Key('planNew')));
    expect(find.text('新しい計画を作る'), findsWidgets);
    await tap(t, find.byKey(const Key('planNewCopy')));
    expect(
        t
            .widget<TextField>(find.byKey(const Key('planText_intention')))
            .controller!
            .text,
        '架空の意向（前回）');
    expect(
        t
            .widget<TextField>(find.byKey(const Key('planRow_0_goal')))
            .controller!
            .text,
        '架空の本人支援の目標');
    expect(find.byKey(const Key('planLockedBanner')), findsNothing);
    expect(find.text('保存する（作成中）'), findsOneWidget);
    await tap(t, find.byKey(const Key('planSave')));
    final docs = (await io(t, () => col().get())).docs;
    expect(docs.length, 2);
    final n = docs.firstWhere((d) => d.id != 'p1').data();
    expect(n['copiedFromPlanId'], 'p1');
    expect(n['status'], 'draft');
    expect(n['agreedOn'], isNull);
    expect(n['explainedOn'], isNull);
    expect((await stored(t, 'p1'))!['status'], 'agreed');
  });

  testWidgets('印刷: 保存していない変更があれば保存してから、保存した内容を様式の並びで印刷する', (t) async {
    await setUpData(t, plans: [plan('p1', 'a', DateTime(2026, 6, 1))]);
    PlanPrintData? printed;
    await open(
        t,
        SupportPlanEditScreen(
            plan: SupportPlanService.instance.getById('p1')!,
            isNew: false,
            printer: (d, _) async => printed = d));
    await type(t, find.byKey(const Key('planText_policy')), '印刷前に書いた方針');
    await tap(t, find.byKey(const Key('planPrint')));
    expect(find.text('保存してから印刷します'), findsOneWidget);
    await tap(t, find.byKey(const Key('planSaveAndPrint')));
    expect(printed, isNotNull);
    expect(printed!.policy[1], ('総合的な支援の方針', '印刷前に書いた方針'));
    expect(printed!.tableRows.first.first, '本人支援');
    expect(printed!.agreedDate, PlanPrintData.blankDate);
    expect((await stored(t, 'p1'))!['texts']['policy'], '印刷前に書いた方針');
    // 変更が無ければそのまま印刷する
    printed = null;
    await tap(t, find.byKey(const Key('planPrint')));
    expect(find.text('保存してから印刷します'), findsNothing);
    expect(printed, isNotNull);
  });

  testWidgets('日付の欄は、読み上げ・操作補助で 1 つずつのボタンとして扱われる', (t) async {
    final h = t.ensureSemantics();
    await setUpData(t);
    await open(
        t, SupportPlanEditScreen(plan: plan('p9', 'a', now0()), isNew: true));
    for (final (k, label) in [
      ('planCreatedOn', '作成年月日'),
      ('planExplainedOn', '説明した日'),
      ('planAgreedOn', '同意を得た日'),
    ]) {
      await t.ensureVisible(find.byKey(Key(k)));
      await t.pumpAndSettle();
      final node = t.getSemantics(find.byKey(Key(k)));
      final data = node.getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue, reason: k);
      expect(data.label, contains(label), reason: k);
    }
    h.dispose();
  });

  testWidgets('保存していない変更があるまま閉じようとしたら確かめる', (t) async {
    await setUpData(t, plans: [plan('p1', 'a', DateTime(2026, 6, 1))]);
    await open(t, const SupportPlanHistoryScreen(customerId: 'a'));
    await tap(t, find.byKey(const Key('planCard_p1')));
    await type(t, find.byKey(const Key('planText_policy')), '書きかけ');
    await t.binding.handlePopRoute();
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(find.byType(SupportPlanEditScreen), findsOneWidget);
    await tap(t, find.byKey(const Key('planDiscardOk')));
    expect(find.byType(SupportPlanEditScreen), findsNothing);
  });

  testWidgets('開いただけ（空の文章・並びの違う項目が保存されている計画）なら、閉じるときに確かめない', (t) async {
    await setUpData(t);
    // 検証データと同じく、空の文章や様式と違う並びの項目を持つ計画
    await io(
        t,
        () => col().doc('raw').set({
              'customerId': 'a',
              'customerName': '架空 あ子',
              'createdOn': '2026-06-01',
              'managerName': '職員 冬子',
              'texts': {'intention': '架空の意向 ', 'policy': ''},
              'rows': [
                {
                  'categories': ['transition', 'self'],
                  'texts': {'goal': '架空の目標', 'notes': ''},
                  'domains': ['social', 'health'],
                  'staff': [],
                  'priority': null,
                },
                {
                  'categories': ['family'],
                  'texts': {'goal': '架空の家族'},
                  'domains': [],
                  'staff': [],
                  'priority': null,
                },
              ],
              'status': 'draft',
              'updatedByStaffName': '検証データ',
            }));
    await open(t, const SupportPlanHistoryScreen(customerId: 'a'));
    await tap(t, find.byKey(const Key('planCard_raw')));
    expect(find.byType(SupportPlanEditScreen), findsOneWidget);
    expect(find.byKey(const Key('planDirty')), findsNothing);
    await t.binding.handlePopRoute();
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(find.text('保存していない変更があります'), findsNothing);
    expect(find.byType(SupportPlanEditScreen), findsNothing);
  });

  testWidgets('他の端末で保存されたとき、入力中なら消さずに知らせる', (t) async {
    await setUpData(t, plans: [plan('p1', 'a', DateTime(2026, 6, 1))]);
    await open(
        t,
        SupportPlanEditScreen(
            plan: SupportPlanService.instance.getById('p1')!, isNew: false));
    await type(t, find.byKey(const Key('planText_policy')), '入力中');
    await io(
        t,
        () => col().doc('p1').set({
              'texts': {'intention': '他の端末で直した'},
              'updatedByStaffName': '佐藤',
            }, SetOptions(merge: true)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('planRemoteBanner')), findsOneWidget);
    expect(
        t
            .widget<TextField>(find.byKey(const Key('planText_policy')))
            .controller!
            .text,
        '入力中');
    await tap(t, find.byKey(const Key('planShowLatest')));
    expect(
        t
            .widget<TextField>(find.byKey(const Key('planText_intention')))
            .controller!
            .text,
        '他の端末で直した');
  });

  for (final size in const [Size(1280, 900), Size(820, 1180), Size(530, 900)]) {
    testWidgets('幅 ${size.width.toInt()} で一覧・履歴・入力が崩れない。押す場所は高さ 48 以上',
        (t) async {
      await setUpData(t,
          plans: [plan('p1', 'b', DateTime(2026, 6, 1), agreed: true)]);
      await open(t, SupportPlanListScreen(today: today), size: size);
      expect(t.takeException(), isNull);
      expect(t.getSize(find.byKey(const Key('planEntry_a'))).height,
          greaterThanOrEqualTo(48));
      await t.pumpWidget(const SizedBox.shrink());
      await open(
          t, SupportPlanEditScreen(plan: plan('p2', 'a', now0()), isNew: true),
          size: size);
      expect(t.takeException(), isNull);
      for (final k in [
        'planRow_0_cat_self',
        'planRow_0_dom_health',
        'planRow_0_period_6か月後',
        'planAddRow',
        'planSave',
      ]) {
        final f = find.byKey(Key(k));
        await t.ensureVisible(f);
        await t.pumpAndSettle();
        expect(t.getSize(f).height, greaterThanOrEqualTo(48), reason: k);
      }
      expect(t.getRect(find.byKey(const Key('planSave'))).bottom,
          lessThanOrEqualTo(size.height));
      expect(t.takeException(), isNull);
    });
  }
}
