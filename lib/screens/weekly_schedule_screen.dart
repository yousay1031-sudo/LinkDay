import 'package:flutter/material.dart';

import '../models/customer.dart';
import '../verify/verify_config.dart';
import '../verify/verify_faults.dart';
import '../models/weekly_schedule.dart';
import '../services/customer_service.dart';
import '../services/weekly_schedule_pdf_service.dart';
import '../data/staff_session.dart';
import '../services/weekly_schedule_service.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../widgets/motion/app_buttons.dart';
import '../widgets/motion/skeleton_gate.dart';
import '../widgets/motion/success_feedback.dart';
import '../widgets/skeletons/screen_skeletons.dart';
import '../utils/load_sequencer.dart';
import '../utils/week_util.dart';

// ── ブレークポイント定数 ──────────────────────────────────────────
const double _kTableBreakpoint = 768.0;
const double _kWideBreakpoint = 1100.0;

// ── ステータスカラー ─────────────────────────────────────────────
class _ScheduleColors {
  static const planned = Color(0xFF388E3C); // 緑
  static const additional = Color(0xFF1565C0); // 青
  static const cancelled = Color(0xFF757575); // グレー
  static const plannedBg = Color(0xFFE8F5E9);
  static const additionalBg = Color(0xFFE3F2FD);
  static const cancelledBg = Color(0xFFF5F5F5);

  static Color foreground(ScheduleStatus s) {
    switch (s) {
      case ScheduleStatus.planned:
        return planned;
      case ScheduleStatus.additional:
        return additional;
      case ScheduleStatus.cancelled:
        return cancelled;
    }
  }

  static Color background(ScheduleStatus s) {
    switch (s) {
      case ScheduleStatus.planned:
        return plannedBg;
      case ScheduleStatus.additional:
        return additionalBg;
      case ScheduleStatus.cancelled:
        return cancelledBg;
    }
  }

  static String icon(ScheduleStatus s) {
    switch (s) {
      case ScheduleStatus.planned:
        return '✓';
      case ScheduleStatus.additional:
        return '＋';
      case ScheduleStatus.cancelled:
        return '×';
    }
  }
}

// ════════════════════════════════════════════════════════════════
// WeeklyScheduleScreen
// ════════════════════════════════════════════════════════════════
class WeeklyScheduleScreen extends StatefulWidget {
  const WeeklyScheduleScreen({super.key});

  @override
  State<WeeklyScheduleScreen> createState() => _WeeklyScheduleScreenState();
}

