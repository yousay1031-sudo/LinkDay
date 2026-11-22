import 'dart:async';

import 'package:flutter/material.dart';

import '../models/attendance_record.dart';
import '../verify/verify_config.dart';
import '../verify/verify_faults.dart';
import '../models/slot_info.dart';
import '../services/attendance_pdf_service.dart';
import '../data/staff_session.dart';
import '../services/attendance_service.dart';
import '../services/monthly_usage_service.dart';
import '../services/slot_service.dart';
import '../services/customer_service.dart';
import '../services/vacancy_notification_service.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../utils/load_sequencer.dart';
import '../widgets/attendance_status_badge.dart';
import '../widgets/attendance_time_chip.dart';
import '../widgets/motion/app_buttons.dart';
import '../widgets/motion/empty_state.dart';
import '../widgets/motion/skeleton_gate.dart';
import '../widgets/motion/staggered.dart';
import '../widgets/motion/state_switcher.dart';
import '../widgets/skeletons/screen_skeletons.dart';
import '../widgets/slot_status_panel.dart';
import '../widgets/vacancy_notice_dialog.dart';
import 'notification_history_screen.dart';
import '../widgets/motion/app_spinner.dart';

/// 出席管理の画面タイトル。今日を開いているときは「当日出席管理」、
/// それ以外の日は「出席管理」（日付は下の行に出す）。
String attendanceTitleFor(DateTime selected, DateTime now) {
  final isToday = selected.year == now.year &&
      selected.month == now.month &&
      selected.day == now.day;
  return isToday ? '当日出席管理' : '出席管理';
}

