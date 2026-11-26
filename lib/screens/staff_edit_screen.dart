// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/account_session.dart';
import '../data/staff_session.dart';
import '../models/staff.dart';
import '../services/staff_account_service.dart';
import '../services/staff_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion/app_buttons.dart';
import '../widgets/unfocus_offscreen_text_field.dart';
import '../widgets/select_chip.dart';

/// 在籍終了の確認ダイアログ（職員管理の一覧・編集画面で共通）
Future<bool> confirmDeactivateStaff(BuildContext context, Staff s) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('「${s.name}」を在籍終了にしますか？'),
      content: const Text(
        'ログインできなくなります。記録に残った名前はそのままで、あとで在籍に戻せます。',
        style: TextStyle(height: 1.6),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル')),
        ElevatedButton(
          key: const Key('staffDeactivateConfirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              minimumSize: const Size(120, 48)),
          child: const Text('在籍終了にする'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 職員の登録・編集。
///
/// 氏名・ふりがな・役割・資格・勤務日・送迎の可否は、担当者を選んだ人なら誰でも編集できる。
/// Google メールアドレス・ログインの許可・管理者・在籍終了は管理者だけ。管理者でないときは
/// 表示するが編集できない状態にし、理由を添える（押してからエラーにしない）。
/// 新規登録は管理者だけ（一覧の「職員を登録」も管理者にだけ出す）。
class StaffEditScreen extends StatefulWidget {
  const StaffEditScreen({super.key, this.staff});

  /// 編集する職員（null なら新規登録）
  final Staff? staff;

  @override
  State<StaffEditScreen> createState() => _StaffEditScreenState();
}

class _StaffEditScreenState extends State<StaffEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _kanaCtrl;
  late final TextEditingController _qualCtrl;
  late final TextEditingController _emailCtrl;
  StaffRole? _role;
  late Set<int> _days;
  late bool _canDrive;
  late bool _isAdmin;
  late bool _loginEnabled;
  String? _emailError;
  bool _saving = false;

  bool get _isNew => widget.staff == null;

  @override
  void initState() {
    super.initState();
    final s = widget.staff;
    _nameCtrl = TextEditingController(text: s?.name ?? '');
    _kanaCtrl = TextEditingController(text: s?.kana ?? '');
    _qualCtrl = TextEditingController(text: s?.qualifications ?? '');
    _emailCtrl = TextEditingController(
        text:
            s == null ? '' : StaffAccountService.instance.emailOf(s.id) ?? '');
    _role = s?.role;
    _days = {...?s?.workDays};
    _canDrive = s?.canDrive ?? false;
    _isAdmin = s?.isAdmin ?? false;
    _loginEnabled = s?.loginEnabled ?? false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _kanaCtrl.dispose();
    _qualCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Staff _draft() => Staff(
        id: widget.staff?.id ?? '',
        name: _nameCtrl.text.trim(),
        kana: _kanaCtrl.text.trim(),
        role: _role,
        qualifications: _qualCtrl.text.trim(),
        workDays: Staff.normalizeDays(_days),
        canDrive: _canDrive,
        isAdmin: _isAdmin,
        loginEnabled: _loginEnabled,
      );

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _emailError = null;
    });
    final admin = AccountSession.instance.isAdmin;
    try {
      final draft = _draft();
      if (_isNew) {
        await StaffService.instance
            .addStaff(draft, googleEmail: _emailCtrl.text);
      } else {
        // アカウントの項目を先に確かめて保存する（最後の管理者・重複などで止まったら、
        // 氏名などの保存もしない）
        if (admin) {
          await StaffService.instance.updateAccess(
            draft.id,
            isAdmin: _isAdmin,
            loginEnabled: _loginEnabled,
            googleEmail: _emailCtrl.text,
          );
        }
        await StaffService.instance.updateProfile(draft);
      }
      if (!mounted) return;
      _snack(_isNew ? '職員「${draft.name}」を登録しました' : '保存しました');
      Navigator.of(context).pop(true);
    } on StaffNotSelectedException {
      // 担当者の選択を閉じた → 何もしない
    } on StaffInputException catch (e) {
      setState(() => _emailError = e.message);
    } on LastAdminException catch (e) {
      _snack(e.toString(), color: AppColors.error);
    } on NotAdminException catch (e) {
      _snack(e.message, color: AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deactivate() async {
    final s = widget.staff!;
    if (!await confirmDeactivateStaff(context, s)) return;
    try {
      await StaffService.instance.deactivateStaff(s.id);
    } on StaffNotSelectedException {
      return;
    } on LastAdminException catch (e) {
      if (mounted) _snack(e.toString(), color: AppColors.error);
      return;
    }
    if (!mounted) return;
    _snack('「${s.name}」を在籍終了にしました', color: AppColors.warning);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AccountSession.instance,
      builder: (context, _) {
        final admin = AccountSession.instance.isAdmin;
        final reason = AccountSession.instance.adminOnlyReason;
        return Scaffold(
          appBar: AppBar(title: Text(_isNew ? '職員を登録' : '職員の編集')),
          body: UnfocusOffscreenTextField(
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 100),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _section('基本情報', _buildBasic()),
                        _section('役割・資格', _buildRole()),
                        _section('勤務', _buildWork()),
                        _section('アカウント（管理者だけが変更できます）',
                            _buildAccount(admin, reason)),
                        if (!_isNew && widget.staff!.isActive)
                          _section('在籍', _buildEnrollment(admin, reason)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                height: 56,
                child: AppElevatedButton(
                  key: const Key('staffSaveButton'),
                  onPressed: _saving || (_isNew && !admin) ? null : _save,
                  child: Text(_isNew ? '登録する' : '保存する',
                      style: const TextStyle(fontSize: 16)),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _section(String title, Widget child) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      // 背景色は Material に持たせる（色付きの DecoratedBox の中に SwitchListTile を
      // 置くと、押したときの波紋が見えなくなるため）
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                      letterSpacing: 0.5)),
            ),
            const Divider(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: child,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBasic() {
    return Column(
      children: [
        TextFormField(
          key: const Key('staffNameField'),
          controller: _nameCtrl,
          decoration:
              const InputDecoration(labelText: '氏名 *', hintText: '例: 山田 花子'),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? '氏名を入力してください' : null,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('staffKanaField'),
          controller: _kanaCtrl,
          decoration:
              const InputDecoration(labelText: 'ふりがな', hintText: '例: やまだ はなこ'),
          textInputAction: TextInputAction.next,
        ),
      ],
    );
  }

  Widget _buildRole() {
    return Column(
      children: [
        DropdownButtonFormField<StaffRole?>(
          key: const Key('staffRoleField'),
          initialValue: _role,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '役割'),
          items: [
            const DropdownMenuItem<StaffRole?>(value: null, child: Text('未設定')),
            for (final r in StaffRole.values)
              DropdownMenuItem<StaffRole?>(value: r, child: Text(r.label)),
          ],
          onChanged: (v) => setState(() => _role = v),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('staffQualField'),
          controller: _qualCtrl,
          decoration: const InputDecoration(
              labelText: '資格', hintText: '例: 保育士、普通自動車免許'),
        ),
      ],
    );
  }

  Widget _buildWork() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('勤務日（押して選ぶ）',
            style: TextStyle(fontSize: 13, color: AppColors.onSurfaceVariant)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var d = 1; d <= 7; d++)
              SelectChip(
                key: Key('staffDay_$d'),
                label: Staff.weekdayLabels[d - 1],
                selected: _days.contains(d),
                onSelected: (on) => setState(() {
                  on ? _days.add(d) : _days.remove(d);
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('staffCanDriveSwitch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('送迎の運転ができる'),
          value: _canDrive,
          onChanged: (v) => setState(() => _canDrive = v),
        ),
      ],
    );
  }

  Widget _buildAccount(bool admin, String? reason) {
    final hasEmail = widget.staff?.hasGoogleEmail ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (reason != null)
          Container(
            key: const Key('staffAdminOnlyReason'),
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline,
                    size: 18, color: AppColors.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(reason,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.onSurfaceVariant))),
              ],
            ),
          ),
        if (admin)
          TextFormField(
            key: const Key('staffEmailField'),
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'Google メールアドレス（個人アカウント用・空欄でもよい）',
              errorText: _emailError,
              errorMaxLines: 2,
            ),
            validator: (v) {
              final t = (v ?? '').trim();
              if (t.isEmpty) return null;
              return StaffAccountService.isValidEmail(t)
                  ? null
                  : 'メールアドレスの形が正しくありません';
            },
          )
        else
          // 管理者でなければアドレス本体は読めない（個人情報）。登録の有無だけ出す
          InputDecorator(
            key: const Key('staffEmailReadOnly'),
            decoration: const InputDecoration(
                labelText: 'Google メールアドレス', enabled: false),
            child: Text(hasEmail ? '登録済み' : '未登録'),
          ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('staffLoginSwitch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('ログインの許可'),
          subtitle: const Text('Google アカウントでのログインを許可する'),
          value: _loginEnabled,
          onChanged: admin ? (v) => setState(() => _loginEnabled = v) : null,
        ),
        SwitchListTile(
          key: const Key('staffAdminSwitch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('管理者'),
          subtitle: const Text('職員の登録・在籍終了・ログインの設定ができる'),
          value: _isAdmin,
          onChanged: admin ? (v) => setState(() => _isAdmin = v) : null,
        ),
      ],
    );
  }

  Widget _buildEnrollment(bool admin, String? reason) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '在籍終了にすると、担当者の一覧から消え、ログインできなくなります。'
          '記録に残った名前はそのままで、あとで在籍に戻せます。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        if (reason != null) ...[
          const SizedBox(height: 4),
          Text(reason,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.onSurfaceVariant)),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('staffDeactivateButton'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.error,
            minimumSize: const Size(160, 48),
          ),
          onPressed: admin ? _deactivate : null,
          icon: const Icon(Icons.person_off_outlined),
          label: const Text('在籍終了にする'),
        ),
      ],
    );
  }
}