class _WeeklyScheduleScreenState extends State<WeeklyScheduleScreen>
    with SingleTickerProviderStateMixin {
  // ── 状態変数 ─────────────────────────────────────────────────
  late DateTime _currentWeekStart;
  WeeklySchedule? _schedule;
  List<Customer> _customers = [];
  bool _loading = true;
  String? _errorMessage;

  /// 再生成・翌週コピーの処理中（二重実行防止。表示中の計画はそのまま残す）
  bool _processing = false;

  /// 週を素早く切り替えたとき、古い週の読込結果で新しい週を上書きしない
  final LoadSequencer _loadSeq = LoadSequencer();
  late TabController _tabController;



  @override
  void initState() {
    super.initState();
    // デフォルトは翌週の月曜から
    final now = DateTime.now();
    _currentWeekStart = WeekUtil.nextWeekStart(WeekUtil.weekStartFromDate(now));

    _tabController = TabController(length: 7, vsync: this);

    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
    WeeklyScheduleService.instance.addListener(_onScheduleChanged);
  }

  /// 他の端末（またはこの端末の別の画面）で計画が変わった: 開き直さずに反映する
  void _onScheduleChanged() {
    if (!mounted || _loading) return;
    _reloadSchedule();
  }

  @override
  void dispose() {
    WeeklyScheduleService.instance.removeListener(_onScheduleChanged);
    _loadSeq.invalidate();
    _tabController.dispose();
    super.dispose();
  }

  // ── データ読み込み ────────────────────────────────────────────

  Future<void> _loadData() async {
    if (!mounted) return;
    final token = _loadSeq.begin();
    final weekStart = _currentWeekStart;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      if (VerifyConfig.enabled) {
        await VerifyFaults.apply(VerifyFaults.weekly);
      }
      final customers = CustomerService.instance.getAllCustomers();
      final schedule = await WeeklyScheduleService.instance.getOrCreateSchedule(
        weekStart,
        customers,
      );
      if (!mounted || !_loadSeq.isCurrent(token)) return;
      setState(() {
        _customers = customers;
        _schedule = schedule;
        _loading = false;
      });
    } on WeekUnavailableException catch (e) {
      // まだ無い週を通信できずに作れない: 仮の案は出さず、理由と再試行を出す
      if (!mounted || !_loadSeq.isCurrent(token)) return;
      setState(() {
        _schedule = null;
        _errorMessage = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || !_loadSeq.isCurrent(token)) return;
      setState(() {
        _errorMessage = 'データ読み込み失敗: $e';
        _loading = false;
      });
    }
  }

  Future<void> _navigateWeek(int direction) async {
    if (!mounted) return;
    setState(() {
      _currentWeekStart = direction > 0
          ? WeekUtil.nextWeekStart(_currentWeekStart)
          : WeekUtil.previousWeekStart(_currentWeekStart);
    });
    await _loadData();
  }

  // ── 再生成（confirm） ─────────────────────────────────────────

  Future<void> _onRegenerate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.refresh, color: AppColors.primary, size: 22),
            SizedBox(width: 8),
            Text('通常予定を再生成'),
          ],
        ),
        content: const Text(
          '現在の「追加」「キャンセル」を保持したまま、\n'
          '通常予定だけ最新の定期利用曜日に更新します。\n\n'
          '続けますか？',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          AppElevatedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('再生成'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _processing) return;

    setState(() => _processing = true);
    final weekStart = _currentWeekStart;
    try {
      final weekKey = WeekUtil.weekKeyFromDate(weekStart);
      final updated = await WeeklyScheduleService.instance
          .regenerateFromRegularDays(weekKey, _customers);
      if (!mounted) return;
      setState(() {
        // 処理中に週を移動していたら、表示中の別の週を上書きしない
        if (weekStart == _currentWeekStart) _schedule = updated;
        _processing = false;
      });
      _showSaved('通常予定を再生成しました');
    } on StaffNotSelectedException {
      if (mounted) setState(() => _processing = false); // 担当者の選択を閉じた
    } catch (e) {
      if (!mounted) return;
      setState(() => _processing = false);
      _showError('再生成に失敗しました: $e');
    }
  }

  // ── 翌週コピー ────────────────────────────────────────────────

  Future<void> _onCopyToNextWeek() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.content_copy, color: AppColors.primary, size: 22),
            SizedBox(width: 8),
            Text('翌週にコピー'),
          ],
        ),
        content: const Text(
          '現在の予定を翌週にコピーします。\n'
          '（キャンセルは引き継がれません）\n\n'
          '翌週のデータが既にある場合は上書きされます。\n'
          '続けますか？',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          AppElevatedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.content_copy, size: 16),
            label: const Text('コピー'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _processing) return;

    setState(() => _processing = true);
    try {
      final weekKey = WeekUtil.weekKeyFromDate(_currentWeekStart);
      await WeeklyScheduleService.instance.copyScheduleToNextWeek(weekKey);
      if (!mounted) return;
      setState(() => _processing = false);
      _showSaved('翌週にコピーしました');
    } on StaffNotSelectedException {
      if (mounted) setState(() => _processing = false); // 担当者の選択を閉じた
    } catch (e) {
      if (!mounted) return;
      setState(() => _processing = false);
      _showError('コピーに失敗しました: $e');
    }
  }

  // ── PDF 出力 ──────────────────────────────────────────────────

  Future<void> _onExportPdf() async {
    if (_schedule == null) return;
    try {
      await WeeklySchedulePdfService.instance.printWeeklySchedule(
        _schedule!,
        _customers,
      );
    } catch (e) {
      if (!mounted) return;
      _showError('PDF出力に失敗しました: $e');
    }
  }

  // ── セルタップ（ステータス変更 / 追加 / 削除 / 時刻変更） ──────

  Future<void> _onCellTap(
    BuildContext context,
    int dayOfWeek,
    Customer? customer,
    ScheduleEntry? existingEntry,
  ) async {
    if (_schedule == null || customer == null) return;
    final weekKey = _schedule!.weekKey;

    if (existingEntry == null) {
      // エントリがない → 「追加する」
      await _addEntry(weekKey, dayOfWeek, customer);
      return;
    }

    // エントリがある → ポップアップメニュー
    final result = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _EntryActionSheet(
        entry: existingEntry,
        customer: customer,
        dayOfWeekLabel: WeekUtil.dayOfWeekJp(dayOfWeek),
      ),
    );

    if (!mounted || result == null) return;

    try {
      await _applyAction(result, weekKey, dayOfWeek, customer, existingEntry);
    } on StaffNotSelectedException {
      // 担当者の選択を閉じた → 保存しない（画面は保存先の内容に戻る）
      await _reloadSchedule();
      return;
    }

    if (!mounted) return;
    await _reloadSchedule();
    _showSaved('保存しました');
  }

  Future<void> _applyAction(
    String result,
    String weekKey,
    int dayOfWeek,
    Customer customer,
    ScheduleEntry existingEntry,
  ) async {
    switch (result) {
      case 'planned':
        await WeeklyScheduleService.instance.updateEntryStatus(
          weekKey,
          dayOfWeek,
          customer.id,
          ScheduleStatus.planned,
        );
        break;
      case 'additional':
        await WeeklyScheduleService.instance.updateEntryStatus(
          weekKey,
          dayOfWeek,
          customer.id,
          ScheduleStatus.additional,
        );
        break;
      case 'cancelled':
        await WeeklyScheduleService.instance.updateEntryStatus(
          weekKey,
          dayOfWeek,
          customer.id,
          ScheduleStatus.cancelled,
        );
        break;
      case 'delete':
        await WeeklyScheduleService.instance.removeEntry(
          weekKey,
          dayOfWeek,
          customer.id,
        );
        break;
      case 'time':
        if (!mounted) return;
        await _editTime(weekKey, dayOfWeek, customer.id, existingEntry);
        break;
    }
  }

  Future<void> _addEntry(
    String weekKey,
    int dayOfWeek,
    Customer customer,
  ) async {
    try {
      await WeeklyScheduleService.instance.addEntry(
        weekKey,
        dayOfWeek,
        ScheduleEntry(
          customerId: customer.id,
          customerName: customer.name,
          status: ScheduleStatus.additional,
        ),
      );
    } on StaffNotSelectedException {
      return; // 担当者の選択を閉じた → 追加しない
    }
    if (!mounted) return;
    await _reloadSchedule();
    _showSaved('${customer.name} を追加しました');
  }

  Future<void> _editTime(
    String weekKey,
    int dayOfWeek,
    String customerId,
    ScheduleEntry entry,
  ) async {
    // 開始時刻
    final startInitial = _parseTime(entry.plannedStartTime);
    final startTime = await showTimePicker(
      context: context,
      initialTime: startInitial ?? const TimeOfDay(hour: 9, minute: 0),
      helpText: '開始時刻を選択',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (!mounted || startTime == null) return;

    // 終了時刻
    final endInitial = _parseTime(entry.plannedEndTime);
    final endTime = await showTimePicker(
      context: context,
      initialTime: endInitial ?? const TimeOfDay(hour: 15, minute: 0),
      helpText: '終了時刻を選択',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (!mounted) return;

    await WeeklyScheduleService.instance.updateEntryTimes(
      weekKey,
      dayOfWeek,
      customerId,
      _formatTime(startTime),
      endTime != null ? _formatTime(endTime) : null,
    );
  }

  // ── モバイル用: 日別カードのセルタップ（顧客選択なし版） ─────────

  Future<void> _onCardTap(
    int dayOfWeek,
    Customer customer,
    ScheduleEntry? entry,
  ) async {
    await _onCellTap(context, dayOfWeek, customer, entry);
  }

  // ── スケジュール再読込（保存後） ──────────────────────────────

  Future<void> _reloadSchedule() async {
    if (!mounted) return;
    final weekKey = WeekUtil.weekKeyFromDate(_currentWeekStart);
    final updated = WeeklyScheduleService.instance.getScheduleByWeekKey(weekKey);
    if (updated != null && mounted) {
      setState(() => _schedule = updated);
    } else if (mounted) {
      setState(() {}); // 同じオブジェクトの中身が変わった
    }
  }

  // ── 通知ヘルパー ──────────────────────────────────────────────

  void _showSaved(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SuccessCheck(size: 18),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
        backgroundColor: _ScheduleColors.planned,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // ── ユーティリティ ────────────────────────────────────────────

  TimeOfDay? _parseTime(String? timeStr) {
    if (timeStr == null) return null;
    final parts = timeStr.split(':');
    if (parts.length != 2) return null;
    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 9,
      minute: int.tryParse(parts[1]) ?? 0,
    );
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // ════════════════════════════════════════════════════════════════
  // BUILD
  // ════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(context),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final weekKey = WeekUtil.weekKeyFromDate(_currentWeekStart);
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('週間利用計画', style: TextStyle(fontSize: 16)),
          Text(
            weekKey,
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
        ],
      ),
      actions: [
        // ← 前週
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: '前の週',
          onPressed: () => _navigateWeek(-1),
        ),
        // 翌週 →
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: '次の週',
          onPressed: () => _navigateWeek(1),
        ),
        // 翌週コピー
        IconButton(
          icon: const Icon(Icons.content_copy),
          tooltip: '翌週にコピー',
          onPressed: _processing ? null : _onCopyToNextWeek,
        ),
        // PDF出力
        IconButton(
          icon: const Icon(Icons.picture_as_pdf),
          tooltip: 'PDF出力',
          onPressed: _schedule == null ? null : _onExportPdf,
        ),
        // 再生成
        IconButton(
          icon: const Icon(Icons.sync),
          tooltip: '通常予定を再生成',
          onPressed: _processing ? null : _onRegenerate,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    // 読込中は最終レイアウトと同構造の骨格 → 完了でクロスフェード。
    // 失敗時は骨格のまま放置せず、エラー＋再試行（SkeletonGate が担当）。
    // 週が変わったら（contentKey）旧週の表を新しい週として見せない。
    // 再生成・コピーの処理中は骨格に戻さず、上端の進行バーだけ出す。
    final gate = SkeletonGate(
      loading: _loading,
      contentKey: _currentWeekStart,
      errorMessage: _errorMessage,
      onRetry: _loadData,
      skeleton: LayoutBuilder(
        builder: (ctx, c) => WeeklyScheduleSkeleton(
          wide: c.maxWidth >= _kTableBreakpoint,
        ),
      ),
      builder: _buildLoadedBody,
    );
    if (!_processing) return gate;
    return Stack(
      fit: StackFit.expand,
      children: [
        gate,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Semantics(
            label: '処理中',
            child: RefreshingBar(reduced: AppMotion.reduced(context)),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadedBody(BuildContext context) {
    return Column(
      children: [
        // ── 週情報ヘッダー
        _WeekInfoHeader(
          weekStart: _currentWeekStart,
          schedule: _schedule,
        ),
        // ── メイン
        Expanded(
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final width = constraints.maxWidth;
              if (width >= _kTableBreakpoint) {
                return _buildTableView(ctx, width);
              }
              return _buildTabView(ctx);
            },
          ),
        ),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════
  // 表形式ビュー（>= 768px）
  // ════════════════════════════════════════════════════════════════

  Widget _buildTableView(BuildContext context, double width) {
    if (_schedule == null || _customers.isEmpty) {
      return const Center(child: Text('顧客データがありません'));
    }

    // 全週に登場する顧客 + アクティブ顧客（氏名順）
    final allIds = _schedule!.allCustomerIds;
    final customerMap = <String, Customer>{
      for (final c in _customers) c.id: c,
    };
    final tableCustomers = {
      ...allIds.map((id) => customerMap[id]).whereType<Customer>(),
      ..._customers.where((c) => c.isActive),
    }.toList()
      ..sort((a, b) => a.nameKana.compareTo(b.nameKana));

    if (tableCustomers.isEmpty) {
      return const Center(child: Text('顧客データがありません'));
    }

    final isCompact = width < _kWideBreakpoint;
    final usageMap = _schedule!.usageByCustomer();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Table(
        border: TableBorder.all(
          color: Colors.grey.shade300,
          width: 0.5,
        ),
        columnWidths: {
          0: isCompact
              ? const FixedColumnWidth(120)
              : const FixedColumnWidth(160),
          for (int i = 1; i <= 7; i++) i: const FlexColumnWidth(1),
          8: isCompact
              ? const FixedColumnWidth(48)
              : const FixedColumnWidth(56),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          // ── ヘッダー行
          _buildTableHeaderRow(isCompact),
          // ── 顧客行
          for (final customer in tableCustomers)
            _buildTableCustomerRow(
              context,
              customer,
              usageMap[customer.id] ?? 0,
              isCompact,
            ),
          // ── 日別合計行
          _buildTableTotalRow(isCompact),
        ],
      ),
    );
  }

  TableRow _buildTableHeaderRow(bool isCompact) {
    final now = DateTime.now();
    const dayLabels = ['月', '火', '水', '木', '金', '土', '日'];

    return TableRow(
      decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1)),
      children: [
        _TableCell(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              '氏名',
              style: TextStyle(
                fontSize: isCompact ? 11 : 13,
                fontWeight: FontWeight.w700,
                color: AppColors.onSurface,
              ),
            ),
          ),
        ),
        for (int i = 0; i < 7; i++) ...[
          (() {
            final date = _currentWeekStart.add(Duration(days: i));
            final isToday = date.year == now.year &&
                date.month == now.month &&
                date.day == now.day;
            return _TableCell(
              child: Container(
                decoration: isToday
                    ? BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.15),
                      )
                    : null,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      dayLabels[i],
                      style: TextStyle(
                        fontSize: isCompact ? 11 : 13,
                        fontWeight: FontWeight.w700,
                        color: i == 5
                            ? const Color(0xFF1565C0)
                            : i == 6
                                ? AppColors.error
                                : AppColors.onSurface,
                      ),
                    ),
                    Text(
                      '${date.month}/${date.day}',
                      style: const TextStyle(
                        fontSize: 9,
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          })(),
        ],
        const _TableCell(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Text(
                '週\n計',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  TableRow _buildTableCustomerRow(
    BuildContext context,
    Customer customer,
    int weeklyUsage,
    bool isCompact,
  ) {
    final usedDays = customer.currentMonthUsedDays;
    final available = customer.monthlyAvailableDays;

    return TableRow(
      children: [
        // 氏名列
        _TableCell(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  customer.name,
                  style: TextStyle(
                    fontSize: isCompact ? 11 : 13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '今月 $usedDays/$available 日',
                  style: TextStyle(
                    fontSize: 9,
                    color: usedDays >= available
                        ? AppColors.error
                        : AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 月〜日（7列）
        for (int dow = 1; dow <= 7; dow++) ...[
          _buildTableDayCell(context, customer, dow, isCompact),
        ],
        // 週合計
        _TableCell(
          child: Center(
            child: Text(
              '$weeklyUsage',
              style: TextStyle(
                fontSize: isCompact ? 12 : 14,
                fontWeight: FontWeight.w700,
                color: weeklyUsage > 0 ? AppColors.primary : AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTableDayCell(
    BuildContext context,
    Customer customer,
    int dayOfWeek,
    bool isCompact,
  ) {
    final slot = _schedule?.slotForDay(dayOfWeek);
    final entry = slot?.findEntry(customer.id);

    return _TableCell(
      child: InkWell(
        onTap: () => _onCellTap(context, dayOfWeek, customer, entry),
        child: Container(
          constraints: BoxConstraints(
            minHeight: isCompact ? 40 : 48,
          ),
          decoration: BoxDecoration(
            color: entry != null
                ? _ScheduleColors.background(entry.status)
                : Colors.transparent,
          ),
          child: Center(
            child: entry == null
                ? Icon(
                    Icons.add,
                    size: 14,
                    color: Colors.grey.shade300,
                  )
                : _EntryCellContent(entry: entry, compact: isCompact),
          ),
        ),
      ),
    );
  }

  TableRow _buildTableTotalRow(bool isCompact) {
    return TableRow(
      decoration: BoxDecoration(color: Colors.grey.shade100),
      children: [
        _TableCell(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              '日計',
              style: TextStyle(
                fontSize: isCompact ? 11 : 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        for (int dow = 1; dow <= 7; dow++) ...[
          _TableCell(
            child: Center(
              child: Text(
                '${_schedule?.slotForDay(dow)?.activeCount ?? 0}名',
                style: TextStyle(
                  fontSize: isCompact ? 11 : 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
          ),
        ],
        const _TableCell(child: SizedBox()),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════
  // タブビュー（< 768px）
  // ════════════════════════════════════════════════════════════════

  Widget _buildTabView(BuildContext context) {
    return Column(
      children: [
        // タブバー
        WeeklyDayTabBar(
          controller: _tabController,
          weekStart: _currentWeekStart,
          countForDay: (day) => _schedule?.slotForDay(day)?.activeCount ?? 0,
        ),
        // タブコンテンツ
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: List.generate(7, (i) {
              return _buildDayTabContent(context, i + 1);
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildDayTabContent(BuildContext context, int dayOfWeek) {
    final slot = _schedule?.slotForDay(dayOfWeek);
    final activeCount = slot?.activeCount ?? 0;

    // アクティブ顧客の全リスト（追加できる顧客を表示するため）
    final customerMap = <String, Customer>{
      for (final c in _customers) c.id: c,
    };

    // スケジュール済み顧客 + アクティブ顧客の合体リスト（氏名順）
    final allIds = <String>{
      if (slot != null)
        for (final e in slot.entries) e.customerId,
      for (final c in _customers.where((c) => c.isActive)) c.id,
    };
    final sortedCustomers = allIds
        .map((id) => customerMap[id])
        .whereType<Customer>()
        .toList()
      ..sort((a, b) => a.nameKana.compareTo(b.nameKana));

    if (sortedCustomers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '顧客データがありません\n顧客管理から登録してください',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.onSurfaceVariant),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // 日計
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '利用予定: $activeCount 名',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ),
        for (final customer in sortedCustomers) ...[
          _buildMobileCustomerCard(
            context,
            customer,
            dayOfWeek,
            slot?.findEntry(customer.id),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildMobileCustomerCard(
    BuildContext context,
    Customer customer,
    int dayOfWeek,
    ScheduleEntry? entry,
  ) {
    final hasEntry = entry != null;
    final isCancelled = entry?.status == ScheduleStatus.cancelled;

    return Card(
      elevation: hasEntry && !isCancelled ? 2 : 0.5,
      color: entry == null
          ? Colors.grey.shade50
          : _ScheduleColors.background(entry.status),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        side: BorderSide(
          color: entry == null
              ? Colors.grey.shade200
              : _ScheduleColors.foreground(entry.status).withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: InkWell(
        onTap: () => _onCardTap(dayOfWeek, customer, entry),
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // ステータスアイコン
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: entry == null
                      ? Colors.grey.shade200
                      : _ScheduleColors.foreground(entry.status)
                          .withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    entry == null ? '+' : _ScheduleColors.icon(entry.status),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: entry == null
                          ? Colors.grey.shade400
                          : _ScheduleColors.foreground(entry.status),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // 顧客情報
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      customer.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isCancelled
                            ? AppColors.onSurfaceVariant
                            : AppColors.onSurface,
                        decoration: isCancelled
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    Row(
                      children: [
                        if (entry != null) ...[
                          _StatusBadge(status: entry.status),
                          const SizedBox(width: 6),
                        ],
                        if (entry?.plannedStartTime != null) ...[
                          Text(
                            '${entry!.plannedStartTime}'
                            '${entry.plannedEndTime != null ? "〜${entry.plannedEndTime}" : ""}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (entry == null)
                          const Text(
                            'タップして追加',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.more_vert,
                color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 週情報ヘッダーウィジェット
// ════════════════════════════════════════════════════════════════
class _WeekInfoHeader extends StatelessWidget {
  final DateTime weekStart;
  final WeeklySchedule? schedule;

  const _WeekInfoHeader({
    required this.weekStart,
    this.schedule,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final todayWeekStart = WeekUtil.weekStartFromDate(now);
    final isCurrentWeek = weekStart == todayWeekStart;
    final isNextWeek = weekStart ==
        WeekUtil.nextWeekStart(todayWeekStart);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  WeekUtil.weekRangeLabel(weekStart),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onSurface,
                  ),
                ),
                Text(
                  WeekUtil.weekInMonthLabel(weekStart),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (isCurrentWeek)
            const _WeekBadge(label: '今週', color: AppColors.secondary),
          if (isNextWeek)
            const _WeekBadge(label: '翌週', color: AppColors.primary),
          if (schedule != null) ...[
            const SizedBox(width: 8),
            Text(
              '総計 ${_totalActiveCount(schedule!)} 件',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  int _totalActiveCount(WeeklySchedule s) {
    int total = 0;
    for (final slot in s.dailySlots) {
      total += slot.activeCount;
    }
    return total;
  }
}

class _WeekBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _WeekBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 表セルウィジェット
// ════════════════════════════════════════════════════════════════
class _TableCell extends StatelessWidget {
  final Widget child;
  const _TableCell({required this.child});

  @override
  Widget build(BuildContext context) => child;
}

// ════════════════════════════════════════════════════════════════
// セルコンテンツウィジェット（表形式用）
// ════════════════════════════════════════════════════════════════
class _EntryCellContent extends StatelessWidget {
  final ScheduleEntry entry;
  final bool compact;

  const _EntryCellContent({required this.entry, required this.compact});

  @override
  Widget build(BuildContext context) {
    final color = _ScheduleColors.foreground(entry.status);
    final isCancelled = entry.status == ScheduleStatus.cancelled;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _ScheduleColors.icon(entry.status),
            style: TextStyle(
              fontSize: compact ? 12 : 14,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          if (!isCancelled && entry.plannedStartTime != null)
            Text(
              entry.plannedStartTime!,
              style: TextStyle(
                fontSize: compact ? 7 : 9,
                color: color.withValues(alpha: 0.8),
              ),
            ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// ステータスバッジ（モバイルカード用）
// ════════════════════════════════════════════════════════════════
class _StatusBadge extends StatelessWidget {
  final ScheduleStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: _ScheduleColors.foreground(status).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _statusLabel(status),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: _ScheduleColors.foreground(status),
        ),
      ),
    );
  }

  String _statusLabel(ScheduleStatus s) {
    switch (s) {
      case ScheduleStatus.planned:
        return '通常予定';
      case ScheduleStatus.additional:
        return '追加';
      case ScheduleStatus.cancelled:
        return 'キャンセル';
    }
  }
}

// ════════════════════════════════════════════════════════════════
// エントリアクションシート（BottomSheet）
// ════════════════════════════════════════════════════════════════
class _EntryActionSheet extends StatelessWidget {
  final ScheduleEntry entry;
  final Customer customer;
  final String dayOfWeekLabel;

  const _EntryActionSheet({
    required this.entry,
    required this.customer,
    required this.dayOfWeekLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ハンドル
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // タイトル
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  '${customer.name}（$dayOfWeekLabel）',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(status: entry.status),
              ],
            ),
          ),
          const Divider(),
          // ステータス変更
          if (entry.status != ScheduleStatus.planned)
            const _ActionTile(
              icon: Icons.check_circle_outline,
              color: _ScheduleColors.planned,
              label: '通常予定にする',
              value: 'planned',
            ),
          if (entry.status != ScheduleStatus.additional)
            const _ActionTile(
              icon: Icons.add_circle_outline,
              color: _ScheduleColors.additional,
              label: '追加に変更',
              value: 'additional',
            ),
          if (entry.status != ScheduleStatus.cancelled)
            const _ActionTile(
              icon: Icons.cancel_outlined,
              color: _ScheduleColors.cancelled,
              label: 'キャンセルにする',
              value: 'cancelled',
            ),
          const Divider(),
          const _ActionTile(
            icon: Icons.access_time,
            color: AppColors.primary,
            label: '時刻を変更',
            value: 'time',
          ),
          const _ActionTile(
            icon: Icons.delete_outline,
            color: AppColors.error,
            label: 'エントリを削除',
            value: 'delete',
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  const _ActionTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color, size: 22),
      title: Text(
        label,
        style: TextStyle(fontSize: 14, color: color),
      ),
      onTap: () => Navigator.of(context).pop(value),
    );
  }
}


// ════════════════════════════════════════════════════════════════
// 曜日ストリップ（< 768px のタブバー）
// ════════════════════════════════════════════════════════════════

/// 7 日分の曜日タブ。曜日・日付(M/D)・利用人数バッジを出す。
///
/// 390px 幅では 1 セルが約 55px。TabBar 既定の左右パディング(16px ×2)だと
/// 実効幅が約 23px となり「11/16」が「11/1」「6」に折り返していたため、
/// 左右パディングを詰めて日付を 1 行で表示する（文字は縮小しない）。
class WeeklyDayTabBar extends StatelessWidget {
  final TabController? controller;
  final DateTime weekStart;

  /// 1(月)〜7(日) の利用人数
  final int Function(int day) countForDay;

  const WeeklyDayTabBar({
    super.key,
    required this.controller,
    required this.weekStart,
    required this.countForDay,
  });

  static const dayLabels = ['月', '火', '水', '木', '金', '土', '日'];

  @override
  Widget build(BuildContext context) {
    return TabBar(
      controller: controller,
      isScrollable: false,
      // 既定 16px だと 390px 幅で日付が折り返す。バッジ(右へ -10)の逃げ分も残す。
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      indicatorColor: AppColors.primary,
      labelColor: AppColors.primary,
      unselectedLabelColor: AppColors.onSurfaceVariant,
      tabs: List.generate(7, (i) {
        final date = weekStart.add(Duration(days: i));
        final count = countForDay(i + 1);
        return Tab(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    dayLabels[i],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: i == 5
                          ? const Color(0xFF1565C0)
                          : i == 6
                              ? AppColors.error
                              : null,
                    ),
                  ),
                  Text(
                    '${date.month}/${date.day}',
                    key: Key('weeklyDayDate$i'),
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(fontSize: 10),
                  ),
                ],
              ),
              if (count > 0)
                Positioned(
                  top: -2,
                  right: -10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}
