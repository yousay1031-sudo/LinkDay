import 'customer.dart';
import 'support_plan.dart';
import 'support_plan_policy.dart';

/// 個別支援計画の知らせの種類
enum PlanAlertKind {
  /// 計画が 1 つもない
  noPlan,

  /// 更新期限を過ぎた（強い色）
  overdue,

  /// 更新期限の 14 日前から
  near,

  /// 更新期限の 45 日前から（アセスメントの時期）
  assessment,
}

/// ホームに出す知らせ 1 件（児童 1 人につき、いちばん急ぐもの 1 件）
class PlanAlert {
  final Customer customer;
  final PlanAlertKind kind;

  /// 更新期限（計画が無ければ null）
  final DateTime? due;

  /// 期限の起点の計画（計画が無ければ null）
  final SupportPlan? base;

  /// 期限が近い・過ぎた知らせで、アセスメントもまだのとき true（一覧に添える）
  final bool assessmentPending;

  const PlanAlert({
    required this.customer,
    required this.kind,
    this.due,
    this.base,
    this.assessmentPending = false,
  });

  /// 知らせの文（指示書の文言のまま）
  String get message => switch (kind) {
        PlanAlertKind.noPlan => '${customer.name}さん：個別支援計画がまだありません',
        PlanAlertKind.overdue => '${customer.name}さん：計画の更新期限を過ぎています',
        PlanAlertKind.near => '${customer.name}さん：計画の更新期限が近づいています',
        PlanAlertKind.assessment =>
          '${customer.name}さん：アセスメントの時期です（更新期限 ${due!.month}月${due!.day}日）',
      };

  bool get strong => kind == PlanAlertKind.overdue;

  /// 在籍中の児童の知らせを作る（[today] の日付で計算する）。
  ///
  /// - 計画が 1 つもない → noPlan（最初の計画を作ると消える。作成中でもよい）
  /// - 期限の起点は [SupportPlanPolicy.basePlan]（同意済みのいちばん新しい計画。
  ///   無ければ作成中のいちばん新しい計画を仮の起点にする）
  /// - 期限を過ぎた → overdue、14 日前から → near（次の計画が同意済みになると、起点が
  ///   次の計画に移るので消える）
  /// - 45 日前から → assessment（起点の計画にアセスメントを実施した日を入れるか、
  ///   次の計画を作ると消える）
  ///
  /// 並び: 計画なし → 期限の近い順（過ぎたものが先）。
  static List<PlanAlert> compute({
    required Iterable<Customer> activeCustomers,
    required List<SupportPlan> Function(String customerId) plansOf,
    required DateTime today,
  }) {
    final t = DateTime(today.year, today.month, today.day);
    final out = <PlanAlert>[];
    for (final c in activeCustomers) {
      if (!c.isActive) continue;
      final plans = plansOf(c.id);
      if (plans.isEmpty) {
        out.add(PlanAlert(customer: c, kind: PlanAlertKind.noPlan));
        continue;
      }
      final base = SupportPlanPolicy.basePlan(plans);
      final created = base?.createdOn;
      if (base == null || created == null) continue;
      final due = SupportPlanPolicy.dueOf(created);
      final daysLeft = due.difference(t).inDays;
      // 起点より後に作った計画（次の計画）があるか
      final hasNext = plans.any((p) =>
          p.id != base.id &&
          (p.createdOn == null ||
              p.createdOn!.isAfter(created) ||
              (p.createdOn == created &&
                  p.createdAt != null &&
                  base.createdAt != null &&
                  p.createdAt!.isAfter(base.createdAt!))));
      final assessmentPending = base.assessmentDoneOn == null && !hasNext;
      PlanAlertKind? kind;
      if (daysLeft < 0) {
        kind = PlanAlertKind.overdue;
      } else if (daysLeft <= SupportPlanPolicy.nearDays) {
        kind = PlanAlertKind.near;
      } else if (daysLeft <= SupportPlanPolicy.assessmentLeadDays &&
          assessmentPending) {
        kind = PlanAlertKind.assessment;
      }
      if (kind == null) continue;
      out.add(PlanAlert(
        customer: c,
        kind: kind,
        due: due,
        base: base,
        assessmentPending:
            kind != PlanAlertKind.assessment && assessmentPending,
      ));
    }
    out.sort((a, b) {
      final da = a.due, db = b.due;
      if (da == null && db != null) return -1;
      if (da != null && db == null) return 1;
      if (da != null && db != null && da != db) return da.compareTo(db);
      return a.customer.nameKana.compareTo(b.customer.nameKana);
    });
    return out;
  }
}