/// 当日出席管理画面
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key, this.afterEnsureHook});

  /// テスト用: 当日レコード生成（保存）の直後に挟む処理。読込の保留・失敗の
  /// 再現に使う。本番では常に null。
  @visibleForTesting
  final Future<void> Function(DateTime date)? afterEnsureHook;

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  DateTime _selectedDate = DateTime.now();
  List<AttendanceRecord> _records = [];
  bool _isLoading = true;

  /// 読込（当日レコード生成〜取得）に失敗したときのメッセージ。
  /// null でなければ SkeletonGate がエラー＋再試行を表示する
  String? _loadError;
  bool _isPdfGenerating = false;

  /// 日付を素早く切り替えたとき、古い日付の読込結果で新しい日付を上書きしない
  final LoadSequencer _loadSeq = LoadSequencer();

  /// 保存中（トランザクションの応答待ち）の児童。カードに「処理中」を出し、ボタンを押せなくする
  final Set<String> _busyIds = {};

  /// Day 11: LINE 通知の送信中フラグ（二重タップ防止・進捗表示）
  bool _isSendingNotice = false;

  // ── Day 14: LINE 応募（slots）の購読 ──────────────────────
  // 選択中の日付の枠だけを購読する。日付変更時は購読を張り直す。
  StreamSubscription<List<SlotInfo>>? _slotSub;
  List<SlotInfo> _slots = const [];
  String? _slotError;

  /// 募集中→受付終了の切り替わりを画面に反映するための再描画タイマー
  Timer? _slotTick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAndLoad();
    });
    _subscribeSlots();
    _slotTick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _slots.isNotEmpty) setState(() {});
    });
    AttendanceService.instance.addListener(_onRecordsChanged);
  }

  /// 他の端末（またはこの端末の別の画面）で出席が変わった: 開き直さずに反映する
  void _onRecordsChanged() {
    if (!mounted || _isLoading || _loadError != null) return;
    _loadRecords();
  }

  @override
  void dispose() {
    AttendanceService.instance.removeListener(_onRecordsChanged);
    _loadSeq.invalidate();
    _slotSub?.cancel();
    _slotTick?.cancel();
    super.dispose();
  }

  /// 選択中の日付の枠を購読し直す。
  /// 前日の購読は必ず cancel する（他日の枠が混ざらないように）。
  void _subscribeSlots() {
    _slotSub?.cancel();
    _slotSub = null;
    setStateSafe(() {
      _slots = const [];
      _slotError = null;
    });
    try {
      _slotSub = SlotService.instance.watchByDate(_selectedDate).listen(
        (slots) {
          if (!mounted) return;
          setState(() {
            _slots = slots;
            _slotError = null;
          });
        },
        onError: (Object e) {
          debugPrint('[AttendanceScreen] slots watch error: $e');
          if (!mounted) return;
          setState(() => _slotError = '通信または権限のエラー');
        },
      );
    } catch (e) {
      // Firebase 未初期化など。出席管理そのものは止めない。
      debugPrint('[AttendanceScreen] slots watch failed: $e');
      setStateSafe(() => _slotError = '接続できません');
    }
  }

  void setStateSafe(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    } else {
      fn();
    }
  }

  String? _customerNameOf(String customerId) =>
      CustomerService.instance.getCustomerById(customerId)?.name;

  /// 欠席した児童の枠（カード内チップ用）。同じ児童は 1 日 1 枠。
  SlotInfo? _slotForAbsent(String customerId) {
    for (final s in _slots) {
      if (s.sourceAbsent == customerId) return s;
    }
    return null;
  }

  // ── データ読み込み ──────────────────────────────────────────

  Future<void> _initializeAndLoad() async {
    final token = _loadSeq.begin();
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    await _loadForSelectedDate(token, _selectedDate);
  }

  /// 指定日のレコードを用意して読み込む。
  /// - 失敗しても `_isLoading` のまま固まらせず、エラー＋再試行を出す
  /// - 待機中に日付が変わっていたら結果は捨てる（古い失敗も表示しない）
  /// - 当日レコード生成（保存）は待機の前に完了させる＝古い表示結果の破棄で
  ///   保存処理そのものは中断されない
  Future<void> _loadForSelectedDate(int token, DateTime date) async {
    try {
      await _ensureScheduled(date);
      await widget.afterEnsureHook?.call(date);
      // 検証構成限定: 読込の遅延・失敗を再現する（通常ビルドでは消える）
      if (VerifyConfig.enabled) {
        await VerifyFaults.apply(VerifyFaults.attendance);
      }
      if (!mounted || !_loadSeq.isCurrent(token)) return;
      _loadRecords(throwOnError: true);
    } catch (e) {
      debugPrint('[AttendanceScreen] load failed: $e');
      if (!mounted || !_loadSeq.isCurrent(token)) return;
      setState(() {
        _isLoading = false;
        _loadError = '出席情報の読み込みに失敗しました';
      });
    }
  }

  /// エラー表示の「再試行」
  void _retryLoad() => _initializeAndLoad();

  /// 当日対象顧客を scheduled として自動生成
  Future<void> _ensureScheduled(DateTime date) async {
    final customers = CustomerService.instance.getAllCustomers();
    await AttendanceService.instance.ensureTodayScheduledRecords(
      date,
      customers,
    );
  }

  void _loadRecords({bool throwOnError = false}) {
    final List<AttendanceRecord> records;
    try {
      records = AttendanceService.instance.getRecordsByDate(_selectedDate);
    } catch (e) {
      if (throwOnError) rethrow;
      debugPrint('[AttendanceScreen] reload failed: $e');
      return; // 操作後の再読込失敗では表示中の内容を潰さない
    }
    debugPrint('[AttendanceScreen] records loaded: ${records.length}');
    if (!mounted) return;
    setState(() {
      _records = records;
      _isLoading = false;
      _loadError = null;
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
    await _selectDate(picked);
  }

  /// テスト用: 日付ピッカーを介さずに日付を切り替える
  @visibleForTesting
  Future<void> debugSelectDate(DateTime picked) => _selectDate(picked);

  Future<void> _selectDate(DateTime picked) async {
    final token = _loadSeq.begin();
    setState(() {
      _selectedDate = picked;
      _isLoading = true;
      _loadError = null;
    });
    _subscribeSlots();
    // 待っている間にさらに日付が変わっていたら、この結果は捨てる
    await _loadForSelectedDate(token, picked);
  }

  // ── PDF 出力 ────────────────────────────────────────────────

  Future<void> _printPdf() async {
    if (_isPdfGenerating) return;
    setState(() => _isPdfGenerating = true);
    try {
      await AttendancePdfService.instance.printAttendanceSheet(_selectedDate);
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

  // ── 記録を変える操作の共通処理（段階5） ──────────────────────

  /// 入室・退室・欠席・欠席の取り消しを実行する。成功したら true。
  ///
  /// - 担当者の選択を閉じた → 何もしない
  /// - 他の端末で先に状態が変わっていた → 記録せず、最新の状態を表示して知らせる
  ///   （状態を逆戻りさせない）
  /// - 通信できない → 記録せず、理由と「再試行」を出す（オフラインでは記録しない）
  Future<bool> _guardRecordOp(
    String what,
    Future<void> Function() op, {
    required VoidCallback retry,
    required String customerId,
  }) async {
    // 保存中（最長 10 秒待つ）は同じ児童の操作を受け付けない（二度押し防止）
    if (_busyIds.contains(customerId)) return false;
    setState(() => _busyIds.add(customerId));
    try {
      await op();
      return true;
    } on StaffNotSelectedException {
      return false;
    } on AttendanceConflictException catch (e) {
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: const Key('attendanceConflictSnack'),
            content: Text('$what：${e.message}'),
            backgroundColor: AppColors.warning,
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    } on AttendanceUnavailableException catch (e) {
      _busyIds.remove(customerId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: const Key('attendanceOfflineSnack'),
            content: Text('$what：${e.message}'),
            backgroundColor: AppColors.error,
            duration: const Duration(seconds: 10),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '再試行',
              textColor: Colors.white,
              onPressed: retry,
            ),
          ),
        );
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _busyIds.remove(customerId));
      } else {
        _busyIds.remove(customerId);
      }
    }
  }

  // ── 入室処理 ────────────────────────────────────────────────

  Future<void> _markPresent(AttendanceRecord record) async {
    final ok = await _guardRecordOp(
      '${record.customerName} さんの入室',
      () => AttendanceService.instance.markPresent(
        customerId: record.customerId,
        date: _selectedDate,
        // 操作を始めたときに画面に出ていた状態（他の端末の操作を逆戻りさせない）
        expected: record.status,
      ),
      retry: () => _markPresent(record),
      customerId: record.customerId,
    );
    if (!ok) return;
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
            const Icon(Icons.warning_amber_rounded,
                color: Colors.white, size: 20),
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
    var result = DepartResult.success;
    final ok = await _guardRecordOp(
      '${record.customerName} さんの退室',
      () async {
        result = await AttendanceService.instance.markDeparted(
          customerId: record.customerId,
          date: _selectedDate,
          expected: record.status,
        );
      },
      retry: () => _markDeparted(record),
      customerId: record.customerId,
    );
    if (!ok || !mounted) return;

    if (result == DepartResult.noCheckIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('先に入室を記録してください。入室記録がない場合は退室できません。'),
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
                const Text('欠席理由を選択してください', style: TextStyle(fontSize: 13)),
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
                // LINE 通知の案内
                // Day 11: 空き枠通知を実装。保存後に候補確認ダイアログを出し、
                // 職員が宛先を確認してから送信する（自動送信はしない）。
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: kLineGreen.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: kLineGreen.withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 16, color: kLineGreen),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '保存後に「空き枠のLINE通知」候補を表示します。\n'
                          '確認してから送信できます（自動送信はしません）。',
                          style: TextStyle(fontSize: 11, height: 1.4),
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

    await _saveAbsent(record, finalReason);
  }

  /// 欠席を保存し、成功したときだけ空き枠通知フローを起動する
  Future<void> _saveAbsent(AttendanceRecord record, String reason) async {
    final ok = await _guardRecordOp(
      '${record.customerName} さんの欠席',
      () => AttendanceService.instance.markAbsent(
        customerId: record.customerId,
        date: _selectedDate,
        reason: reason,
        // 欠席理由を選んでいる間に他の端末で入室された場合は記録しない
        expected: record.status,
      ),
      retry: () => _saveAbsent(record, reason),
      customerId: record.customerId,
    );
    if (!ok || !mounted) return;

    _reload();

    // Day 11: 欠席保存成功後に空き枠通知フローを起動する（動きは従来どおり。
    // 送信は職員が確認して「送信する」を押したときだけ。検証構成では送信しない）
    await _runVacancyNotificationFlow(record);
  }

  // ── Day 11: 空き枠 LINE 通知フロー ──────────────────────────

  /// 欠席登録成功後のフック。
  ///
  /// 1. 候補抽出（VacancyNotificationService.findCandidates）
  /// 2. 候補確認ダイアログ（職員がチェックを外せる／未連携は別枠）
  /// 3. 「送信する」が明示的に押された場合のみ Callable Function 呼び出し
  ///
  /// 【BUG-002 の教訓】
  /// ダイアログの戻り値 shouldSend が true のときだけ送信する。
  /// null（バリアタップ・戻るキー）は VacancyNoticeDialog.show が
  /// cancelled に正規化するため、ここで送信されることはない。
  Future<void> _runVacancyNotificationFlow(AttendanceRecord record) async {
    final svc = VacancyNotificationService.instance;

    VacancyCandidateResult candidates;
    try {
      candidates = await svc.findCandidates(
        date: _selectedDate,
        absentCustomerIds: [record.customerId],
      );
    } catch (e) {
      debugPrint('[AttendanceScreen] findCandidates failed: $e');
      if (!mounted) return;
      await _showAbsenceSavedDialog(
        record.customerName,
        note: '空き枠候補の抽出に失敗しました。保護者への連絡は電話等でお願いします。',
      );
      return;
    }
    if (!mounted) return;

    // 候補 0 件 → 通知ダイアログは出さず完了案内のみ
    if (candidates.isEmpty) {
      await _showAbsenceSavedDialog(
        record.customerName,
        note: '本日、空き枠を埋められる候補のご家庭はありませんでした。',
      );
      return;
    }

    final result = await VacancyNoticeDialog.show(
      context,
      candidates: candidates,
      absentChildName: record.customerName,
    );
    if (!mounted) return;

    // 「送信しない」／ダイアログ破棄 → 何も送らない
    if (!result.shouldSend || result.selected.isEmpty) {
      debugPrint('[AttendanceScreen] vacancy notice cancelled by staff');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('LINE通知は送信しませんでした'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // ── 送信（進捗表示つき）
    setState(() => _isSendingNotice = true);
    final sendResult = await svc.sendNotices(
      date: _selectedDate,
      candidates: result.selected,
      messageOverride: result.message.isEmpty ? null : result.message,
      // Day 13: 欠席者を枠の出所として渡すと、保護者の LINE に
      // 「応募する」ボタン付きで届き、先着1名でその場で確定できる。
      sourceAbsentCustomerId: record.customerId,
    );
    if (!mounted) return;
    setState(() => _isSendingNotice = false);

    await VacancySendResultDialog.show(context, sendResult);
  }

  /// 欠席記録完了の案内（通知を送らなかった場合）
  Future<void> _showAbsenceSavedDialog(
    String customerName, {
    required String note,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
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
        content: SizedBox(
          width: 360,
          child: Column(
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
                  border: Border.all(
                      color: AppColors.warning.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        size: 16, color: AppColors.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        note,
                        style: const TextStyle(fontSize: 11, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
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

    final ok = await _guardRecordOp(
      '${record.customerName} さんの欠席の取り消し',
      () => AttendanceService.instance.resetAbsent(
        customerId: record.customerId,
        date: _selectedDate,
      ),
      retry: () => _doResetAbsent(record),
      customerId: record.customerId,
    );
    if (!ok) return;
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

  /// 欠席の取り消し（確認ダイアログの後・再試行から）
  Future<void> _doResetAbsent(AttendanceRecord record) async {
    final ok = await _guardRecordOp(
      '${record.customerName} さんの欠席の取り消し',
      () => AttendanceService.instance.resetAbsent(
        customerId: record.customerId,
        date: _selectedDate,
      ),
      retry: () => _doResetAbsent(record),
      customerId: record.customerId,
    );
    if (!ok) return;
    _reload();
  }

  // ── 時刻修正 ────────────────────────────────────────────────

  Future<void> _onCheckInChanged(
      AttendanceRecord record, DateTime newTime) async {
    try {
      await AttendanceService.instance.updateCheckInTime(
        customerId: record.customerId,
        date: _selectedDate,
        newTime: newTime,
      );
    } on StaffNotSelectedException {
      return;
    }
    _reload();
  }

  Future<void> _onCheckOutChanged(
      AttendanceRecord record, DateTime newTime) async {
    try {
      await AttendanceService.instance.updateCheckOutTime(
        customerId: record.customerId,
        date: _selectedDate,
        newTime: newTime,
      );
    } on StaffNotSelectedException {
      return;
    }
    _reload();
  }

  // ── UI ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: SkeletonGate(
                loading: _isLoading,
                contentKey: _selectedDate,
                errorMessage: _loadError,
                onRetry: _retryLoad,
                skeleton: LayoutBuilder(
                  builder: (context, c) {
                    final columns = _columnCount(c.maxWidth);
                    return AttendanceSkeleton(
                      columns: columns,
                      aspectRatio: _aspectRatio(columns, c.maxWidth),
                      padding: _gridPadding(c.maxWidth),
                    );
                  },
                ),
                builder: (context) => StaggerScope(
                  child: Column(
                    children: [
                      _buildSummaryBar(),
                      // Day 14: 選択日の LINE 応募状況
                      SlotStatusPanel(
                        slots: _slots,
                        now: DateTime.now(),
                        nameOf: _customerNameOf,
                        error: _slotError,
                      ),
                      Expanded(child: _buildBody()),
                    ],
                  ),
                ),
              ),
            ),
            // Day 11: LINE 通知送信中のオーバーレイ（二重操作をブロック）
            if (_isSendingNotice)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: const Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppSpinner(color: kLineGreen),
                            SizedBox(height: 16),
                            Text('LINE通知を送信中です…',
                                style: TextStyle(fontSize: 13)),
                            SizedBox(height: 4),
                            Text('画面を閉じずにお待ちください',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final wd = weekdays[_selectedDate.weekday - 1];
    final dateStr = '${_selectedDate.month}/${_selectedDate.day}（$wd）';

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(attendanceTitleFor(_selectedDate, DateTime.now())),
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
        // Day 11: LINE 通知の送信履歴
        IconButton(
          icon: const Icon(Icons.chat_bubble_outline),
          tooltip: 'LINE通知の履歴',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const NotificationHistoryScreen(),
            ),
          ),
        ),
        _isPdfGenerating
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: AppSpinner(
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
    final summary = AttendanceService.instance.getTodaySummary(_selectedDate);
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
              inRoomDot: summary.presentCount > 0,
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
    bool inRoomDot = false,
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
          if (inRoomDot)
            _InRoomDotSmall(color: color)
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
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(10),
            ),
            child: AnimatedCount(
              value: count,
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
        final padding = _gridPadding(constraints.maxWidth);
        return GridView.builder(
          padding: EdgeInsets.all(padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _gridSpacing,
            mainAxisSpacing: _gridSpacing,
            mainAxisExtent: _cardExtent,
          ),
          itemCount: _records.length,
          itemBuilder: (ctx, i) => StaggeredItem(
            index: i,
            total: _records.length,
            child: _AttendanceCard(
              record: _records[i],
              busy: _busyIds.contains(_records[i].customerId),
              slotView: _slotViewFor(_records[i]),
              onMarkPresent: () => _markPresent(_records[i]),
              onMarkDeparted: () => _markDeparted(_records[i]),
              onMarkAbsent: () => _showAbsenceDialog(_records[i]),
              onResetAbsent: () => _resetAbsent(_records[i]),
              onCheckInChanged: (t) => _onCheckInChanged(_records[i], t),
              onCheckOutChanged: (t) => _onCheckOutChanged(_records[i], t),
            ),
          ),
        );
      },
    );
  }

  /// カードの縦の長さ（中身に合わせた固定値。幅に比例させると空白が大きくなるため）。
  /// 氏名 + 時刻（または欠席理由と LINE 応募）+ 提供時間 + ボタン（高さ 48）。
  static const double _cardExtent = 176;
  static const double _gridSpacing = 10;

  /// 読み込み中の骨格用（カードと同じ大きさになる比率）
  double _aspectRatio(int columns, double width) {
    final cellWidth =
        (width - _gridPadding(width) * 2 - _gridSpacing * (columns - 1)) / columns;
    return cellWidth / _cardExtent;
  }

  double _gridPadding(double width) => width >= 900 ? 16.0 : 12.0;

  /// 欠席カード用: その児童の枠の表示内容（無ければ null）
  SlotRowView? _slotViewFor(AttendanceRecord r) {
    if (r.status != AttendanceStatus.absent) return null;
    final slot = _slotForAbsent(r.customerId);
    if (slot == null) return null;
    return SlotRowView.from(slot, now: DateTime.now(), nameOf: _customerNameOf);
  }

  Widget _buildEmptyState() {
    return EmptyState(
      icon: Icons.event_busy_outlined,
      title: '本日の利用予定者はいません',
      message: '顧客の定期利用曜日を確認してください',
      actions: [
        AppOutlinedButton.icon(
          icon: const Icon(Icons.calendar_today_outlined, size: 16),
          label: const Text('日付を変更'),
          onPressed: _changeDate,
        ),
      ],
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

  /// Day 14: 欠席カードに出す LINE 応募の状態（枠が無ければ null）
  final SlotRowView? slotView;
  final VoidCallback onMarkPresent;
  final VoidCallback onMarkDeparted;
  final VoidCallback onMarkAbsent;
  final VoidCallback onResetAbsent;
  final Future<void> Function(DateTime) onCheckInChanged;
  final Future<void> Function(DateTime) onCheckOutChanged;

  /// 保存中（応答待ち）。ボタンの代わりに「処理中」を出し、押せなくする
  final bool busy;

  const _AttendanceCard({
    required this.record,
    this.busy = false,
    this.slotView,
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
      duration: AppMotion.scaled(context, AppMotion.normal),
      curve: AppMotion.standard,
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

            const SizedBox(height: 6),

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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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

            // ── Day 14: LINE 応募の状態（欠席カードのみ）
            if (slotView != null) ...[
              const SizedBox(height: 6),
              SlotChip(
                key: const Key('slotChip'),
                view: slotView!,
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
    if (busy) return _busyRow();
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

  /// 保存中: 「処理中…」（ボタンは出さない＝二度押しできない）
  Widget _busyRow() {
    return const SizedBox(
      key: Key('attendanceCardBusy'),
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('処理中…', style: TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  /// scheduled: 「入室」「欠席」
  Widget _scheduledButtons(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 48,
            child: AppElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            height: 48,
            child: AppOutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            height: 48,
            child: AppElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
        Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF546E7A)),
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
      height: 48,
      child: AppOutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.error,
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
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
// 集計バー用の在室中ドット（静止表示）
// ─────────────────────────────────────────────────────────────────────

/// 以前は無限に点滅させていたが、出席画面を開いている間ずっとフレームを
/// 要求し続けるため静止にした。在室中は色と「在室中」の文字で伝わる。
class _InRoomDotSmall extends StatelessWidget {
  final Color color;
  const _InRoomDotSmall({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
