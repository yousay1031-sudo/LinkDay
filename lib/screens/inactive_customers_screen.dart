// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/staff_session.dart';
import '../models/customer.dart';
import '../services/customer_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion/empty_state.dart';

/// 在籍終了の顧客の一覧と「在籍に戻す」操作。
///
/// 顧客は削除しない（在籍終了 = isActive:false）。ここから在籍中に戻せる。
/// 他の端末での在籍終了・在籍に戻す操作も、開き直さずに反映される。
class InactiveCustomersScreen extends StatefulWidget {
  const InactiveCustomersScreen({super.key});

  @override
  State<InactiveCustomersScreen> createState() =>
      _InactiveCustomersScreenState();
}

class _InactiveCustomersScreenState extends State<InactiveCustomersScreen> {
  Future<void> _restore(Customer c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${c.name}」を在籍に戻しますか？'),
        content: const Text(
          '顧客一覧・週間利用計画などに、再び表示されるようになります。\n'
          '登録内容はそのまま残っています。',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            key: const Key('restoreCustomerConfirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('在籍に戻す'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CustomerService.instance.restoreCustomer(c.id);
    } on StaffNotSelectedException {
      return; // 担当者の選択を閉じた → 何もしない
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「${c.name}」を在籍に戻しました')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 戻ったときの一覧の読み直しは不要（顧客管理の画面が変更通知で読み直す）。
    // 以前は PopScope で結果を返していたが、戻った後に顧客管理の「戻る」が
    // 効かなくなる不具合があったためやめた。
    return Scaffold(
      appBar: AppBar(title: const Text('在籍終了の顧客')),
      body: ListenableBuilder(
        listenable: CustomerService.instance,
        builder: (context, _) {
          final list = CustomerService.instance.getInactiveCustomers();
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: '在籍終了の顧客はいません',
              message: '顧客の編集画面から「在籍終了」にした顧客がここに表示されます',
            );
          }
          final fmt = DateFormat('yyyy/MM/dd');
          return ListView.separated(
            key: const Key('inactiveCustomerList'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            itemCount: list.length + 1,
            separatorBuilder: (_, i) =>
                i == 0 ? const SizedBox(height: 8) : const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Text(
                  '在籍終了 ${list.length} 名。「在籍に戻す」で顧客一覧に戻せます。',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.onSurfaceVariant),
                );
              }
              final c = list[i - 1];
              final ended = c.deactivatedAt;
              return ListTile(
                key: Key('inactiveCustomer_${c.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_off_outlined),
                title: Text(c.name),
                subtitle: Text([
                  c.nameKana,
                  if (ended != null) '在籍終了 ${fmt.format(ended)}',
                ].join('　')),
                trailing: OutlinedButton.icon(
                  key: Key('restoreCustomer_${c.id}'),
                  // テーマの minimumSize は幅が無限（Size.fromHeight）のため、
                  // ListTile の trailing では有限の最小幅を指定する
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(120, 40)),
                  onPressed: () => _restore(c),
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
