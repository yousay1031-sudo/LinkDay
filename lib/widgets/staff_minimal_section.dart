// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/data_errors.dart';
import '../data/staff_session.dart';
import '../models/staff.dart';
import '../services/staff_service.dart';
import '../theme/app_theme.dart';

/// 設定画面: 職員（担当者）の最小限の入力。
///
/// 名前の追加と在籍終了だけを置く。職員の登録・編集画面はステップ5（職員管理）で作る。
/// ログイン前（StaffService 未接続）は何も表示しない（設定画面単体のテスト等）。
class StaffMinimalSection extends StatefulWidget {
  const StaffMinimalSection({super.key});

  @override
  State<StaffMinimalSection> createState() => _StaffMinimalSectionState();
}

class _StaffMinimalSectionState extends State<StaffMinimalSection> {
  final _nameCtrl = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '名前を入力してください');
      return;
    }
    final dup = StaffService.instance
        .getActiveStaff()
        .any((s) => s.name == name);
    if (dup) {
      setState(() => _error = '同じ名前の職員がすでにいます');
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await StaffService.instance.addStaff(name);
      _nameCtrl.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('職員「$name」を追加しました')),
      );
    } on StaffNotSelectedException {
      // 選択画面を閉じた → 何もしない
    } catch (e) {
      setState(() => _error = DataErrors.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deactivate(Staff s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${s.name}」を在籍終了にしますか？'),
        content: const Text(
          '担当者の一覧から消えます。\n過去の記録に残っている名前はそのまま表示されます。',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('キャンセル')),
          ElevatedButton(
            key: const Key('staffDeactivateConfirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('在籍終了にする'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await StaffService.instance.deactivateStaff(s.id);
    } on StaffNotSelectedException {
      // 何もしない
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: StaffService.instance,
      builder: (context, _) {
        if (!StaffService.instance.isAttached) return const SizedBox.shrink();
        final staff = StaffService.instance.getActiveStaff();
        return Card(
          key: const Key('staffMinimalSection'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.badge_outlined, color: AppColors.primary, size: 20),
                    SizedBox(width: 8),
                    Text('職員（担当者）',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  '記録に残す「担当者」の一覧です。名前の追加と在籍終了ができます。',
                  style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('staffNameField'),
                        controller: _nameCtrl,
                        decoration: InputDecoration(
                          labelText: '職員の名前',
                          errorText: _error,
                          isDense: true,
                        ),
                        onSubmitted: (_) => _busy ? null : _add(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      key: const Key('staffAddButton'),
                      // テーマの minimumSize は幅が無限（Size.fromHeight）のため、
                      // 横並び（Row）では有限の最小幅を指定しないと描画が壊れる
                      style: ElevatedButton.styleFrom(
                          minimumSize: const Size(96, 44)),
                      onPressed: _busy ? null : _add,
                      icon: const Icon(Icons.person_add_alt_1, size: 18),
                      label: const Text('追加'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (staff.isEmpty)
                  const Text('まだ登録されていません。',
                      style: TextStyle(color: AppColors.onSurfaceVariant))
                else
                  for (final s in staff)
                    ListTile(
                      key: Key('staffRow_${s.id}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.person_outline),
                      title: Text(s.name),
                      trailing: TextButton(
                        key: Key('staffDeactivate_${s.id}'),
                        onPressed: () => _deactivate(s),
                        child: const Text('在籍終了'),
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}
