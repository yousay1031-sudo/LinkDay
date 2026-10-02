import 'package:flutter/material.dart';

import '../models/attendance_record.dart';
import '../services/attendance_pdf_service.dart';
import '../services/attendance_service.dart';
import '../services/monthly_usage_service.dart';
import '../services/customer_service.dart';
import '../theme/app_theme.dart';
import '../widgets/attendance_status_badge.dart';
import '../widgets/attendance_time_chip.dart';

/// 当日出席管理画面
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  DateTime _selectedDate = DateTime.now();
  List<AttendanceRecord> _records = [];
  bool _isLoading = true;
  bool _isPdfGenerating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAndLoad();
    });
  }

  // ── データ読み込み ──────────────────────────────────────────

  Future<void> _initializeAndLoad() async {
    setState(() => _isLoading = true);
    await _ensureScheduled();
    _loadRecords();
  }

  /// 当日対象顧客を scheduled として自動生成
  Future<void> _ensureScheduled() async {
    final customers = CustomerService.instance.getAllCustomers();
    await AttendanceService.instance.ensureTodayScheduledRecords(
      _selectedDate,
      customers,
    );
  }

  void _loadRecords() {
    final records =
        AttendanceService.instance.getRecordsByDate(_selectedDate);
    debugPrint('[AttendanceScreen] records loaded: ${records.length}');
    if (!mounted) return;
    setState(() {
      _records = records;
      _isLoading = false;
    });
  }

  void _reload() {
    _loadRecords();
  }

  // ── 日付変更 ────────────────────────────────────────────────

  Future<void> _changeDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: '日付を選択',
      confirmText: '決定',
      cancelText: 'キャンセル',
    );
    if (picked == null) return;
    if (!mounted) return;

    setState(() {
      _selectedDate = picked;
      _isLoading = true;
    });
    await _ensureScheduled();
    _loadRecords();
  }

  // ── PDF 出力 ────────────────────────────────────────────────

  Future<void> _printPdf() async {
    if (_isPdfGenerating) return;
    setState(() => _isPdfGenerating = true);
    try {
      await AttendancePdfService.instance
          .printAttendanceSheet(_selectedDate);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('PDF生成に失敗しました: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isPdfGenerating = false);
    }
  }

  // ── 入室処理 ────────────────────────────────────────────────

  Future<void> _markPresent(AttendanceRecord record) async {
    await AttendanceService.instance.markPresent(
      customerId: record.customerId,
      date: _selectedDate,
    );
    _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${record.customerName} さんが入室しました'),
        backgroundColor: const Color(0xFF2E7D32),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    // Day 9: 支給量超過の即時警告（記録はブロックしない）
    await _warnIfOverProjected(record);
  }

  /// 入室後に支給量超過見込みなら警告する（Day 9）
  ///
  /// 制度上、超過しても記録自体は必要なため処理はブロックせず警告のみ行う。
  Future<void> _warnIfOverProjected(AttendanceRecord record) async {
    final usage = await MonthlyUsageService.instance
        .checkOverageAfterCheckIn(record.customerId, today: _selectedDate);
    if (usage == null || !mounted) return;
    final name = record.customerName.isNotEmpty
        ? record.customerName
        : usage.customerName;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$name：今月の支給日数を超過します'
                    '（${usage.projectedTotal}/${usage.available}日）',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  const Text('超過分は利用者負担となる可能性があります',
                      style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 7),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── 退室処理 ────────────────────────────────────────────────

  Future<void> _markDeparted(AttendanceRecord record) async {
    final result = await AttendanceService.instance.markDeparted(
      customerId: record.customerId,
      date: _selectedDate,
    );
    if (!mounted) return;

    if (result == DepartResult.noCheckIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('先に入室を記録してください。入室記録がない場合は退室できません。'),
          backgroundColor: AppColors.warning,
          duration: Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    _reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${record.customerName} さんが退室しました'),
        backgroundColor: AppColors.primary,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── 欠席処理 ────────────────────────────────────────────────

  Future<void> _showAbsenceDialog(AttendanceRecord record) async {
    String? selectedReason = kAbsenceReasons.first;
    String freeText = '';
    bool isOther = false;

    // Day 10 Fix: 以前は「キャンセル」も「保存」も pop() のみで結果を返さず、
    // キャンセルしても欠席が保存されていた（出席データと Day 9 支給量集計が
    // 意図せず書き換わる致命バグ）。確定/取消を bool で明示的に受け取る。
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.cancel_outlined,
                  color: AppColors.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '欠席理由: ${record.customerName}',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('欠席理由を選択してください',
                    style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                // 理由選択肢
                ...kAbsenceReasons.map((reason) {
                  // ignore: deprecated_member_use
                  return RadioListTile<String>(
                    title: Text(reason, style: const TextStyle(fontSize: 14)),
                    value: reason,
                    // ignore: deprecated_member_use
                    groupValue: selectedReason,
                    dense: true,
                    activeColor: AppColors.error,
                    // ignore: deprecated_member_use
                    onChanged: (val) {
                      setDialogState(() {
                        selectedReason = val;
                        isOther = val == 'その他';
                        if (!isOther) freeText = '';
                      });
                    },
                  );
                }),
                // 「その他」自由入力欄
                if (isOther) ...[
                  const SizedBox(height: 8),
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '理由を入力',
                      hintText: '具体的な理由を記入してください',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => freeText = v,
                  ),
                ],
                const SizedBox(height: 16),
                // LINE 通知確認
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF06C755).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF06C755).withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 16, color: Color(0xFF06C755)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          // Day 10 Fix: LINE 通知は未実装。送信されると
                          // 誘導する文言を「準備中」に修正。
                          'LINE 通知は準備中です（現在は自動送信されません）',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.error,
              ),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('欠席として保存'),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
            ),
          ],
        ),
      ),
    );

    // キャンセル（または画面破棄）時は保存しない
    if (confirmed != true) return;
    if (!mounted) return;

    final finalReason = isOther
        ? (freeText.isEmpty ? 'その他' : freeText)
        : (selectedReason ?? kAbsenceReasons.first);

    await AttendanceService.instance.markAbsent(
      customerId: record.customerId,
      date: _selectedDate,
      reason: finalReason,
    );
    if (!mounted) return;

    _reload();

    // LINE 通知確認ダイアログ
    await _showLineNotificationDialog(record.customerName);
  }

  /// 欠席記録完了の案内ダイアログ
  ///
  /// Day 10 Fix: 以前は「送る」ボタンを持つ「空き枠 LINE 通知」ダイアログで、
  /// 押しても実際には送信されない（未実装）ため「通知したつもり」の
  /// 誤認を招く状態だった。送信ボタンを廃止し、準備中の案内に統一する。
  Future<void> _showLineNotificationDialog(String customerName) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle_outline,
                color: AppColors.success, size: 20),
            SizedBox(width: 8),
            Expanded(child: Text('欠席を記録しました')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$customerName さんの欠席を記録しました。'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: AppColors.warning),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '空き枠の LINE 通知は準備中です。\n'
                      'お手数ですが、保護者への連絡は電話等でお願いします。',
                      style: TextStyle(fontSize: 11, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ── 欠席取り消し ────────────────────────────────────────────

  Future<void> _resetAbsent(AttendanceRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('欠席を取り消す'),
        content: Text(
          '${record.customerName} さんの欠席を取り消して「予定」に戻しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('取り消す'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    await AttendanceService.instance.resetAbsent(
      customerId: record.customerId,
      date: _selectedDate,
    );
    _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${record.customerName} さんの欠席を取り消しました'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── 時刻修正 ────────────────────────────────────────────────

  Future<void> _onCheckInChanged(
      AttendanceRecord record, DateTime newTime) async {
    await AttendanceService.instance.updateCheckInTime(
      customerId: record.customerId,
      date: _selectedDate,
      newTime: newTime,
    );
    _reload();
  }

  Future<void> _onCheckOutChanged(
      AttendanceRecord record, DateTime newTime) async {
    await AttendanceService.instance.updateCheckOutTime(
      customerId: record.customerId,
      date: _selectedDate,
      newTime: newTime,
    );
    _reload();
  }

  // ── UI ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _buildSummaryBar(),
                  Expanded(child: _buildBody()),
                ],
              ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final wd = weekdays[_selectedDate.weekday - 1];
    final dateStr =
        '${_selectedDate.month}/${_selectedDate.day}（$wd）';

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('当日出席管理'),
          Text(
            dateStr,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.calendar_today_outlined),
          tooltip: '日付変更',
          onPressed: _changeDate,
        ),
        _isPdfGenerating
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                ),
              )
            : IconButton(
                icon: const Icon(Icons.picture_as_pdf_outlined),
                tooltip: 'PDF出力',
                onPressed: _printPdf,
              ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// 集計バー
  Widget _buildSummaryBar() {
    final summary =
        AttendanceService.instance.getTodaySummary(_selectedDate);
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _summaryChip(
              label: '予定',
              count: summary.scheduledCount,
              color: const Color(0xFF1565C0),
              bg: const Color(0xFFE3F2FD),
              icon: Icons.schedule,
            ),
            const SizedBox(width: 8),
            _summaryChip(
              label: '在室中',
              count: summary.presentCount,
              color: const Color(0xFF2E7D32),
              bg: const Color(0xFFE8F5E9),
              icon: Icons.login,
              pulseDot: summary.presentCount > 0,
            ),
            const SizedBox(width: 8),
            _summaryChip(
              label: '退室済',
              count: summary.departedCount,
              color: const Color(0xFF546E7A),
              bg: const Color(0xFFECEFF1),
              icon: Icons.logout,
            ),
            const SizedBox(width: 8),
            _summaryChip(
              label: '欠席',
              count: summary.absentCount,
              color: AppColors.error,
              bg: const Color(0xFFFFEBEE),
              icon: Icons.cancel_outlined,
            ),
            const SizedBox(width: 12),
            Container(
              height: 32,
              width: 1,
              color: AppColors.divider,
            ),
            const SizedBox(width: 12),
            _summaryChip(
              label: '空き枠',
              count: summary.availableSlots,
              color: AppColors.primary,
              bg: AppColors.primary.withValues(alpha: 0.1),
              icon: Icons.event_available,
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryChip({
    required String label,
    required int count,
    required Color color,
    required Color bg,
    required IconData icon,
    bool pulseDot = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pulseDot)
            _PulseDotSmall(color: color)
          else
            Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_records.isEmpty) {
      return _buildEmptyState();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _columnCount(constraints.maxWidth);
        final padding = constraints.maxWidth >= 900 ? 16.0 : 12.0;
        return GridView.builder(
          padding: EdgeInsets.all(padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: columns == 1 ? 2.0 : 1.15,
          ),
          itemCount: _records.length,
          itemBuilder: (ctx, i) => _AttendanceCard(
            record: _records[i],
            onMarkPresent: () => _markPresent(_records[i]),
            onMarkDeparted: () => _markDeparted(_records[i]),
            onMarkAbsent: () => _showAbsenceDialog(_records[i]),
            onResetAbsent: () => _resetAbsent(_records[i]),
            onCheckInChanged: (t) => _onCheckInChanged(_records[i], t),
            onCheckOutChanged: (t) => _onCheckOutChanged(_records[i], t),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.event_busy_outlined,
            size: 72,
            color: AppColors.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          const Text(
            '本日の利用予定者はいません',
            style: TextStyle(
              fontSize: 16,
              color: AppColors.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '顧客の定期利用曜日を確認してください',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today_outlined, size: 16),
            label: const Text('日付を変更'),
            onPressed: _changeDate,
          ),
        ],
      ),
    );
  }

  int _columnCount(double width) {
    if (width >= 1280) return 4;
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }
}

// ─────────────────────────────────────────────────────────────────────
// 利用者カード
// ─────────────────────────────────────────────────────────────────────

class _AttendanceCard extends StatelessWidget {
  final AttendanceRecord record;
  final VoidCallback onMarkPresent;
  final VoidCallback onMarkDeparted;
  final VoidCallback onMarkAbsent;
  final VoidCallback onResetAbsent;
  final Future<void> Function(DateTime) onCheckInChanged;
  final Future<void> Function(DateTime) onCheckOutChanged;

  const _AttendanceCard({
    required this.record,
    required this.onMarkPresent,
    required this.onMarkDeparted,
    required this.onMarkAbsent,
    required this.onResetAbsent,
    required this.onCheckInChanged,
    required this.onCheckOutChanged,
  });

  Color get _bgColor {
    switch (record.status) {
      case AttendanceStatus.scheduled:
        return const Color(0xFFF0F7FF);
      case AttendanceStatus.present:
        return const Color(0xFFF1FBF1);
      case AttendanceStatus.departed:
        return const Color(0xFFF5F5F5);
      case AttendanceStatus.absent:
        return const Color(0xFFFFF5F5);
    }
  }

  Color get _borderColor {
    switch (record.status) {
      case AttendanceStatus.scheduled:
        return const Color(0xFF90CAF9);
      case AttendanceStatus.present:
        return const Color(0xFF81C784);
      case AttendanceStatus.departed:
        return const Color(0xFFB0BEC5);
      case AttendanceStatus.absent:
        return const Color(0xFFEF9A9A);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        border: Border.all(color: _borderColor, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── ヘッダー行（氏名 + バッジ）
            Row(
              children: [
                Expanded(
                  child: Text(
                    record.customerName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                AttendanceStatusBadge(
                  status: record.status,
                  compact: true,
                ),
              ],
            ),

            const SizedBox(height: 8),

            // ── 時刻チップ（欠席以外）
            if (record.status != AttendanceStatus.absent) ...[
              Row(
                children: [
                  Expanded(
                    child: AttendanceTimeChip(
                      label: '入室',
                      time: record.checkInTime,
                      readOnly: record.status == AttendanceStatus.scheduled,
                      onTimeChanged: record.status == AttendanceStatus.scheduled
                          ? null
                          : onCheckInChanged,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AttendanceTimeChip(
                      label: '退室',
                      time: record.checkOutTime,
                      readOnly: record.status != AttendanceStatus.departed,
                      onTimeChanged: record.status != AttendanceStatus.departed
                          ? null
                          : onCheckOutChanged,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 提供時間
              if (record.serviceTimeLabel != null)
                Text(
                  '提供時間: ${record.serviceTimeLabel}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
            ],

            // ── 欠席理由
            if (record.status == AttendanceStatus.absent &&
                record.absenceReason != null) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 12,
                      color: AppColors.error.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        record.absenceReason!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const Spacer(),

            // ── ボタン群
            _buildButtons(context),
          ],
        ),
      ),
    );
  }

  Widget _buildButtons(BuildContext context) {
    switch (record.status) {
      case AttendanceStatus.scheduled:
        return _scheduledButtons(context);
      case AttendanceStatus.present:
        return _presentButtons(context);
      case AttendanceStatus.departed:
        return _departedLabel(context);
      case AttendanceStatus.absent:
        return _absentButtons(context);
    }
  }

  /// scheduled: 「入室」「欠席」
  Widget _scheduledButtons(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 34,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                minimumSize: Size.zero,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              icon: const Icon(Icons.login, size: 14),
              label: const Text('入室'),
              onPressed: onMarkPresent,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 34,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                minimumSize: Size.zero,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                side: const BorderSide(color: AppColors.error),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              icon: const Icon(Icons.cancel_outlined, size: 14),
              label: const Text('欠席'),
              onPressed: onMarkAbsent,
            ),
          ),
        ),
      ],
    );
  }

  /// present: 「退室」
  Widget _presentButtons(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            '在室中',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF2E7D32),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 34,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                minimumSize: Size.zero,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              icon: const Icon(Icons.logout, size: 14),
              label: const Text('退室'),
              onPressed: onMarkDeparted,
            ),
          ),
        ),
      ],
    );
  }

  /// departed: 完了表示
  Widget _departedLabel(BuildContext context) {
    return const Row(
      children: [
        Icon(Icons.check_circle_outline,
            size: 14, color: Color(0xFF546E7A)),
        SizedBox(width: 4),
        Text(
          '退室完了',
          style: TextStyle(
            fontSize: 12,
            color: Color(0xFF546E7A),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// absent: 「欠席を取り消す」
  Widget _absentButtons(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 32,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.error,
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          side: BorderSide(
              color: AppColors.error.withValues(alpha: 0.5)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        icon: const Icon(Icons.undo, size: 13),
        label: const Text('欠席を取り消す'),
        onPressed: onResetAbsent,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// 集計バー用の点滅ドット
// ─────────────────────────────────────────────────────────────────────

class _PulseDotSmall extends StatefulWidget {
  final Color color;
  const _PulseDotSmall({required this.color});

  @override
  State<_PulseDotSmall> createState() => _PulseDotSmallState();
}

class _PulseDotSmallState extends State<_PulseDotSmall>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: _anim.value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
