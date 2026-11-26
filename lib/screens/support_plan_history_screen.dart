// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../models/customer.dart';
import '../models/staff.dart';
import '../models/support_plan.dart';
import '../models/support_plan_form.dart';
import '../models/support_plan_policy.dart';
import '../models/weekly_schedule.dart';
import '../services/customer_service.dart';
import '../services/settings_service.dart';
import '../services/staff_service.dart';
import '../services/support_plan_service.dart';
import '../services/weekly_schedule_service.dart';
import '../theme/app_theme.dart';
import 'support_plan_edit_screen.dart';

/// 児童ごとの個別支援計画の履歴（ステップ3）。
///
/// 新しい順に並べる。計画は削除できない。新しい計画は「前回の内容を写して作る」と
/// 「空から作る」を選べる（前回が無ければ空から）。
class SupportPlanHistoryScreen extends StatelessWidget {
  const SupportPlanHistoryScreen(
      {super.key, required this.customerId, this.today});

  final String customerId;

  /// テスト用: 今日を差し替える
  final DateTime? today;

  DateTime get _today {
    final n = today ?? DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// 空の新しい計画（顧客の情報・提供時間・児発管・提供機関を初期値に入れる）
  static SupportPlan blankPlan(Customer c, DateTime today) {
    final svc = SupportPlanService.instance;
    final mgr = defaultManager();
    final entries = <(DateTime, ScheduleEntry)>[];
    for (var i = 0; i < 28; i++) {
      final d = today.subtract(Duration(days: i));
      for (final e in WeeklyScheduleService.instance.getEntriesForDate(d)) {
        entries.add((d, e));
      }
    }
    return SupportPlan(
      id: svc.newId(),
      customerId: c.id,
      customerName: c.name,
      birthday: c.birthday,
      createdOn: today,
      managerStaffId: mgr?.id,
      managerName: mgr?.name ?? '',
      texts: {
        SupportPlanForm.kStandardTime:
            SupportPlanService.standardTimeFor(c, entries),
      },
    );
  }

  /// 児童発達支援管理責任者の役割の職員（在籍中のうち最初の人）
  static Staff? defaultManager() {
    for (final s in StaffService.instance.getActiveStaff()) {
      if (s.role == StaffRole.childDevManager) return s;
    }
    return null;
  }

  /// 提供機関の初期値（事業所名）
  static String defaultProvider() =>
      SettingsService.instance.getSettings().facilityName.trim();

  Future<void> _newPlan(BuildContext context, Customer c) async {
    final plans = SupportPlanService.instance.plansOf(c.id);
    SupportPlan plan;
    if (plans.isEmpty) {
      plan = blankPlan(c, _today);
    } else {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('新しい計画を作る'),
          content: const Text('前回の計画の内容を写して作るか、空から作るかを選んでください。'
              '写した場合も、作成年月日・説明した日・同意を得た日は新しく入れます。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('やめる')),
            TextButton(
                key: const Key('planNewBlank'),
                onPressed: () => Navigator.pop(ctx, 'blank'),
                child: const Text('空から作る')),
            ElevatedButton(
                key: const Key('planNewCopy'),
                onPressed: () => Navigator.pop(ctx, 'copy'),
                child: const Text('前回の内容を写して作る')),
          ],
        ),
      );
      if (choice == null) return;
      final prev = plans.first;
      plan = choice == 'copy'
          ? prev
              .copyAsNew(
                  newId: SupportPlanService.instance.newId(), today: _today)
              .copyWith(customerName: c.name, birthday: () => c.birthday)
          : blankPlan(c, _today);
    }
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
          builder: (_) => SupportPlanEditScreen(plan: plan, isNew: true)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [SupportPlanService.instance, CustomerService.instance]),
      builder: (context, _) {
        final c = CustomerService.instance.getCustomerById(customerId);
        final plans = SupportPlanService.instance.plansOf(customerId);
        final base = SupportPlanPolicy.basePlan(plans);
        return Scaffold(
          appBar:
              AppBar(title: Text(c == null ? '個別支援計画' : '${c.name}さんの個別支援計画')),
          floatingActionButton: c == null
              ? null
              : FloatingActionButton.extended(
                  key: const Key('planNew'),
                  onPressed: () => _newPlan(context, c),
                  icon: const Icon(Icons.add),
                  label: const Text('新しい計画を作る'),
                ),
          body: plans.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('個別支援計画がまだありません。\n右下の「新しい計画を作る」から作れます。',
                        textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: [
                    for (final p in plans)
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 960),
                          child: _PlanCard(
                              plan: p,
                              isBase: identical(p, base) || p.id == base?.id),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.isBase});
  final SupportPlan plan;
  final bool isBase;

  static String ymd(DateTime? d) =>
      d == null ? '未入力' : '${d.year}年${d.month}月${d.day}日';

  @override
  Widget build(BuildContext context) {
    final p = plan;
    final created = p.createdOn;
    return Card(
      key: Key('planCard_${p.id}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        onTap: () => Navigator.push<void>(
          context,
          MaterialPageRoute(
              builder: (_) => SupportPlanEditScreen(plan: p, isNew: false)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('作成年月日 ${ymd(created)}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      Text(p.status.label,
                          key: Key('planCardStatus_${p.id}'),
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: p.isAgreed
                                  ? AppColors.secondary
                                  : AppColors.warning)),
                      if (p.isAgreed) Text('同意を得た日 ${ymd(p.agreedOn)}'),
                      if (p.revisedAfterAgreement)
                        Text('同意後に修正あり',
                            key: Key('planCardRevised_${p.id}'),
                            style: const TextStyle(
                                color: AppColors.onSurfaceVariant)),
                      if (created != null && isBase)
                        Text('更新期限 ${ymd(SupportPlanPolicy.dueOf(created))}',
                            style: const TextStyle(
                                color: AppColors.onSurfaceVariant)),
                    ]),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  color: AppColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
