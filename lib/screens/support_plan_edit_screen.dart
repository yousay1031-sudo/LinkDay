// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/staff_session.dart';
import '../models/staff.dart';
import '../models/support_plan.dart';
import '../models/support_plan_form.dart';
import '../services/settings_service.dart';
import '../services/staff_service.dart';
import '../services/support_plan_pdf_service.dart';
import '../services/support_plan_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion/success_feedback.dart';
import '../widgets/unfocus_offscreen_text_field.dart';

/// 支援の表の 1 行の入力欄
class _RowEdit {
  _RowEdit(SupportPlanRow r)
      : categories = [...r.categories],
        domains = [...r.domains],
        staff = [...r.staff],
        priority = r.priority,
        extraTexts = {
          for (final e in r.texts.entries)
            if (!_keys.contains(e.key)) e.key: e.value
        } {
    for (final k in _keys) {
      ctrls[k] = TextEditingController(text: r.text(k));
    }
  }

  static const _keys = [
    SupportPlanForm.rGoal,
    SupportPlanForm.rContent,
    SupportPlanForm.rPeriod,
    SupportPlanForm.rProvider,
    SupportPlanForm.rNotes,
  ];

  /// 画面の中で行を見分ける（並べ替えても入力欄を取り違えない）
  final Key key = UniqueKey();
  List<String> categories;
  List<String> domains;
  List<PlanStaff> staff;
  int? priority;
  final Map<String, TextEditingController> ctrls = {};
  final TextEditingController staffNameCtrl = TextEditingController();

  /// 様式の一覧から外した項目の値（消さずに残す）
  final Map<String, String> extraTexts;

  bool get usesDomains => categories
      .any((c) => SupportPlanForm.categoryOf(c)?.usesDomains ?? false);

  SupportPlanRow toRow() => SupportPlanRow(
        categories: [
          for (final c in SupportPlanForm.categories)
            if (categories.contains(c.code)) c.code,
          for (final c in categories)
            if (SupportPlanForm.categoryOf(c) == null) c,
        ],
        texts: {
          ...extraTexts,
          for (final k in _keys)
            if (ctrls[k]!.text.trim().isNotEmpty) k: ctrls[k]!.text.trim(),
        },
        // 5 領域・優先順位は本人支援の行だけ
        domains: usesDomains
            ? [
                for (final d in SupportPlanForm.domains)
                  if (domains.contains(d.code)) d.code
              ]
            : const [],
        staff: staff,
        priority: usesDomains ? priority : null,
      );

  void dispose() {
    for (final c in ctrls.values) {
      c.dispose();
    }
    staffNameCtrl.dispose();
  }
}

/// 同意済みの計画を直すときのしかた
enum _AgreedEdit { light, revert }

/// 個別支援計画の入力（ステップ3）。参考様式の並び（基本 → 方針 → 支援の表 → 同意）。
///
/// - 足りない点（本人支援・家族支援・移行支援の行など）は上にまとめて出す。足りないまま
///   「作成中」で保存できるが、同意を得た日は入れられない。
/// - 本人支援の行全体で選ばれていない 5 領域があれば、同意を得た日を入れる前に確かめる。
/// - 同意済みの計画は、そのままでは書き換えられない。「編集する」で、軽い修正（同意済みの
///   まま）か内容を変える（作成中に戻す）かを選ぶ。
class SupportPlanEditScreen extends StatefulWidget {
  const SupportPlanEditScreen({
    super.key,
    required this.plan,
    required this.isNew,
    this.today,
    this.printer,
  });

  final SupportPlan plan;
  final bool isNew;

  /// テスト用: 今日を差し替える
  final DateTime? today;

  /// テスト用: 印刷の代わりに呼ぶ
  final Future<void> Function(PlanPrintData data, SupportPlan plan)? printer;

  @override
  State<SupportPlanEditScreen> createState() => _SupportPlanEditScreenState();
}

