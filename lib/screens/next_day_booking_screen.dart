import 'dart:async';

// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/day_ticker.dart';
import '../data/staff_session.dart';
import '../models/customer.dart';
import '../models/weekly_schedule.dart';
import '../services/customer_service.dart';
import '../services/day_confirmation_service.dart';
import '../services/monthly_usage_service.dart';
import '../services/next_day_service.dart';
import '../services/settings_service.dart';
import '../services/transport_plan_service.dart';
import '../services/weekly_schedule_service.dart';
import '../theme/app_theme.dart';
import '../utils/week_util.dart';
import 'attendance_screen.dart';

/// 翌日予約選択（ステップ4）。前日に、明日の利用を見直す画面。
///
/// 新しい予定は作らない。表示も変更も、週間利用計画のその日の予定（scheduleEntries）を
/// そのまま使う（週間利用計画の画面と同じデータの別の見せ方）。
/// - 利用する／お休み: 押した時点で保存。お休みは予定をキャンセルにする（消さない）
/// - 時間の変更: カードを押して、その日の予定の時間だけを直す
/// - 児童を追加: その日に予定の無い在籍中の児童を「追加」の予定として足す
/// - 過去の日と今日は表示だけ（今日の分は出席管理で扱う）
class NextDayBookingScreen extends StatefulWidget {
  const NextDayBookingScreen({super.key, this.initialDate});

  /// 開く日（テスト用。省略時は明日から予定のある最初の日）
  final DateTime? initialDate;

  /// 一覧の列の数（顧客管理と同じ）
  static int columnCount(double width) {
    if (width >= 1280) return 4;
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }

  /// 1 件の高さ（顧客管理と同じ詰め方。1 列: 横並び、複数列: 縦並び）
  static double cardExtent(int cols) => cols == 1 ? 84 : 128;

  @override
  State<NextDayBookingScreen> createState() => _NextDayBookingScreenState();
}

