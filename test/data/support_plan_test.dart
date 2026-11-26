import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/support_plan.dart';
import 'package:linkday_app/models/support_plan_form.dart';
import 'package:linkday_app/models/support_plan_policy.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/services/support_plan_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ3 段階3: 個別支援計画（決まり・保存・初期値・期限の計算）
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  SupportPlanRow row(List<String> cats,
          {String goal = '架空の目標', List<String> domains = const []}) =>
      SupportPlanRow(
          categories: cats,
          texts: {SupportPlanForm.rGoal: goal},
          domains: domains);

  /// 必須の項目が揃った作成中の計画（5 領域もすべて選んである）
  SupportPlan full({String id = 'p1', DateTime? createdOn}) => SupportPlan(
        id: id,
        customerId: 'c1',
        customerName: '架空 一郎',
        createdOn: createdOn ?? DateTime(2026, 5, 1),
        managerName: '職員 冬子',
        texts: const {SupportPlanForm.kIntention: '架空の意向'},
        rows: [
          row(['self'], domains: ['health', 'motor', 'cognition']),
          row(['self', 'transition'], domains: ['language', 'social']),
          row(['family']),
        ],
      );

  group('足りない点（同意済みにできない理由）と 5 領域', () {
    test('揃っていれば同意済みにできる。項目を併記した行も数える', () {
      final c = PlanCheck.of(full());
      expect(c.blockers, isEmpty);
      expect(c.missingDomains, isEmpty);
    });

    test('本人支援・家族支援・移行支援はそれぞれ 1 行以上要る。中身の無い行は数えない', () {
      final p = full().copyWith(rows: [
        row(['self']),
        row(['family'], goal: ''),
        row(['community']),
      ]);
      final b = PlanCheck.of(p).blockers;
      expect(b.where((e) => e.contains('「家族支援」')), hasLength(1));
      expect(b.where((e) => e.contains('「移行支援」')), hasLength(1));
      expect(b.where((e) => e.contains('「本人支援」')), isEmpty);
      expect(b.where((e) => e.contains('地域支援')), isEmpty); // 任意
    });

    test('作成年月日と児童発達支援管理責任者が無いと足りない', () {
      final p = full().copyWith(createdOn: () => null, managerName: '');
      final b = PlanCheck.of(p).blockers;
      expect(b, contains('作成年月日が入っていません'));
      expect(b, contains('児童発達支援管理責任者氏名が選ばれていません'));
    });

    test('作成年月日 ≦ 説明した日 ≦ 同意を得た日（同じ日は可）。同意には説明した日が要る', () {
      final d = DateTime(2026, 5, 1);
      expect(
          PlanCheck.of(full().copyWith(explainedOn: () => d, agreedOn: () => d))
              .blockers,
          isEmpty);
      expect(
          PlanCheck.of(
                  full().copyWith(explainedOn: () => DateTime(2026, 4, 30)))
              .blockers
              .single,
          contains('説明した日（2026/4/30）が作成年月日（2026/5/1）より前です'));
      expect(
          PlanCheck.of(full().copyWith(
              explainedOn: () => DateTime(2026, 5, 3),
              agreedOn: () => DateTime(2026, 5, 2))).blockers.single,
          contains('同意を得た日（2026/5/2）が説明した日（2026/5/3）より前です'));
      expect(
          PlanCheck.of(full().copyWith(agreedOn: () => DateTime(2026, 5, 2)))
              .blockers,
          ['説明した日が入っていません']);
    });

    test('5 領域は本人支援の行だけで数え、選ばれていない領域を名前で返す（止めない）', () {
      final p = full().copyWith(rows: [
        row(['self'], domains: ['health']),
        row(['family'], domains: ['motor']), // 本人支援ではない行の領域は数えない
        row(['transition']),
      ]);
      final c = PlanCheck.of(p);
      expect(c.canAgree, isTrue);
      expect(c.missingDomains, ['運動・感覚', '認知・行動', '言語・コミュニケーション', '人間関係・社会性']);
    });
  });

  group('更新期限の計算（作成年月日の6か月後の同じ日。無い日は月末）', () {
    DateTime due(int y, int m, int d) =>
        SupportPlanPolicy.dueOf(DateTime(y, m, d));
    test('境目の日', () {
      expect(due(2026, 5, 1), DateTime(2026, 11, 1));
      expect(due(2026, 8, 31), DateTime(2027, 2, 28));
      expect(due(2027, 8, 31), DateTime(2028, 2, 29)); // うるう年
      expect(due(2026, 3, 31), DateTime(2026, 9, 30));
      expect(due(2026, 12, 31), DateTime(2027, 6, 30));
      expect(due(2026, 7, 31), DateTime(2027, 1, 31));
      expect(due(2026, 8, 30), DateTime(2027, 2, 28));
      expect(due(2026, 1, 29), DateTime(2026, 7, 29));
    });

    test('起点は、同意済みのうち作成年月日がいちばん新しい計画。同意済みが無ければ作成中のいちばん新しいもの', () {
      final a1 = full(id: 'a1', createdOn: DateTime(2026, 1, 10)).copyWith(
          status: PlanStatus.agreed,
          explainedOn: () => DateTime(2026, 1, 10),
          agreedOn: () => DateTime(2026, 1, 10));
      final a2 = a1.copyWith(id: 'a2', createdOn: () => DateTime(2026, 6, 1));
      final d1 = full(id: 'd1', createdOn: DateTime(2026, 9, 1));
      final noDate = full(id: 'n').copyWith(createdOn: () => null);
      expect(SupportPlanPolicy.basePlan([a1, a2, d1, noDate])!.id, 'a2');
      expect(SupportPlanPolicy.basePlan([d1, noDate])!.id, 'd1');
      expect(SupportPlanPolicy.basePlan([noDate]), isNull);
      expect(SupportPlanPolicy.basePlan([]), isNull);
    });
  });

  group('初期値', () {
    test('支援の標準的な提供時間等: 利用曜日と、週間利用計画でいちばん多い予定時刻', () {
      final c = Customer(
          id: 'c1',
          name: '架空 一郎',
          nameKana: 'カクウ イチロウ',
          regularDays: [5, 1, 3]);
      ScheduleEntry e(String s, String en, {String id = 'c1'}) => ScheduleEntry(
          customerId: id,
          customerName: 'x',
          plannedStartTime: s,
          plannedEndTime: en);
      final entries = [
        (DateTime(2026, 11, 2), e('14:30', '17:30')),
        (DateTime(2026, 11, 4), e('14:30', '17:30')),
        (DateTime(2026, 11, 6), e('10:00', '16:00')),
        (DateTime(2026, 11, 6), e('09:00', '12:00', id: '他の児童')),
      ];
      expect(SupportPlanService.standardTimeFor(c, entries),
          '月・水・金曜日　14:30〜17:30');
      expect(SupportPlanService.standardTimeFor(c, const []), '月・水・金曜日');
    });

    test('前回の内容を写した計画: 内容は写し、日付・説明・同意・アセスメントは空にする', () {
      final prev = full().copyWith(
          status: PlanStatus.agreed,
          explainedOn: () => DateTime(2026, 5, 1),
          agreedOn: () => DateTime(2026, 5, 2),
          assessmentDoneOn: () => DateTime(2026, 9, 1));
      final n = prev.copyAsNew(newId: 'p2', today: DateTime(2026, 11, 26));
      expect(n.id, 'p2');
      expect(n.copiedFromPlanId, prev.id);
      expect(n.createdOn, DateTime(2026, 11, 26));
      expect(n.explainedOn, isNull);
      expect(n.agreedOn, isNull);
      expect(n.assessmentDoneOn, isNull);
      expect(n.status, PlanStatus.draft);
      expect(n.texts, prev.texts);
      expect(n.rows.length, prev.rows.length);
      expect(n.managerName, '職員 冬子');
    });
  });

  group('保存', () {
    CollectionReference<Map<String, dynamic>> col(FakeBackend b) => b.db
        .collection(FsPaths.facilities)
        .doc(b.facilityId)
        .collection(FsPaths.supportPlans);

    Future<Map<String, dynamic>> stored(FakeBackend b, String id) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return (await col(b).doc(id).get()).data()!;
    }

    test('担当者の記録つきで作る。同意を得た日が無ければ作成中、あれば同意済み', () async {
      final b = await FakeBackend.attachWithStaff();
      final svc = SupportPlanService.instance;
      await svc.save(full(), exists: false);
      var d = await stored(b, 'p1');
      expect(d['status'], 'draft');
      expect(d['updatedByStaffName'], '職員 冬子');
      expect(d.containsKey('createdAt'), isTrue);
      expect(d['createdOn'], '2026-05-01');
      expect((d['rows'] as List).length, 3);

      await svc.save(
          full().copyWith(
              explainedOn: () => DateTime(2026, 5, 1),
              agreedOn: () => DateTime(2026, 5, 2)),
          exists: true);
      d = await stored(b, 'p1');
      expect(d['status'], 'agreed');
      expect(d['agreedOn'], '2026-05-02');
      expect(svc.getById('p1')!.isAgreed, isTrue);
    });

    test('足りない点があるのに同意を得た日が入っていれば保存しない（作成中なら保存できる）', () async {
      final b = await FakeBackend.attachWithStaff();
      final svc = SupportPlanService.instance;
      final lacking = full().copyWith(rows: [
        row(['self'])
      ]);
      await expectLater(
          svc.save(
              lacking.copyWith(
                  explainedOn: () => DateTime(2026, 5, 1),
                  agreedOn: () => DateTime(2026, 5, 1)),
              exists: false),
          throwsA(isA<PlanCannotAgreeException>()));
      expect((await col(b).doc('p1').get()).exists, isFalse);
      await svc.save(lacking, exists: false);
      expect((await stored(b, 'p1'))['status'], 'draft');
    });

    test('同意済みの軽い修正: 同意済みのまま、同意後に修正した日時と担当者を残す', () async {
      final b = await FakeBackend.attachWithStaff();
      final svc = SupportPlanService.instance;
      final agreed = full().copyWith(
          explainedOn: () => DateTime(2026, 5, 1),
          agreedOn: () => DateTime(2026, 5, 2));
      await svc.save(agreed, exists: false);
      await svc.save(
          agreed.copyWith(texts: {SupportPlanForm.kIntention: '誤字を直した'}),
          exists: true,
          mode: PlanSaveMode.lightRevision,
          stamp: const AuditStamp(staffId: 's-b', staffName: '佐藤'));
      final d = await stored(b, 'p1');
      expect(d['status'], 'agreed');
      expect(d['agreedOn'], '2026-05-02');
      expect(d[SupportPlan.fRevisedAt], isNotNull);
      expect(d[SupportPlan.fRevisedById], 's-b');
      expect(d[SupportPlan.fRevisedByName], '佐藤');
      expect(svc.getById('p1')!.revisedAfterAgreement, isTrue);
    });

    test('同意済みの内容を変える: 作成中に戻し、説明した日・同意を得た日を空にする', () async {
      final b = await FakeBackend.attachWithStaff();
      final svc = SupportPlanService.instance;
      final agreed = full().copyWith(
          explainedOn: () => DateTime(2026, 5, 1),
          agreedOn: () => DateTime(2026, 5, 2));
      await svc.save(agreed, exists: false);
      await svc.save(agreed, exists: true, mode: PlanSaveMode.revertToDraft);
      final d = await stored(b, 'p1');
      expect(d['status'], 'draft');
      expect(d['agreedOn'], isNull);
      expect(d['explainedOn'], isNull);
      expect(d[SupportPlan.fRevisedAt], isNull);
    });

    test('児童ごとの履歴は新しい順。様式の一覧に無い項目の値も消さずに残る', () async {
      final b = await FakeBackend.attachWithStaff();
      final svc = SupportPlanService.instance;
      await svc.save(full(id: 'old', createdOn: DateTime(2025, 11, 1)),
          exists: false);
      await svc.save(full(id: 'new', createdOn: DateTime(2026, 5, 1)),
          exists: false);
      expect(svc.plansOf('c1').map((p) => p.id), ['new', 'old']);
      // 他の地域の様式で足した項目（例）
      await col(b).doc('x').set({
        'customerId': 'c1',
        'createdOn': '2024-01-01',
        'texts': {'otherField': '残す値'},
        'rows': [
          {
            'categories': ['self'],
            'texts': {'goal': '目標', 'extraCol': '残す列'}
          }
        ],
        'status': 'draft',
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final x = svc.getById('x')!;
      expect(x.texts['otherField'], '残す値');
      expect(x.rows.single.texts['extraCol'], '残す列');
      expect(x.toFirestoreData()['texts'], {'otherField': '残す値'});
    });
  });
}