class _SupportPlanEditScreenState extends State<SupportPlanEditScreen> {
  final _svc = SupportPlanService.instance;

  /// 保存先にある内容（新しい計画は保存するまで null）
  SupportPlan? _saved;

  /// 入力欄に入れた元の内容（保存していない変更があるかの判定に使う）
  late SupportPlan _base;
  bool _isNew = false;

  // 入力欄
  DateTime? _createdOn;
  String? _managerId;
  String _managerName = '';
  final Map<String, TextEditingController> _texts = {};
  Map<String, String> _extraTexts = {};
  List<_RowEdit> _rows = [];
  DateTime? _explainedOn;
  DateTime? _agreedOn;

  /// 同意済みの計画を直しているときのしかた（null = まだ直していない）
  _AgreedEdit? _agreedEdit;
  bool _remoteChanged = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _isNew = widget.isNew;
    _saved = _isNew ? null : (_svc.getById(widget.plan.id) ?? widget.plan);
    _load(_saved ?? widget.plan);
    _svc.addListener(_onPlansChanged);
    StaffService.instance.addListener(_onOther);
  }

  @override
  void dispose() {
    _svc.removeListener(_onPlansChanged);
    StaffService.instance.removeListener(_onOther);
    for (final c in _texts.values) {
      c.dispose();
    }
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _onOther() {
    if (mounted) setState(() {});
  }

  DateTime get _today {
    final n = widget.today ?? DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  void _load(SupportPlan p) {
    _base = p;
    _createdOn = p.createdOn;
    _managerId = p.managerStaffId;
    _managerName = p.managerName;
    for (final f in SupportPlanForm.policyFields) {
      (_texts[f.key] ??= TextEditingController()).text = p.text(f.key);
    }
    _extraTexts = {
      for (final e in p.texts.entries)
        if (!SupportPlanForm.policyFields.any((f) => f.key == e.key))
          e.key: e.value
    };
    for (final r in _rows) {
      r.dispose();
    }
    _rows = [for (final r in p.rows) _RowEdit(r)];
    _explainedOn = p.explainedOn;
    _agreedOn = p.agreedOn;
  }

  /// 入力欄の内容
  SupportPlan get _current => _base.copyWith(
        createdOn: () => _createdOn,
        managerStaffId: () => _managerId,
        managerName: _managerName,
        texts: {
          ..._extraTexts,
          for (final f in SupportPlanForm.policyFields)
            if (_texts[f.key]!.text.trim().isNotEmpty)
              f.key: _texts[f.key]!.text.trim(),
        },
        rows: [for (final r in _rows) r.toRow()],
        explainedOn: () => _explainedOn,
        agreedOn: () => _agreedOn,
        status: _agreedOn != null ? PlanStatus.agreed : PlanStatus.draft,
      );

  bool get _dirty => !_current.sameContent(_base);

  /// 同意済みで、まだ「編集する」を選んでいない（見るだけ）
  bool get _locked => (_saved?.isAgreed ?? false) && _agreedEdit == null;

  void _onPlansChanged() {
    if (!mounted || _isNew) return;
    final latest = _svc.getById(_base.id);
    if (latest == null) return;
    final wasSaved = _saved;
    _saved = latest;
    if (latest.sameContent(_current)) {
      // 自分の保存の反映など
      _base = latest;
      setState(() => _remoteChanged = false);
      return;
    }
    if (!_dirty && wasSaved != null && !latest.sameContent(wasSaved)) {
      setState(() {
        _load(latest);
        if (!latest.isAgreed) _agreedEdit = null;
      });
      return;
    }
    if (_dirty) setState(() => _remoteChanged = true);
  }

  void _showLatest() {
    final s = _saved;
    if (s == null) return;
    setState(() {
      _load(s);
      _agreedEdit = null;
      _remoteChanged = false;
    });
  }

  // ── 操作 ────────────────────────────────────────────────────

  void _snack(String m, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating));
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存していない変更があります'),
        content: const Text('このまま閉じると、入力した内容は消えます。'),
        actions: [
          TextButton(
              key: const Key('planDiscardCancel'),
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('戻って保存する')),
          TextButton(
              key: const Key('planDiscardOk'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存せずに閉じる',
                  style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    return ok == true;
  }

  /// 同意済みの計画の「編集する」
  Future<void> _startAgreedEdit() async {
    final choice = await showDialog<_AgreedEdit>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('同意済みの計画を直します'),
        content: const Text('保護者の同意を得た計画です。直し方を選んでください。\n\n'
            '・軽い修正：誤字などを直します。同意済みのまま、「同意後に修正した日時と担当者」を'
            '記録し、計画の画面と一覧に「同意後に修正あり」と出します。\n'
            '・内容を変える：作成中に戻し、説明した日と同意を得た日を空にします。'
            'もう一度説明して同意を得てください。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('やめる')),
          TextButton(
              key: const Key('planEditRevert'),
              onPressed: () => Navigator.pop(ctx, _AgreedEdit.revert),
              child: const Text('内容を変える（作成中に戻す）')),
          ElevatedButton(
              key: const Key('planEditLight'),
              onPressed: () => Navigator.pop(ctx, _AgreedEdit.light),
              child: const Text('軽い修正（同意済みのまま）')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      _agreedEdit = choice;
      if (choice == _AgreedEdit.revert) {
        _explainedOn = null;
        _agreedOn = null;
      }
    });
  }

  Future<DateTime?> _pick(DateTime? initial, String help) => showDatePicker(
        context: context,
        initialDate: initial ?? _today,
        firstDate: DateTime(2015),
        lastDate: DateTime(_today.year + 2, 12, 31),
        helpText: help,
        confirmText: '決定',
        cancelText: 'キャンセル',
      );

  Future<void> _pickAgreedOn() async {
    final check = PlanCheck.of(_current.copyWith(agreedOn: () => null));
    if (!check.canAgree || _explainedOn == null) return;
    final d =
        await _pick(_agreedOn ?? _explainedOn, SupportPlanForm.agreedOnLabel);
    if (d == null || !mounted) return;
    final probe = PlanCheck.of(_current.copyWith(agreedOn: () => d));
    if (!probe.canAgree) {
      _snack(probe.blockers.join('\n'), color: AppColors.error);
      return;
    }
    if (probe.missingDomains.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('5領域のうち選ばれていない領域があります'),
          content: Text('本人支援の行全体で、次の領域が選ばれていません。\n\n'
              '${probe.missingDomains.map((d) => '・$d').join('\n')}\n\n'
              '記載のポイントでは、5つの領域すべてとの関連を書くこととされています。'
              'このまま同意済みにしますか。'),
          actions: [
            TextButton(
                key: const Key('planDomainsBack'),
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('戻って直す')),
            ElevatedButton(
                key: const Key('planDomainsOk'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('このまま同意済みにする')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _agreedOn = d);
  }

  Future<void> _save() async {
    if (_saving) return;
    final mode = switch (_agreedEdit) {
      _AgreedEdit.light => PlanSaveMode.lightRevision,
      _AgreedEdit.revert => PlanSaveMode.revertToDraft,
      null => PlanSaveMode.normal,
    };
    setState(() => _saving = true);
    try {
      final p = _current;
      await _svc.save(p, exists: !_isNew, mode: mode);
      if (!mounted) return;
      final stored = _svc.getById(p.id) ?? p;
      setState(() {
        _isNew = false;
        _saved = stored;
        _load(stored);
        // 内容を変えた計画は作成中になったので、ここからは普通に直せる
        _agreedEdit = null;
        _remoteChanged = false;
      });
      showSuccessSnack(
          context, stored.isAgreed ? '保存しました（同意済み）' : '保存しました（作成中）');
    } on StaffNotSelectedException {
      _snack('担当者を選ぶと保存できます');
    } on PlanCannotAgreeException catch (e) {
      _snack('同意済みにできません：${e.blockers.join('／')}', color: AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 印刷（保存した内容を印刷する。保存していない変更があれば先に保存するか確かめる）
  Future<void> _print() async {
    if (_dirty || _isNew) {
      if (_locked) return;
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
                key: const Key('planSaveAndPrint'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存して印刷')),
          ],
        ),
      );
      if (ok != true) return;
      await _save();
      if (!mounted || _dirty || _isNew) return; // 保存できなかった
    }
    final p = _saved ?? _current;
    final printer = widget.printer ?? SupportPlanPdfService.printPlan;
    try {
      await printer(PlanPrintData.from(p), p);
    } catch (e) {
      _snack('印刷の準備ができませんでした（通信を確かめてください）', color: AppColors.error);
    }
  }

  Future<void> _removeRow(_RowEdit r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('この行を消しますか'),
        content: const Text('保存するまでは、閉じれば元に戻ります。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('やめる')),
          ElevatedButton(
              key: const Key('planRowRemoveOk'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('消す')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _rows.remove(r);
      r.dispose();
    });
  }

  void _addRow() {
    setState(() => _rows.add(_RowEdit(SupportPlanRow(texts: {
          SupportPlanForm.rProvider:
              SettingsService.instance.getSettings().facilityName.trim(),
        }))));
  }

  void _moveRow(int i, int d) {
    final j = i + d;
    if (j < 0 || j >= _rows.length) return;
    setState(() {
      final r = _rows.removeAt(i);
      _rows.insert(j, r);
    });
  }

  // ── 表示 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    final check = PlanCheck.of(cur.copyWith(agreedOn: () => null));
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          _base = _current; // 確かめた後は止めない
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${cur.customerName}さん 個別支援計画'),
          actions: [
            IconButton(
              key: const Key('planPrint'),
              tooltip: '印刷',
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.print_outlined),
              onPressed: _saving ? null : _print,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            if (_locked) _lockedBanner(),
            if (_agreedEdit != null) _editModeBanner(),
            if (_remoteChanged) _remoteBanner(),
            Expanded(
              child: UnfocusOffscreenTextField(
                child: SingleChildScrollView(
                  key: const Key('planScroll'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _checkPanel(check),
                          _basicSection(cur),
                          const SizedBox(height: 12),
                          _policySection(),
                          const SizedBox(height: 12),
                          _tableSection(),
                          const SizedBox(height: 12),
                          _consentSection(check),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: _footer(cur),
      ),
    );
  }

  Widget _banner(Key key, Color color, IconData icon, String text,
      {String? action, VoidCallback? onAction, Key? actionKey}) {
    return Container(
      key: key,
      width: double.infinity,
      color: color.withValues(alpha: 0.13),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          if (action != null)
            TextButton(
              key: actionKey,
              style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: onAction,
              child: Text(action),
            ),
        ],
      ),
    );
  }

  Widget _lockedBanner() {
    final s = _saved!;
    return _banner(
      const Key('planLockedBanner'),
      AppColors.secondary,
      Icons.verified_outlined,
      '同意済みの計画です（同意を得た日 ${_ymd(s.agreedOn)}）。誤って書き換えないよう、'
      '直すときは「編集する」を押してください。'
      '${s.revisedAfterAgreement ? '\n同意後に修正あり（${_ymdhm(s.revisedAfterAgreementAt)}・${s.revisedAfterAgreementByStaffName ?? '—'}）' : ''}',
      action: '編集する',
      actionKey: const Key('planStartEdit'),
      onAction: _startAgreedEdit,
    );
  }

  Widget _editModeBanner() => _banner(
        const Key('planEditModeBanner'),
        AppColors.warning,
        Icons.edit_note,
        _agreedEdit == _AgreedEdit.light
            ? '軽い修正をしています。保存すると同意済みのまま、同意後に修正した日時と担当者を記録します。'
            : '内容を変えています。保存すると作成中に戻り、説明した日・同意を得た日は空になります。',
      );

  Widget _remoteBanner() => _banner(
        const Key('planRemoteBanner'),
        AppColors.warning,
        Icons.info_outline,
        '他の端末でこの計画が保存されました。入力中の内容は消していません（保存すると、入力した内容になります）。',
        action: '保存された内容を表示',
        actionKey: const Key('planShowLatest'),
        onAction: _showLatest,
      );

  static String _ymd(DateTime? d) =>
      d == null ? '未入力' : '${d.year}年${d.month}月${d.day}日';

  static String _ymdhm(DateTime? d) => d == null
      ? '—'
      : '${d.year}/${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// 生年月日と、作成年月日の時点の年齢（例: 2019年4月30日生：5歳0か月）
  static String birthLabel(DateTime? birthday, DateTime? at) {
    if (birthday == null) return '生年月日：未登録';
    final b = '${birthday.year}年${birthday.month}月${birthday.day}日生';
    if (at == null) return b;
    var months = (at.year - birthday.year) * 12 + at.month - birthday.month;
    if (at.day < birthday.day) months--;
    if (months < 0) return b;
    return '$b：${months ~/ 12}歳${months % 12}か月';
  }

  Widget _section(String title, Widget child, {Key? key, String? note}) => Card(
        key: key,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              if (note != null) ...[
                const SizedBox(height: 2),
                Text(note,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.onSurfaceVariant)),
              ],
              const SizedBox(height: 10),
              child,
            ],
          ),
        ),
      );

  Widget _checkPanel(PlanCheck check) {
    if (check.canAgree && check.missingDomains.isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      key: const Key('planCheckPanel'),
      color: check.canAgree ? null : AppColors.warning.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!check.canAgree) ...[
              const Text('足りない点（このままでも「作成中」で保存できます。同意済みにはできません）',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              for (final b in check.blockers)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('・$b', key: Key('planBlocker_$b')),
                ),
            ],
            if (check.missingDomains.isNotEmpty) ...[
              if (!check.canAgree) const SizedBox(height: 8),
              Text(
                '本人支援の行全体で選ばれていない5領域：${check.missingDomains.join('、')}'
                '（同意済みにする前に確かめます）',
                key: const Key('planMissingDomains'),
                style: const TextStyle(
                    fontSize: 13, color: AppColors.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _basicSection(SupportPlan cur) {
    final staff = StaffService.instance.getActiveStaff();
    final managers = [
      ...staff.where((s) => s.role == StaffRole.childDevManager),
      ...staff.where((s) => s.role != StaffRole.childDevManager),
    ];
    final selectedGone =
        _managerId != null && !managers.any((s) => s.id == _managerId);
    return _section(
      '基本',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${SupportPlanForm.childNameLabel}：${cur.customerName}',
              style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 2),
          Text(birthLabel(cur.birthday, _createdOn),
              key: const Key('planBirth'),
              style: const TextStyle(color: AppColors.onSurfaceVariant)),
          const SizedBox(height: 10),
          _dateField(
            key: const Key('planCreatedOn'),
            label: SupportPlanForm.createdOnLabel,
            value: _createdOn,
            note: '更新期限（6か月後）の起点になります',
            onTap: _locked || _agreedEdit == _AgreedEdit.light
                ? null
                : () async {
                    final d =
                        await _pick(_createdOn, SupportPlanForm.createdOnLabel);
                    if (d != null) setState(() => _createdOn = d);
                  },
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: const Key('planManager'),
            initialValue:
                managers.any((s) => s.id == _managerId) || selectedGone
                    ? _managerId
                    : null,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: SupportPlanForm.managerLabel,
                border: OutlineInputBorder()),
            items: [
              for (final Staff s in managers)
                DropdownMenuItem(
                  value: s.id,
                  child: Text(s.role == StaffRole.childDevManager
                      ? '${s.name}（${StaffRole.childDevManager.label}）'
                      : s.name),
                ),
              if (selectedGone)
                DropdownMenuItem(
                    value: _managerId, child: Text('$_managerName（在籍終了）')),
            ],
            onChanged: _locked
                ? null
                : (id) {
                    final s = staff.where((e) => e.id == id).firstOrNull;
                    setState(() {
                      _managerId = id;
                      _managerName = s?.name ?? _managerName;
                    });
                  },
          ),
        ],
      ),
      key: const Key('planBasicSection'),
    );
  }

  Widget _dateField({
    required Key key,
    required String label,
    required DateTime? value,
    required VoidCallback? onTap,
    String? note,
  }) {
    return InkWell(
      key: key,
      onTap: onTap,
      child: InputDecorator(
        isEmpty: value == null,
        decoration: InputDecoration(
          labelText: label,
          helperText: note,
          enabled: onTap != null,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_today, size: 18),
        ),
        child: Text(value == null ? '' : _ymd(value),
            style: const TextStyle(fontSize: 15)),
      ),
    );
  }

  Widget _policySection() {
    return _section(
      '方針',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in SupportPlanForm.policyFields) ...[
            TextField(
              key: Key('planText_${f.key}'),
              controller: _texts[f.key],
              enabled: !_locked,
              minLines: f.key == SupportPlanForm.kStandardTime ? 1 : 2,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: f.label,
                helperText: f.hint,
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
      key: const Key('planPolicySection'),
    );
  }

  Widget _tableSection() {
    return _section(
      SupportPlanForm.tableTitle,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _rows.length; i++) ...[
            _rowCard(i, _rows[i]),
            const SizedBox(height: 10),
          ],
          if (!_locked)
            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                key: const Key('planAddRow'),
                onPressed: _addRow,
                icon: const Icon(Icons.add),
                label: const Text('行を足す'),
              ),
            ),
        ],
      ),
      note: '本人支援・家族支援・移行支援は必ず 1 行以上。地域支援・地域連携は必要に応じて。'
          '1 つの行に項目を併記できます。',
      key: const Key('planTableSection'),
    );
  }

  Widget _chip(
      {required Key key,
      required String label,
      required bool selected,
      required ValueChanged<bool>? onSelected}) {
    return SizedBox(
      height: 48,
      child: FilterChip(
        key: key,
        label: Text(label),
        selected: selected,
        onSelected: onSelected,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(t,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      );

  Widget _rowCard(int i, _RowEdit r) {
    final enabled = !_locked;
    void touch(VoidCallback f) => setState(f);
    final staffList = StaffService.instance.getActiveStaff();
    final period = r.ctrls[SupportPlanForm.rPeriod]!;
    return Container(
      key: Key('planRow_$i'),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0x22000000)),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('${i + 1} 行目',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (enabled) ...[
                IconButton(
                    tooltip: '上へ',
                    onPressed: i == 0 ? null : () => _moveRow(i, -1),
                    icon: const Icon(Icons.arrow_upward, size: 20)),
                IconButton(
                    tooltip: '下へ',
                    onPressed:
                        i == _rows.length - 1 ? null : () => _moveRow(i, 1),
                    icon: const Icon(Icons.arrow_downward, size: 20)),
                IconButton(
                    key: Key('planRowRemove_$i'),
                    tooltip: 'この行を消す',
                    onPressed: () => _removeRow(r),
                    icon: const Icon(Icons.delete_outline,
                        size: 20, color: AppColors.error)),
              ],
            ],
          ),
          _label('項目'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in SupportPlanForm.categories)
              _chip(
                key: Key('planRow_${i}_cat_${c.code}'),
                label: c.label,
                selected: r.categories.contains(c.code),
                onSelected: !enabled
                    ? null
                    : (v) => touch(() => v
                        ? r.categories.add(c.code)
                        : r.categories.remove(c.code)),
              ),
          ]),
          const SizedBox(height: 8),
          for (final (k, label, lines) in [
            (SupportPlanForm.rGoal, SupportPlanForm.goalLabel, 2),
            (SupportPlanForm.rContent, SupportPlanForm.contentLabel, 3),
          ]) ...[
            const SizedBox(height: 8),
            TextField(
              key: Key('planRow_${i}_$k'),
              controller: r.ctrls[k],
              enabled: enabled,
              minLines: lines,
              maxLines: 10,
              decoration: InputDecoration(
                  labelText: label,
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true),
              onChanged: (_) => setState(() {}),
            ),
          ],
          if (r.usesDomains) ...[
            _label('${SupportPlanForm.domainsLabel}（本人支援の行。いくつでも選べます）'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final d in SupportPlanForm.domains)
                _chip(
                  key: Key('planRow_${i}_dom_${d.code}'),
                  label: d.label,
                  selected: r.domains.contains(d.code),
                  onSelected: !enabled
                      ? null
                      : (v) => touch(() =>
                          v ? r.domains.add(d.code) : r.domains.remove(d.code)),
                ),
            ]),
          ],
          _label(SupportPlanForm.periodLabel),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final p in SupportPlanForm.periodChoices)
                _chip(
                  key: Key('planRow_${i}_period_$p'),
                  label: p,
                  selected: period.text.trim() == p,
                  onSelected: !enabled
                      ? null
                      : (v) => touch(() => period.text = v ? p : ''),
                ),
              SizedBox(
                width: 200,
                child: TextField(
                  key: Key('planRow_${i}_period'),
                  controller: period,
                  enabled: enabled,
                  decoration: const InputDecoration(
                      labelText: 'または自由に書く', isDense: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          _label(SupportPlanForm.staffLabel),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final Staff s in staffList)
              _chip(
                key: Key('planRow_${i}_staff_${s.id}'),
                label: s.name,
                selected: r.staff.any((e) => e.staffId == s.id),
                onSelected: !enabled
                    ? null
                    : (v) => touch(() => v
                        ? r.staff.add(PlanStaff(staffId: s.id, name: s.name))
                        : r.staff.removeWhere((e) => e.staffId == s.id)),
              ),
            for (final e in r.staff)
              if (e.staffId == null || !staffList.any((s) => s.id == e.staffId))
                _chip(
                  key: Key('planRow_${i}_staffFree_${e.name}'),
                  label: e.staffId == null ? e.name : '${e.name}（在籍終了）',
                  selected: true,
                  onSelected:
                      !enabled ? null : (_) => touch(() => r.staff.remove(e)),
                ),
          ]),
          if (enabled)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    key: Key('planRow_${i}_staffName'),
                    controller: r.staffNameCtrl,
                    decoration: const InputDecoration(
                        labelText: '職員以外の担当者を書いて足す（例：連携先の担当の方）', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    key: Key('planRow_${i}_staffAdd'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(64, 48)),
                    onPressed: () {
                      final n = r.staffNameCtrl.text.trim();
                      if (n.isEmpty) return;
                      touch(() {
                        if (!r.staff.any((e) => e.name == n)) {
                          r.staff.add(PlanStaff(name: n));
                        }
                        r.staffNameCtrl.clear();
                      });
                    },
                    child: const Text('足す'),
                  ),
                ),
              ]),
            ),
          const SizedBox(height: 10),
          TextField(
            key: Key('planRow_${i}_${SupportPlanForm.rProvider}'),
            controller: r.ctrls[SupportPlanForm.rProvider],
            enabled: enabled,
            decoration: const InputDecoration(
                labelText: SupportPlanForm.providerLabel,
                border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          TextField(
            key: Key('planRow_${i}_${SupportPlanForm.rNotes}'),
            controller: r.ctrls[SupportPlanForm.rNotes],
            enabled: enabled,
            minLines: 1,
            maxLines: 6,
            decoration: const InputDecoration(
                labelText: SupportPlanForm.notesLabel,
                border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          if (r.usesDomains) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<int?>(
              key: Key('planRow_${i}_priority'),
              initialValue: r.priority,
              decoration: const InputDecoration(
                  labelText: '${SupportPlanForm.priorityLabel}（本人支援の行）',
                  border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('なし')),
                for (final n in SupportPlanForm.priorityChoices)
                  DropdownMenuItem<int?>(value: n, child: Text('$n')),
              ],
              onChanged: !enabled ? null : (v) => touch(() => r.priority = v),
            ),
          ],
        ],
      ),
    );
  }

  Widget _consentSection(PlanCheck check) {
    final datesLocked = _locked || _agreedEdit != null;
    final canPickAgreed =
        !datesLocked && check.canAgree && _explainedOn != null;
    final reason = datesLocked
        ? (_agreedEdit == _AgreedEdit.light
            ? '軽い修正では、説明した日・同意を得た日は変えられません'
            : _agreedEdit == _AgreedEdit.revert
                ? '作成中に戻して保存した後に、もう一度入れられます'
                : null)
        : !check.canAgree
            ? '足りない点があるため、同意を得た日は入れられません'
            : _explainedOn == null
                ? '先に説明した日を入れてください'
                : null;
    return _section(
      '説明と同意',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: _dateField(
                key: const Key('planExplainedOn'),
                label: SupportPlanForm.explainedOnLabel,
                value: _explainedOn,
                onTap: datesLocked
                    ? null
                    : () async {
                        final d = await _pick(
                            _explainedOn, SupportPlanForm.explainedOnLabel);
                        if (d != null) setState(() => _explainedOn = d);
                      },
              ),
            ),
            if (!datesLocked && _explainedOn != null && _agreedOn == null)
              IconButton(
                  tooltip: '説明した日を空にする',
                  onPressed: () => setState(() => _explainedOn = null),
                  icon: const Icon(Icons.clear)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _dateField(
                key: const Key('planAgreedOn'),
                label: SupportPlanForm.agreedOnLabel,
                value: _agreedOn,
                note: reason,
                onTap: canPickAgreed ? _pickAgreedOn : null,
              ),
            ),
            if (!datesLocked && _agreedOn != null)
              IconButton(
                  key: const Key('planAgreedClear'),
                  tooltip: '同意を得た日を空にする（作成中に戻す）',
                  onPressed: () => setState(() => _agreedOn = null),
                  icon: const Icon(Icons.clear)),
          ]),
          const SizedBox(height: 8),
          const Text('保護者の署名は、印刷した紙にもらいます。同意を得た日を入れると「同意済み」になります。',
              style:
                  TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant)),
        ],
      ),
      key: const Key('planConsentSection'),
    );
  }

  Widget _footer(SupportPlan cur) {
    final s = _saved;
    final status = _isNew
        ? '新しい計画（まだ保存していません）'
        : '${(s ?? cur).status.label}'
            '${s?.revisedAfterAgreement ?? false ? '・同意後に修正あり' : ''}'
            '　最後の保存：${s?.updatedByStaffName ?? '—'}'
            '${s?.updatedAt == null ? '' : '（${_ymdhm(s!.updatedAt)}）'}';
    final canSave = !_saving && !_locked && (_dirty || _isNew);
    return Material(
      key: const Key('planFooter'),
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
                  key: const Key('planStatusLine'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.onSurfaceVariant)),
              if (_dirty && !_isNew)
                const Text('保存していない変更があります',
                    key: Key('planDirty'),
                    style: TextStyle(fontSize: 12.5, color: AppColors.warning)),
              const SizedBox(height: 6),
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  key: const Key('planSave'),
                  onPressed: canSave ? _save : null,
                  icon: const Icon(Icons.save),
                  label: Text(_agreedOn != null && _agreedEdit == null
                      ? '保存する（同意済み）'
                      : _agreedEdit == _AgreedEdit.light
                          ? '保存する（軽い修正・同意済みのまま）'
                          : '保存する（作成中）'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
