// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/account_session.dart';
import '../data/staff_session.dart';
import '../models/staff.dart';
import '../services/staff_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion/empty_state.dart';

/// 在籍終了の職員の一覧と「在籍に戻す」操作（顧客の在籍終了の画面と同じ作り）。
///
/// 職員は削除しない（在籍終了 = isActive:false）。在籍に戻すのは管理者だけ。
class InactiveStaffScreen extends StatelessWidget {
  const InactiveStaffScreen({super.key});

  Future<void> _restore(BuildContext context, Staff s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${s.name}」を在籍に戻しますか？'),
        content: const Text(
          '担当者の一覧に再び表示されます。\n'
          'ログインの許可があれば、本人がもう一度 Google でログインすると使えます。',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            key: const Key('restoreStaffConfirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('在籍に戻す'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await StaffService.instance.restoreStaff(s.id);
    } on StaffNotSelectedException {
      return;
    } on NotAdminException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「${s.name}」を在籍に戻しました')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('在籍終了の職員')),
      body: ListenableBuilder(
        listenable:
            Listenable.merge([StaffService.instance, AccountSession.instance]),
        builder: (context, _) {
          final list = StaffService.instance.getInactiveStaff();
          final admin = AccountSession.instance.isAdmin;
          final reason = AccountSession.instance.adminOnlyReason;
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: '在籍終了の職員はいません',
              message: '職員の編集画面から「在籍終了」にした職員がここに表示されます',
            );
          }
          final fmt = DateFormat('yyyy/MM/dd');
          return ListView.separated(
            key: const Key('inactiveStaffList'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            itemCount: list.length + 1,
            separatorBuilder: (_, i) =>
                i == 0 ? const SizedBox(height: 8) : const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Text(
                  '在籍終了 ${list.length} 名。'
                  '${admin ? '「在籍に戻す」で職員の一覧に戻せます。' : '在籍に戻すのは管理者だけができます。$reason'}',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.onSurfaceVariant),
                );
              }
              final s = list[i - 1];
              final ended = s.deactivatedAt;
              return ListTile(
                key: Key('inactiveStaff_${s.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_off_outlined),
                title: Text(s.name),
                subtitle: Text([
                  if (s.kana.isNotEmpty) s.kana,
                  if (ended != null) '在籍終了 ${fmt.format(ended)}',
                ].join('　')),
                trailing: OutlinedButton.icon(
                  key: Key('restoreStaff_${s.id}'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(120, 48)),
                  onPressed: admin ? () => _restore(context, s) : null,
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('在籍に戻す'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
