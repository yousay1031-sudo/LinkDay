// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../models/customer.dart';
import '../models/support_plan.dart';
import '../models/support_plan_policy.dart';
import '../services/customer_service.dart';
import '../services/support_plan_service.dart';
import '../theme/app_theme.dart';
import 'support_plan_history_screen.dart';

/// 一覧の 1 行（在籍中の児童 1 人）
class PlanListEntry {
  final Customer customer;

  /// 期限の起点の計画（無ければ null）
  final SupportPlan? base;

  /// いちばん新しい計画（状態の表示用）
  final SupportPlan? latest;
  final DateTime? due;

  const PlanListEntry(this.customer, this.base, this.latest, this.due);

  /// 期限が近い順（計画がまだ無い児童がいちばん上）
  static List<PlanListEntry> build(
      List<Customer> activeCustomers, SupportPlanService svc) {
    final list = [
      for (final c in activeCustomers)
        () {
          final plans = svc.plansOf(c.id);
          final base = SupportPlanPolicy.basePlan(plans);
          final created = base?.createdOn;
          return PlanListEntry(c, base, plans.isEmpty ? null : plans.first,
              created == null ? null : SupportPlanPolicy.dueOf(created));
        }()
    ];
    list.sort((a, b) {
      final da = a.due, db = b.due;
      if (da == null && db != null) return -1;
      if (da != null && db == null) return 1;
      if (da != null && db != null && da != db) return da.compareTo(db);
      return a.customer.nameKana.compareTo(b.customer.nameKana);
    });
    return list;
  }
}

/// 個別支援計画の一覧（ステップ3）。
///
/// 在籍中の児童を、計画の状態と次の期限とともに、期限が近い順に並べる。
/// 計画がまだ無い児童はいちばん上に「計画なし」と出す。押すと児童ごとの履歴が開く。
class SupportPlanListScreen extends StatelessWidget {
  const SupportPlanListScreen({super.key, this.today});

  /// テスト用: 今日を差し替える
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('個別支援計画')),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [SupportPlanService.instance, CustomerService.instance]),
        builder: (context, _) {
          final entries = PlanListEntry.build(
              CustomerService.instance.getAllCustomers(),
              SupportPlanService.instance);
          if (entries.isEmpty) {
            return const Center(child: Text('在籍中の児童がいません'));
          }
          final now = today ?? DateTime.now();
          final t = DateTime(now.year, now.month, now.day);
          return ListView.builder(
            key: const Key('planList'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: entries.length,
            itemBuilder: (context, i) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: _EntryCard(entry: entries[i], today: t),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry, required this.today});
  final PlanListEntry entry;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final latest = e.latest;
    final due = e.due;
    final days = due?.difference(today).inDays;
    final overdue = days != null && days < 0;
    final (statusText, statusColor) = latest == null
        ? ('計画なし', AppColors.error)
        : latest.isAgreed
            ? ('同意済み', AppColors.secondary)
            : ('作成中', AppColors.warning);
    return Card(
      key: Key('planEntry_${e.customer.id}'),
      child: InkWell(
        onTap: () => Navigator.push<void>(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  SupportPlanHistoryScreen(customerId: e.customer.id)),
        ),
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.customer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _Tag(statusText, statusColor,
                              key: Key('planStatus_${e.customer.id}')),
                          if (latest != null && latest.revisedAfterAgreement)
                            const _Tag('同意後に修正あり', AppColors.onSurfaceVariant),
                          if (e.base != null &&
                              !e.base!.isAgreed &&
                              latest != null)
                            const Text('（作成中の計画の作成年月日で期限を出しています）',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.onSurfaceVariant)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('次の期限',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.onSurfaceVariant)),
                    Text(
                      due == null ? '—' : '${due.year}/${due.month}/${due.day}',
                      key: Key('planDue_${e.customer.id}'),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: overdue ? AppColors.error : AppColors.onSurface,
                      ),
                    ),
                    if (days != null)
                      Text(
                        overdue ? '${-days}日過ぎています' : 'あと$days日',
                        style: TextStyle(
                            fontSize: 11,
                            color: overdue
                                ? AppColors.error
                                : AppColors.onSurfaceVariant),
                      ),
                  ],
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right,
                    color: AppColors.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, this.color, {super.key});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
      );
}