class _NextDayBookingScreenState extends State<NextDayBookingScreen> {
  DateTime? _date;
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};

  WeeklyScheduleService get _w => WeeklyScheduleService.instance;
  DateTime get _today => DayTicker.instance.today;

  @override
  void initState() {
    super.initState();
    DayTicker.instance.ensureStarted();
    for (final l in _listenables) {
      l.addListener(_onChanged);
    }
    _start();
  }

  List<Listenable> get _listenables => [
        _w,
        CustomerService.instance,
        SettingsService.instance,
        TransportPlanService.instance,
        DayConfirmationService.instance,
        DayTicker.instance,
      ];

  @override
  void dispose() {
    for (final l in _listenables) {
      l.removeListener(_onChanged);
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    final init = widget.initialDate;
    if (init != null) {
      await _open(DateTime(init.year, init.month, init.day));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await NextDayService.findTargetDate(_today);
      await _open(d);
    } on WeekUnavailableException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Future<void> _open(DateTime d) async {
    setState(() {
      _date = d;
      _loading = true;
      _error = null;
    });
    try {
      // 予定は週間利用計画と同じ: その週がまだ無ければ、同じ処理で作る（今日より後の日だけ）
      await _w.ensureRange(d, d);
      if (!_w.hasWeekFor(d) && d.isAfter(_today)) {
        await _w.getOrCreateSchedule(WeekUtil.weekStartFromDate(d),
            CustomerService.instance.getAllCustomers());
      }
      unawaited(TransportPlanService.instance.ensureDate(_key(d)));
      await DayConfirmationService.instance.ensure(d);
    } on WeekUnavailableException catch (e) {
      if (!mounted || _date != d) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
      return;
    }
    if (!mounted || _date != d) return;
    setState(() => _loading = false);
  }

  static String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const _weekdays = ['月', '火', '水', '木', '金', '土', '日'];

  /// ダイアログのボタンも押す場所は高さ 48 以上
  static final ButtonStyle _dialogButton =
      ButtonStyle(minimumSize: WidgetStateProperty.all(const Size(64, 48)));

  bool get _editable => _date != null && _date!.isAfter(_today);

  void _snack(String m, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating));
  }

  Future<void> _guard(String id, Future<void> Function() f) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await f();
    } on StaffNotSelectedException {
      _snack('担当者を選ぶと保存できます');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _setUse(Customer c, bool use) =>
      _guard('use_${c.id}', () => _w.setUse(_date!, c, use: use));

  // ── 時間の変更 ─────────────────────────────────────────────

  static TimeOfDay? _parse(String? s) {
    if (s == null) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
    if (m == null) return null;
    return TimeOfDay(hour: int.parse(m[1]!), minute: int.parse(m[2]!));
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _editTime(Customer? c, ScheduleEntry e) async {
    if (!_editable) return;
    var start = e.plannedStartTime;
    var end = e.plannedEndTime;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          Future<void> pick(bool isStart) async {
            final t = await showTimePicker(
              context: ctx,
              initialTime: _parse(isStart ? start : end) ??
                  (isStart
                      ? const TimeOfDay(hour: 14, minute: 0)
                      : const TimeOfDay(hour: 17, minute: 0)),
              helpText: isStart ? '開始の時刻' : '終了の時刻',
              confirmText: '決定',
              cancelText: 'キャンセル',
            );
            if (t != null) set(() => isStart ? start = _fmt(t) : end = _fmt(t));
          }

          return AlertDialog(
            title: Text('${e.customerName}さんの時間'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${_dateLabel(_date!)}の予定だけを直します。',
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.onSurfaceVariant)),
                const SizedBox(height: 12),
                for (final (isStart, label, v) in [
                  (true, '開始', start),
                  (false, '終了', end),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        key: Key('nextDayTime_${isStart ? 'start' : 'end'}'),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 48)),
                        onPressed: () => pick(isStart),
                        icon: const Icon(Icons.schedule),
                        label: Text('$label　${v ?? '未定'}'),
                      ),
                    ),
                  ),
                if (start != null || end != null)
                  TextButton(
                    style: _dialogButton,
                    onPressed: () => set(() {
                      start = null;
                      end = null;
                    }),
                    child: const Text('時間を空にする'),
                  ),
              ],
            ),
            actions: [
              TextButton(
                  style: _dialogButton,
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('やめる')),
              ElevatedButton(
                  style: _dialogButton,
                  key: const Key('nextDayTimeSave'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存')),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    await _guard(
        'time_${e.customerId}',
        () => _w.updateEntryTimes(WeekUtil.weekKeyFromDate(_date!),
            _date!.weekday, e.customerId, start, end));
  }

  // ── 児童を追加 ─────────────────────────────────────────────

  Future<void> _addChild() async {
    final date = _date!;
    final existing = {
      for (final e in _w.getAllEntriesForDate(date)) e.customerId
    };
    final candidates = CustomerService.instance
        .getAllCustomers()
        .where((c) => c.isActive && !existing.contains(c.id))
        .toList()
      ..sort((a, b) => a.nameKana.compareTo(b.nameKana));
    if (candidates.isEmpty) {
      _snack('この日に予定の無い在籍中の児童はいません');
      return;
    }
    final picked = await showDialog<Customer>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${_dateLabel(date)}に追加する児童'),
        content: SizedBox(
          width: 420,
          height: 420,
          child: ListView(
            children: [
              for (final c in candidates)
                ListTile(
                  key: Key('nextDayAddPick_${c.id}'),
                  minTileHeight: 48,
                  title: Text(c.name),
                  subtitle: Text(c.regularDays.isEmpty
                      ? '利用曜日なし'
                      : '利用曜日 ${c.regularDays.map((d) => _weekdays[d - 1]).join('・')}'),
                  onTap: () => Navigator.pop(ctx, c),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              style: _dialogButton,
              onPressed: () => Navigator.pop(ctx),
              child: const Text('やめる')),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    // 月の利用可能日数を超える見込みなら、顧客管理の超過見込みと同じ考え方で知らせる
    final usage = await MonthlyUsageService.instance.getUsage(
        picked.id, DateTime(date.year, date.month),
        today: _today, reconcileCache: false);
    if (!mounted) return;
    final after = usage.projectedTotal + 1;
    if (after > usage.available) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('今月の支給日数を超過する見込みです'),
          content: Text('${picked.name}さんを追加すると、'
              '支給量 ${usage.available}日 / 見込み $after日'
              '（超過 ${after - usage.available}日）になります。\n'
              '超過分は利用者負担となる可能性があります。追加しますか。'),
          actions: [
            TextButton(
                style: _dialogButton,
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('やめる')),
            ElevatedButton(
                style: _dialogButton,
                key: const Key('nextDayAddOverOk'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('追加する')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _guard('add_${picked.id}', () => _w.addExtra(date, picked));
  }

  // ── 表示 ────────────────────────────────────────────────────

  static String _dateLabel(DateTime d) =>
      '${d.month}月${d.day}日（${_weekdays[d.weekday - 1]}）';

  @override
  Widget build(BuildContext context) {
    final d = _date;
    return Scaffold(
      appBar: AppBar(title: const Text('翌日予約選択')),
      body: d == null
          ? Center(
              child: _error != null
                  ? _errorView()
                  : const CircularProgressIndicator())
          : Column(
              children: [
                _dateBar(d),
                if (!_editable) _readOnlyNote(d),
                if (_error != null)
                  Expanded(child: Center(child: _errorView()))
                else if (_loading)
                  const Expanded(
                      child: Center(child: CircularProgressIndicator()))
                else ...[
                  _countsBar(d),
                  Expanded(child: _list(d)),
                ],
              ],
            ),
      bottomNavigationBar:
          d != null && !_loading && _error == null ? _confirmBar(d) : null,
    );
  }

  /// 確認した（印を残すだけ。予定は固定しない。確認の後も直せて、直すと「確認後に変更あり」）
  Widget _confirmBar(DateTime d) {
    final conf = DayConfirmationService.instance.get(d);
    final counts = NextDayCounts.of(_w.getAllEntriesForDate(d),
        SettingsService.instance.getSettings().maxStudentsPerDay);
    final changed = conf != null &&
        DayConfirmationService.changedAfter(conf, d, counts.using);
    final at = conf?.confirmedAt;
    String hm(DateTime t) =>
        '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final status = conf == null
        ? 'まだ確認していません'
        : '確認済み：${conf.confirmedByStaffName}${at == null ? '' : '（${hm(at)}）'}'
            '・確認したとき 利用 ${conf.usingCount}人／お休み ${conf.absentCount}人';
    return Material(
      key: const Key('nextDayConfirmBar'),
      elevation: 8,
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(status,
                  key: const Key('nextDayConfirmStatus'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      color: conf == null
                          ? AppColors.warning
                          : AppColors.onSurfaceVariant)),
              if (changed)
                const Text('確認後に変更あり',
                    key: Key('nextDayChangedAfter'),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.warning)),
              if (_editable) ...[
                const SizedBox(height: 6),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    key: const Key('nextDayConfirm'),
                    onPressed: _busy.contains('confirm')
                        ? null
                        : () => _guard(
                            'confirm',
                            () => DayConfirmationService.instance
                                .confirm(d, counts)),
                    icon: const Icon(Icons.task_alt),
                    label: Text(
                        conf == null || changed ? 'この内容で確認した' : 'もう一度確認する'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorView() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? '', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                key: const Key('nextDayRetry'),
                onPressed: () => _date == null ? _start() : _open(_date!),
                child: const Text('再試行'),
              ),
            ),
          ],
        ),
      );

  Widget _dateBar(DateTime d) {
    final isTomorrow = d == DateTime(_today.year, _today.month, _today.day + 1);
    return Material(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              key: const Key('nextDayPrev'),
              tooltip: '前の日',
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _open(DateTime(d.year, d.month, d.day - 1)),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    '${d.year}年${_dateLabel(d)}',
                    key: const Key('nextDayDate'),
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    d == _today
                        ? '今日'
                        : isTomorrow
                            ? '明日'
                            : d.isBefore(_today)
                                ? '過ぎた日'
                                : '${d.difference(_today).inDays}日後',
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('nextDayNext'),
              tooltip: '次の日',
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _open(DateTime(d.year, d.month, d.day + 1)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readOnlyNote(DateTime d) {
    final isToday = d == _today;
    return Container(
      key: const Key('nextDayReadOnly'),
      width: double.infinity,
      color: AppColors.primary.withValues(alpha: 0.08),
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              isToday ? '今日の分は出席管理で扱います（この画面では直せません）' : '過ぎた日は表示だけです',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (isToday)
            TextButton(
              key: const Key('nextDayOpenAttendance'),
              style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(builder: (_) => const AttendanceScreen()),
              ),
              child: const Text('出席管理を開く'),
            ),
        ],
      ),
    );
  }

  Widget _countsBar(DateTime d) {
    final c = NextDayCounts.of(_w.getAllEntriesForDate(d),
        SettingsService.instance.getSettings().maxStudentsPerDay);
    Widget item(String label, String value, {Color? color, Key? key}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.onSurfaceVariant)),
              Text(value,
                  key: key,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: color ?? AppColors.onSurface)),
            ],
          ),
        );
    return Container(
      key: const Key('nextDayCounts'),
      width: double.infinity,
      color: c.over > 0 ? AppColors.error.withValues(alpha: 0.08) : null,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          item('利用する', '${c.using}人', key: const Key('nextDayUsing')),
          item('お休み', '${c.absent}人', key: const Key('nextDayAbsent')),
          item('定員', '${c.capacity}人'),
          c.over > 0
              ? item('定員超過', '${c.over}人超えています',
                  color: AppColors.error, key: const Key('nextDayOver'))
              : item('空き', '${c.free}人', key: const Key('nextDayFree')),
          // 浮かせたボタンにすると右下の児童のボタンに重なるため、人数の帯に置く
          if (_editable)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  key: const Key('nextDayAdd'),
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _addChild,
                  icon: const Icon(Icons.person_add),
                  label: const Text('児童を追加'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _list(DateTime d) {
    final entries = _w.getAllEntriesForDate(d);
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _editable ? 'この日の予定はありません。\n上の「児童を追加」から追加できます。' : 'この日の予定はありません。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final customers = {
      for (final c
          in CustomerService.instance.getAllCustomers(includeInactive: true))
        c.id: c
    };
    final routes = TransportPlanService.instance.getRoutesByDate(_key(d));
    // 利用する人が先、その中は名前の順
    final sorted = [...entries]..sort((a, b) {
        final ca = a.status == ScheduleStatus.cancelled ? 1 : 0;
        final cb = b.status == ScheduleStatus.cancelled ? 1 : 0;
        if (ca != cb) return ca.compareTo(cb);
        final ka = customers[a.customerId]?.nameKana ?? a.customerName;
        final kb = customers[b.customerId]?.nameKana ?? b.customerName;
        return ka.compareTo(kb);
      });
    return LayoutBuilder(builder: (context, box) {
      final cols = NextDayBookingScreen.columnCount(box.maxWidth);
      return GridView.builder(
        key: const Key('nextDayList'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          mainAxisExtent: NextDayBookingScreen.cardExtent(cols),
        ),
        itemCount: sorted.length,
        itemBuilder: (context, i) {
          final e = sorted[i];
          final c = customers[e.customerId];
          return _EntryCard(
            entry: e,
            customer: c,
            horizontal: cols == 1,
            editable: _editable && c != null,
            busy: _busy.contains('use_${e.customerId}'),
            routeText: NextDayTransport.routeText(e.customerId, routes),
            onUse: c == null ? null : () => _setUse(c, true),
            onAbsent: c == null ? null : () => _setUse(c, false),
            onTap: () => _editTime(c, e),
          );
        },
      );
    });
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.customer,
    required this.horizontal,
    required this.editable,
    required this.busy,
    required this.routeText,
    required this.onUse,
    required this.onAbsent,
    required this.onTap,
  });

  final ScheduleEntry entry;
  final Customer? customer;
  final bool horizontal;
  final bool editable;
  final bool busy;
  final String? routeText;
  final VoidCallback? onUse;
  final VoidCallback? onAbsent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final absent = e.status == ScheduleStatus.cancelled;
    final time = (e.plannedStartTime == null && e.plannedEndTime == null)
        ? '時間未定'
        : '${e.plannedStartTime ?? '--:--'}〜${e.plannedEndTime ?? '--:--'}';
    final kind = switch (e.status) {
      ScheduleStatus.planned => '通常',
      ScheduleStatus.additional => '追加',
      ScheduleStatus.cancelled => 'お休み',
    };
    final transport = [
      NextDayTransport.placeText(customer, e),
      if (routeText != null) routeText!,
    ].join('　');
    final warnRoute = absent && routeText != null;
    final fg = absent ? AppColors.onSurfaceVariant : AppColors.onSurface;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(e.customerName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: fg)),
        Text('$time　$kind',
            key: Key('nextDayTimeText_${e.customerId}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: fg)),
        Text(
          warnRoute ? '送迎計画に入っています（送迎計画で外してください）' : transport,
          key: Key('nextDayTransport_${e.customerId}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 12,
              color: warnRoute ? AppColors.error : AppColors.onSurfaceVariant),
        ),
      ],
    );

    Widget toggle(
        String label, bool selected, VoidCallback? onPressed, Key key) {
      final color = label == 'お休み' ? AppColors.error : AppColors.secondary;
      return SizedBox(
        height: 48,
        child: selected
            ? ElevatedButton(
                key: key,
                onPressed: editable && !busy ? () {} : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: color,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: color.withValues(alpha: 0.5),
                  disabledForegroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(label),
              )
            : OutlinedButton(
                key: key,
                onPressed: editable && !busy ? onPressed : null,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(label),
              ),
      );
    }

    final use =
        toggle('利用する', !absent, onUse, Key('nextDayUse_${e.customerId}'));
    final off =
        toggle('お休み', absent, onAbsent, Key('nextDayAbsent_${e.customerId}'));
    final buttons = horizontal
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 84, child: use),
            const SizedBox(width: 6),
            SizedBox(width: 76, child: off),
          ])
        : Row(children: [
            Expanded(child: use),
            const SizedBox(width: 6),
            Expanded(child: off),
          ]);

    return Card(
      key: Key('nextDayCard_${e.customerId}'),
      color: absent ? const Color(0xFFF5F5F5) : null,
      child: InkWell(
        onTap: editable ? onTap : null,
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
          child: horizontal
              ? Row(children: [
                  Expanded(child: info),
                  const SizedBox(width: 8),
                  buttons,
                ])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    info,
                    const Spacer(),
                    buttons,
                  ],
                ),
        ),
      ),
    );
  }
}
