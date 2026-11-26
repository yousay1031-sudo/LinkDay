import 'dart:async';

// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/staff_session.dart';
import '../models/attendance_record.dart';
import '../models/daily_journal.dart';
import '../models/staff.dart';
import '../services/attendance_service.dart';
import '../services/daily_journal_pdf_service.dart';
import '../services/daily_journal_service.dart';
import '../services/settings_service.dart';
import '../services/staff_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion/success_feedback.dart';
import '../widgets/unfocus_offscreen_text_field.dart';

/// 業務日誌（ステップ3）。1 日 1 件。文字を打つのは備考だけ。
///
/// - 今日いた職員: 在籍中の職員を押して選ぶ（日誌がまだ無い日は、勤務日がその
///   曜日に当たる職員を選んだ状態で開く）。
/// - 利用者の入退室時間: 出席の記録から表示するだけ（保存しない）。
/// - その日の内容: 設定の選択肢から押して選ぶ（いくつでも）。
/// - 備考: 自由に書く（空でも保存できる）。
///
/// 「日誌を保存」で保存する。保存していない変更があるまま離れようとしたら確かめる。
/// 他の端末で保存されたとき、入力中の内容があれば消さずに知らせる。
class DailyJournalScreen extends StatefulWidget {
  const DailyJournalScreen({super.key, this.initialDate, this.printer});

  /// 開く日（省略時は今日）
  final DateTime? initialDate;

  /// テスト用: 印刷の代わりに呼ぶ
  final Future<void> Function(JournalPrintData data, DateTime date)? printer;

  @override
  State<DailyJournalScreen> createState() => _DailyJournalScreenState();
}

class _DailyJournalScreenState extends State<DailyJournalScreen> {
  final _svc = DailyJournalService.instance;
  late DateTime _date;
  StreamSubscription<JournalSnapshot>? _sub;

  /// 保存先にある日誌（無ければ null）
  DailyJournal? _saved;

  /// 最初の読み込みが届いたか
  bool _loaded = false;

  /// 入力欄に入れた元の内容（保存していない変更があるかの判定に使う）
  DailyJournal? _applied;

  /// 他の端末で保存されたが、入力中の内容があるため画面に入れていない
  bool _remoteChanged = false;

