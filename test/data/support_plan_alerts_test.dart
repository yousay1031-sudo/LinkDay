import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/support_plan.dart';
import 'package:linkday_app/models/support_plan_alerts.dart';
import 'package:linkday_app/models/support_plan_policy.dart';

/// ステップ3 段階5: 個別支援計画の更新時期の知らせ（4 種類・出る時期と消える条件）
void main() {
  Customer c(String id, {bool active = true}) =>
      Customer(id: id, name: '架空 $id', nameKana: 'カクウ $id', isActive: active);

  SupportPlan p(String id, String cid, DateTime created,
          {bool agreed = true, DateTime? assessed, DateTime? createdAt}) =>
      SupportPlan(
        id: id,
        customerId: cid,
        customerName: '架空 $cid',
        createdOn: created,
        managerName: '山田',
        status: agreed ? PlanStatus.agreed : PlanStatus.draft,
        explainedOn: agreed ? created : null,
        agreedOn: agreed ? created : null,
        assessmentDoneOn: assessed,
        createdAt: createdAt,
      );

  List<PlanAlert> alerts(
          List<Customer> cs, List<SupportPlan> plans, DateTime today) =>
      PlanAlert.compute(
        activeCustomers: cs,
        plansOf: (id) => plans.where((x) => x.customerId == id).toList(),
        today: today,
      );

  PlanAlert? one(List<SupportPlan> plans, DateTime today) {
    final a = alerts([c('a')], plans, today);
    return a.isEmpty ? null : a.single;
  }

  // 作成 2026-05-01 → 期限 2026-11-01
  final created = DateTime(2026, 5, 1);
  final due = DateTime(2026, 11, 1);
  DateTime before(int days) => due.subtract(Duration(days: days));

  test('日数の値は 6 か月・45 日・14 日（1 か所に置いてある）', () {
    expect(SupportPlanPolicy.validMonths, 6);
    expect(SupportPlanPolicy.assessmentLeadDays, 45);
    expect(SupportPlanPolicy.nearDays, 14);
  });

  test('境目の日: 46 日前は無し、45 日前からアセスメント、14 日前から近づいている、当日も近づいている、翌日から過ぎている', () {
    final plans = [p('p1', 'a', created)];
    expect(one(plans, before(46)), isNull);
    final a45 = one(plans, before(45))!;
    expect(a45.kind, PlanAlertKind.assessment);
    expect(a45.message, '架空 aさん：アセスメントの時期です（更新期限 11月1日）');
    expect(one(plans, before(15))!.kind, PlanAlertKind.assessment);
    final n14 = one(plans, before(14))!;
    expect(n14.kind, PlanAlertKind.near);
    expect(n14.message, '架空 aさん：計画の更新期限が近づいています');
    expect(n14.assessmentPending, isTrue);
    expect(one(plans, due)!.kind, PlanAlertKind.near);
    final over = one(plans, due.add(const Duration(days: 1)))!;
    expect(over.kind, PlanAlertKind.overdue);
    expect(over.message, '架空 aさん：計画の更新期限を過ぎています');
    expect(over.strong, isTrue);
  });

  test('月末: 8月31日に作った計画の期限は2月28日（その日は近づいている、3月1日から過ぎている）', () {
    final plans = [p('p1', 'a', DateTime(2026, 8, 31))];
    expect(one(plans, DateTime(2027, 2, 28))!.kind, PlanAlertKind.near);
    expect(one(plans, DateTime(2027, 3, 1))!.kind, PlanAlertKind.overdue);
  });

  test('アセスメントの時期の知らせは、アセスメントを実施した日を入れるか、次の計画を作ると消える', () {
    final today = before(30);
    expect(one([p('p1', 'a', created)], today)!.kind, PlanAlertKind.assessment);
    expect(one([p('p1', 'a', created, assessed: before(31))], today), isNull);
    // 次の計画（作成中）を作った
    expect(
        one([
          p('p1', 'a', created),
          p('p2', 'a', before(31), agreed: false),
        ], today),
        isNull);
  });

  test('近づいている・過ぎている知らせは、次の計画が同意済みになるまで消えない', () {
    final today = due.add(const Duration(days: 3));
    // アセスメントを入れても、次の計画が作成中でも、まだ出る
    final draftNext = one([
      p('p1', 'a', created, assessed: before(40)),
      p('p2', 'a', before(10), agreed: false),
    ], today)!;
    expect(draftNext.kind, PlanAlertKind.overdue);
    expect(draftNext.assessmentPending, isFalse);
    // 次の計画が同意済みになった → 起点が次の計画に移り、消える
    expect(
        one([
          p('p1', 'a', created),
          p('p2', 'a', before(10)),
        ], today),
        isNull);
  });

  test('計画が 1 つもない → 「まだありません」。最初の計画を作ると消える（作成中でもよい）', () {
    final a = one(const [], DateTime(2026, 11, 26))!;
    expect(a.kind, PlanAlertKind.noPlan);
    expect(a.message, '架空 aさん：個別支援計画がまだありません');
    expect(
        one([p('p1', 'a', DateTime(2026, 11, 26), agreed: false)],
            DateTime(2026, 11, 26)),
        isNull);
  });

  test('作成中の計画しかない児童は、作成中の作成年月日を仮の起点にする（判断点2 (ア)）', () {
    final plans = [p('d1', 'a', created, agreed: false)];
    expect(one(plans, before(20))!.kind, PlanAlertKind.assessment);
    expect(one(plans, due.add(const Duration(days: 1)))!.kind,
        PlanAlertKind.overdue);
  });

  test('在籍終了の児童は出さない。並びは 計画なし → 期限の近い順', () {
    final today = DateTime(2026, 10, 25);
    final list = alerts([
      c('near'),
      c('none'),
      c('over'),
      c('gone', active: false),
      c('ok'),
    ], [
      p('1', 'near', DateTime(2026, 5, 1)), // 期限 11/1（あと 7 日）
      p('2', 'over', DateTime(2026, 4, 1)), // 期限 10/1（過ぎた）
      p('3', 'ok', DateTime(2026, 9, 1)), // 期限 3/1（知らせなし）
    ], today);
    expect(list.map((a) => a.customer.id), ['none', 'over', 'near']);
  });
}
