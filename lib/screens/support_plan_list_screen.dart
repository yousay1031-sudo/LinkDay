// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/day_ticker.dart';
import '../models/customer.dart';
import '../models/support_plan.dart';
import '../models/support_plan_alerts.dart';
import '../models/support_plan_policy.dart';
import '../services/customer_service.dart';
import '../services/support_plan_service.dart';
import '../theme/app_theme.dart';
import '../utils/name_search.dart';
import 'support_plan_history_screen.dart';
import '../widgets/select_chip.dart';

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
/// 上に更新時期の知らせ（期限の近い順）。その下に在籍中の児童を、計画の状態と次の期限とともに、
/// 期限が近い順に並べる（計画がまだ無い児童はいちばん上に「計画なし」）。
/// 押すと児童ごとの履歴が開く。画面を開いたまま日付が変わっても計算し直す。
class SupportPlanListScreen extends StatefulWidget {
  const SupportPlanListScreen({super.key, this.today});

  /// テスト用: 今日を差し替える（省略時は [DayTicker] の今日）
  final DateTime? today;

  /// 知らせの種類で絞るときの選択肢（並びは画面の並び）
  static const List<(PlanAlertKind, String)> kindFilters = [
    (PlanAlertKind.overdue, '期限切れ'),
    (PlanAlertKind.near, '期限間近'),
    (PlanAlertKind.assessment, 'アセスメント'),
    (PlanAlertKind.noPlan, '未作成'),
  ];

  @override
  State<SupportPlanListScreen> createState() => _SupportPlanListScreenState();
}

class _SupportPlanListScreenState extends State<SupportPlanListScreen> {
  final _search = TextEditingController();

  /// 絞り込む知らせの種類（null = すべて）
  PlanAlertKind? _kind;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    DayTicker.instance.ensureStarted();
    return Scaffold(
      appBar: AppBar(title: const Text('個別支援計画')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          SupportPlanService.instance,
          CustomerService.instance,
          DayTicker.instance,
        ]),
        builder: (context, _) {
          final customers = CustomerService.instance.getAllCustomers();
          final all =
              PlanListEntry.build(customers, SupportPlanService.instance);
          if (all.isEmpty) {
            return const Center(child: Text('在籍中の児童がいません'));
          }
          final t = widget.today ?? DayTicker.instance.today;
          final allAlerts = PlanAlert.compute(
            activeCustomers: customers,
            plansOf: SupportPlanService.instance.plansOf,
            today: t,
          );
          final kindOf = {for (final a in allAlerts) a.customer.id: a.kind};
          bool keep(Customer c) =>
              NameSearch.matches(_search.text,
                  name: c.name, kana: c.nameKana) &&
              (_kind == null || kindOf[c.id] == _kind);
          final entries = [
            for (final e in all)
              if (keep(e.customer)) e
          ];
          final alerts = [
            for (final a in allAlerts)
              if (keep(a.customer)) a
          ];
          final filtering = _search.text.trim().isNotEmpty || _kind != null;
          return ListView.builder(
            key: const Key('planList'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: entries.length + 2,
            itemBuilder: (context, i) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: i == 0
                    ? _filterBar(kindOf)
                    : i == 1
                        ? (entries.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.all(24),
                                child: Text('該当する児童はいません',
                                    key: Key('planListNoMatch'),
                                    textAlign: TextAlign.center),
                              )
                            : filtering && alerts.isEmpty
                                ? const SizedBox.shrink()
                                : PlanAlertPanel(alerts: alerts))
                        : _EntryCard(entry: entries[i - 2], today: t),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 検索欄と、知らせの種類での絞り込み
  Widget _filterBar(Map<String, PlanAlertKind> kindOf) {
    int count(PlanAlertKind k) => kindOf.values.where((v) => v == k).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('planListSearch'),
            controller: _search,
            decoration: InputDecoration(
              hintText: '氏名・ふりがなで探す',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      key: const Key('planListSearchClear'),
                      tooltip: '検索を消す',
                      style:
                          IconButton.styleFrom(minimumSize: const Size(48, 48)),
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_search.clear),
                    ),
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _kindChip(null, 'すべて', null),
              for (final (k, label) in SupportPlanListScreen.kindFilters)
                _kindChip(k, label, count(k)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kindChip(PlanAlertKind? k, String label, int? n) {
    return SelectChip(
      key: Key('planListKind_${k?.name ?? 'all'}'),
      label: n == null ? label : '$label $n',
      selected: _kind == k,
      onSelected: (_) => setState(() => _kind = k),
    );
  }
}

/// 一覧の上に出す知らせ（期限の近い順）。押すとその児童の履歴が開く
class PlanAlertPanel extends StatelessWidget {
  const PlanAlertPanel({super.key, required this.alerts});
  final List<PlanAlert> alerts;

  static String _ymd(DateTime d) => '${d.year}/${d.month}/${d.day}';

  @override
  Widget build(BuildContext context) {
    if (alerts.isEmpty) {
      return const Padding(
        key: Key('planAlertsNone'),
        padding: EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Text('更新時期の知らせはありません',
            style: TextStyle(color: AppColors.onSurfaceVariant)),
      );
    }
    return Card(
      key: const Key('planAlerts'),
      color: AppColors.warning.withValues(alpha: 0.08),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('知らせ（${alerts.length}件）',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            for (final a in alerts) _alertRow(context, a),
          ],
        ),
      ),
    );
  }

  Widget _alertRow(BuildContext context, PlanAlert a) {
    final due = a.due;
    final sub =
        (a.kind == PlanAlertKind.near || a.kind == PlanAlertKind.overdue) &&
                due != null
            ? '更新期限 ${_ymd(due)}${a.assessmentPending ? '・アセスメント未実施' : ''}'
            : null;
    return InkWell(
      key: Key('planAlert_${a.customer.id}'),
      onTap: () => Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                SupportPlanHistoryScreen(customerId: a.customer.id)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(
                a.strong
                    ? Icons.error
                    : a.kind == PlanAlertKind.noPlan
                        ? Icons.assignment_late_outlined
                        : Icons.schedule,
                size: 20,
                color: a.strong ? AppColors.error : AppColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.message,
                      key: Key('planAlertText_${a.customer.id}'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            a.strong ? FontWeight.w700 : FontWeight.w500,
                        color: a.strong ? AppColors.error : AppColors.onSurface,
                      ),
                    ),
                    if (sub != null)
                      Text(sub,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.onSurfaceVariant)),
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