  List<JournalStaff> _staff = [];
  List<String> _activities = [];
  final _noteCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDate ?? _svc.today;
    _date = DateTime(d.year, d.month, d.day);
    if (_svc.isFuture(_date)) _date = _svc.today;
    _noteCtrl.addListener(_onNoteChanged);
    StaffService.instance.addListener(_onOtherChanged);
    AttendanceService.instance.addListener(_onOtherChanged);
    SettingsService.instance.addListener(_onOtherChanged);
    _open(_date);
  }

  @override
  void dispose() {
    _sub?.cancel();
    StaffService.instance.removeListener(_onOtherChanged);
    AttendanceService.instance.removeListener(_onOtherChanged);
    SettingsService.instance.removeListener(_onOtherChanged);
    _noteCtrl.dispose();
    super.dispose();
  }

  void _onOtherChanged() {
    if (mounted) setState(() {});
  }

  String _lastNote = '';
  void _onNoteChanged() {
    if (_noteCtrl.text == _lastNote) return;
    _lastNote = _noteCtrl.text;
    if (mounted) setState(() {});
  }

  // ── 読み込み ────────────────────────────────────────────────

  void _open(DateTime date) {
    _sub?.cancel();
    setState(() {
      _date = date;
      _loaded = false;
      _saved = null;
      _applied = null;
      _remoteChanged = false;
    });
    unawaited(AttendanceService.instance.ensureDate(date));
    _sub = _svc.watch(date).listen((snap) {
      if (!mounted || snap.staleEcho) return;
      final j = snap.journal;
      final first = !_loaded;
      _saved = j;
      _loaded = true;
      if (first || !_dirty) {
        _apply(j ?? _defaultFor(date));
        _remoteChanged = false;
      } else if (j != null && !_current.sameContent(j)) {
        // 入力中の内容は消さない（保存すると、入力した内容になる）
        _remoteChanged = true;
      } else {
        // 入力した内容と同じになった（自分の保存の折り返しなど）
        _applied = j;
        _remoteChanged = false;
      }
      setState(() {});
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() => _loaded = true);
    });
  }

  DailyJournal _defaultFor(DateTime date) => DailyJournal(
        dateKey: DailyJournal.keyOf(date),
        staff: DailyJournalService.defaultStaffFor(
            date, StaffService.instance.getActiveStaff()),
      );

  void _apply(DailyJournal j) {
    _applied = j;
    _staff = List.of(j.staff);
    _activities = List.of(j.activities);
    _lastNote = j.note;
    _noteCtrl.text = j.note;
  }

  /// 入力欄の内容
  DailyJournal get _current => DailyJournal(
        dateKey: DailyJournal.keyOf(_date),
        staff: _staff,
        activities: _activities,
        note: _noteCtrl.text.trim(),
      );

  /// 保存していない変更があるか
  bool get _dirty {
    final a = _applied;
    if (a == null) return false;
    return !_current.sameContent(a);
  }

  // ── 操作 ────────────────────────────────────────────────────

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存していない変更があります'),
        content: const Text('このまま移ると、入力した内容は消えます。'),
        actions: [
          TextButton(
              key: const Key('journalDiscardCancel'),
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('戻って保存する')),
          TextButton(
              key: const Key('journalDiscardOk'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存せずに移る',
                  style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _goTo(DateTime d) async {
    final day = DateTime(d.year, d.month, d.day);
    if (_svc.isFuture(day) || day == _date) return;
    if (!await _confirmDiscard()) return;
    _open(day);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: _svc.today,
      helpText: '日誌を開く日を選ぶ',
      confirmText: '開く',
      cancelText: 'キャンセル',
    );
    if (picked != null) await _goTo(picked);
  }

  void _toggleStaff(JournalStaff s) {
    setState(() {
      final i = _staff.indexWhere((e) => _sameStaff(e, s));
      if (i >= 0) {
        _staff.removeAt(i);
      } else {
        _staff.add(s);
      }
    });
  }

  static bool _sameStaff(JournalStaff a, JournalStaff b) =>
      a.staffId != null ? a.staffId == b.staffId : a.name == b.name;

  void _toggleActivity(String a) {
    setState(() {
      if (_activities.contains(a)) {
        _activities.remove(a);
      } else {
        _activities.add(a);
      }
    });
  }

  /// 保存する。保存できたら使った担当者の記録を返す
  Future<String?> _save() async {
    if (_saving) return null;
    setState(() => _saving = true);
    try {
      final j = _current;
      final stamp = await _svc.save(j, exists: _saved != null);
      if (!mounted) return stamp.staffName;
      setState(() {
        _applied = j;
        _remoteChanged = false;
      });
      showSuccessSnack(context, '日誌を保存しました');
      return stamp.staffName;
    } on StaffNotSelectedException {
      _snack('担当者を選ぶと保存できます');
    } on JournalFutureDateException {
      _snack('未来の日の日誌は作れません');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    return null;
  }

  void _snack(String m, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _showLatest() {
    final j = _saved;
    if (j == null) return;
    setState(() {
      _apply(j);
      _remoteChanged = false;
    });
  }

  Future<void> _print() async {
    DailyJournal? j = _saved;
    if (_dirty || j == null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('保存してから印刷します'),
          content: const Text('印刷には保存した内容が出ます。いまの内容を保存して印刷しますか。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('やめる')),
            ElevatedButton(
                key: const Key('journalSaveAndPrint'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存して印刷')),
          ],
        ),
      );
      if (ok != true) return;
      final who = await _save();
      if (who == null) return;
      final cur = _current;
      j = DailyJournal(
        dateKey: cur.dateKey,
        staff: cur.staff,
        activities: cur.activities,
        note: cur.note,
        updatedAt: DateTime.now(),
        updatedByStaffName: who,
      );
    }
    final data = JournalPrintData.from(
      journal: j,
      attendance: _attendanceRows(),
      facilityName: SettingsService.instance.getSettings().facilityLabel,
    );
    final printer = widget.printer ?? DailyJournalPdfService.printJournal;
    try {
      await printer(data, _date);
    } catch (e) {
      _snack('印刷の準備ができませんでした（通信を確かめてください）', color: AppColors.error);
    }
  }

  List<JournalAttendanceRow> _attendanceRows() =>
      JournalAttendanceRow.fromRecords(
          AttendanceService.instance.getRecordsByDate(_date));

  // ── 表示 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isToday = _date == _svc.today;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          _applied = _current; // 確かめた後は止めない
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('業務日誌'),
          actions: [
            IconButton(
              key: const Key('journalPrint'),
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              tooltip: '印刷',
              icon: const Icon(Icons.print_outlined),
              onPressed: _loaded ? _print : null,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            _dateBar(isToday),
            if (_remoteChanged) _remoteBanner(),
            Expanded(
              child: !_loaded
                  ? const Center(child: CircularProgressIndicator())
                  : UnfocusOffscreenTextField(
                      child: LayoutBuilder(builder: (context, c) {
                        // 広い幅は 2 列（左: 入力する欄、右: 見るだけの入退室）。
                        // 狭い幅は 1 列で、入退室（利用者が多いと長い・見るだけ）を最後に置く
                        final wide = c.maxWidth >= 1000;
                        final inputs = [
                          _staffSection(),
                          const SizedBox(height: 12),
                          _activitySection(),
                          const SizedBox(height: 12),
                          _noteSection(),
                        ];
                        return SingleChildScrollView(
                          key: const Key('journalScroll'),
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          child: Center(
                            child: ConstrainedBox(
                              constraints:
                                  BoxConstraints(maxWidth: wide ? 1400 : 960),
                              child: wide
                                  ? Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: inputs,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                            flex: 2,
                                            child: _attendanceSection()),
                                      ],
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        ...inputs,
                                        const SizedBox(height: 12),
                                        _attendanceSection(),
                                      ],
                                    ),
                            ),
                          ),
                        );
                      }),
                    ),
            ),
          ],
        ),
        // 保存のボタンは画面の下に固定する（利用者が多くても探さずに押せる）
        bottomNavigationBar: _loaded ? _footer() : null,
      ),
    );
  }

  Widget _dateBar(bool isToday) {
    return Material(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              key: const Key('journalPrevDay'),
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              tooltip: '前の日',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _goTo(_date.subtract(const Duration(days: 1))),
            ),
            Expanded(
              child: TextButton.icon(
                key: const Key('journalPickDate'),
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(
                  '${JournalPrintData.dateJp(_date)}${isToday ? '　今日' : ''}',
                  key: const Key('journalDateLabel'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            IconButton(
              key: const Key('journalNextDay'),
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              tooltip: isToday ? '未来の日の日誌は作れません' : '次の日',
              icon: const Icon(Icons.chevron_right),
              onPressed: isToday
                  ? null
                  : () => _goTo(_date.add(const Duration(days: 1))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _remoteBanner() {
    return Container(
      key: const Key('journalRemoteBanner'),
      width: double.infinity,
      color: AppColors.warning.withValues(alpha: 0.15),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.warning, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '他の端末でこの日の日誌が保存されました。入力中の内容は消していません'
              '（保存すると、入力した内容になります）。',
              style: TextStyle(fontSize: 13),
            ),
          ),
          TextButton(
            key: const Key('journalShowLatest'),
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _showLatest,
            child: const Text('保存された内容を表示'),
          ),
        ],
      ),
    );
  }

  Widget _card(String title, Widget child, {String? note, Key? key}) {
    return Card(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            if (note != null) ...[
              const SizedBox(height: 2),
              Text(note,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.onSurfaceVariant)),
            ],
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  Widget _chip({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    // 見た目の高さも押せる範囲も 48（見た目より押せる範囲が広いと分かりにくいため）
    return SizedBox(
      height: 48,
      child: FilterChip(
        key: key,
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        labelStyle: const TextStyle(fontSize: 14),
      ),
    );
  }

  Widget _staffSection() {
    final active = StaffService.instance.getActiveStaff();
    final chips = <Widget>[
      for (final Staff s in active)
        _chip(
          key: Key('journalStaff_${s.id}'),
          label: s.name,
          selected: _staff.any((e) => e.staffId == s.id),
          onTap: () => _toggleStaff(JournalStaff(staffId: s.id, name: s.name)),
        ),
      // 在籍終了などで一覧にいない人（その日の日誌に残っている名前）
      for (final e in _staff)
        if (e.staffId == null || !active.any((s) => s.id == e.staffId))
          _chip(
            key: Key('journalStaffGone_${e.staffId ?? e.name}'),
            label: '${e.name}（在籍終了）',
            selected: true,
            onTap: () => _toggleStaff(e),
          ),
    ];
    return _card(
      '今日いた職員',
      chips.isEmpty
          ? const Text('在籍中の職員がいません（職員管理で登録できます）')
          : Wrap(spacing: 8, runSpacing: 8, children: chips),
      note: _saved == null
          ? '勤務日がこの曜日に当たる職員を選んであります。押すと選ぶ・外すが変わります。'
          : '押すと選ぶ・外すが変わります。',
      key: const Key('journalStaffSection'),
    );
  }

  Widget _attendanceSection() {
    final rows = _attendanceRows();
    return _card(
      '利用者の入退室時間',
      rows.isEmpty
          ? const Text('この日の出席の記録はありません',
              style: TextStyle(color: AppColors.onSurfaceVariant))
          : Column(
              children: [
                for (final r in rows)
                  // 1 人ずつ読み上げられるように、行ごとにまとめる
                  MergeSemantics(
                      child: Container(
                    key: Key('journalAttendance_${r.customerId}'),
                    constraints: const BoxConstraints(minHeight: 40),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: const BoxDecoration(
                      border:
                          Border(bottom: BorderSide(color: Color(0x14000000))),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14)),
                        ),
                        Expanded(
                          flex: 4,
                          child: Text(
                            _rowText(r),
                            key: Key('journalAttendanceText_${r.customerId}'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: switch (r.status) {
                                AttendanceStatus.absent => AppColors.error,
                                AttendanceStatus.present => AppColors.secondary,
                                _ => AppColors.onSurface,
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  )),
              ],
            ),
      note: '出席管理の記録から表示しています（ここでは直せません。出席管理で直すと、ここと印刷にも反映されます）。',
      key: const Key('journalAttendanceSection'),
    );
  }

  static String _rowText(JournalAttendanceRow r) => switch (r.status) {
        AttendanceStatus.present => '入室 ${r.inText}　在室中',
        AttendanceStatus.departed => '入室 ${r.inText}　退室 ${r.outText}',
        _ => r.statusText,
      };

  Widget _activitySection() {
    final options =
        SettingsService.instance.getSettings().journalActivityOptions;
    final chips = <Widget>[
      for (final a in options)
        _chip(
          key: Key('journalActivity_$a'),
          label: a,
          selected: _activities.contains(a),
          onTap: () => _toggleActivity(a),
        ),
      // 設定から消した選択肢（この日の日誌に残っている名前）
      for (final a in _activities)
        if (!options.contains(a))
          _chip(
            key: Key('journalActivity_$a'),
            label: a,
            selected: true,
            onTap: () => _toggleActivity(a),
          ),
    ];
    return _card(
      'その日の内容',
      chips.isEmpty
          ? const Text('選択肢がありません（設定の「業務日誌の内容の選択肢」で足せます）')
          : Wrap(spacing: 8, runSpacing: 8, children: chips),
      note: 'いくつでも選べます。選択肢は設定で足したり減らしたりできます。',
      key: const Key('journalActivitySection'),
    );
  }

  Widget _noteSection() {
    return _card(
      '備考',
      TextField(
        key: const Key('journalNote'),
        controller: _noteCtrl,
        minLines: 3,
        maxLines: 8,
        maxLength: DailyJournal.maxNoteLength,
        decoration: const InputDecoration(
          hintText: '空欄でも保存できます',
          border: OutlineInputBorder(),
        ),
      ),
      key: const Key('journalNoteSection'),
    );
  }

  Widget _footer() {
    final s = _saved;
    final who = s?.updatedByStaffName;
    final at = s?.updatedAt;
    final canSave = !_saving && (_dirty || _saved == null);
    final staffName = StaffSession.instance.current?.name;
    return Material(
      key: const Key('journalFooter'),
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
              Text(
                s == null
                    ? 'この日の日誌はまだ保存されていません'
                    : '記入者：${who ?? '—'}'
                        '${at == null ? '' : '（${at.month}/${at.day} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}）'}',
                key: const Key('journalWriter'),
                style: const TextStyle(
                    fontSize: 13, color: AppColors.onSurfaceVariant),
              ),
              if (_dirty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('保存していない変更があります',
                      key: Key('journalDirty'),
                      style: TextStyle(fontSize: 13, color: AppColors.warning)),
                ),
              const SizedBox(height: 6),
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  key: const Key('journalSave'),
                  onPressed: canSave ? _save : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save),
                  label: Text(staffName == null ? '日誌を保存（担当者を選びます）' : '日誌を保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
