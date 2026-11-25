// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/account_session.dart';
import '../services/login_history_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion/empty_state.dart';

/// ログイン履歴（管理者だけ）。新しい順に直近 [LoginHistoryService.recentLimit] 件。
class LoginHistoryScreen extends StatelessWidget {
  const LoginHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('yyyy/MM/dd（E） HH:mm', 'ja_JP');
    return Scaffold(
      appBar: AppBar(title: const Text('ログイン履歴')),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [LoginHistoryService.instance, AccountSession.instance]),
        builder: (context, _) {
          if (!AccountSession.instance.isAdmin) {
            return EmptyState(
              icon: Icons.lock_outline,
              title: 'ログイン履歴は管理者だけが見られます',
              message: AccountSession.instance.adminOnlyReason,
            );
          }
          final list = LoginHistoryService.instance.recent;
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.history,
              title: LoginHistoryService.instance.isLoaded
                  ? 'ログインの記録はまだありません'
                  : '読み込み中です',
            );
          }
          return ListView.separated(
            key: const Key('loginHistoryList'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            itemCount: list.length + 1,
            separatorBuilder: (_, i) =>
                i == 0 ? const SizedBox(height: 8) : const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i == 0) {
                return const Text(
                  '事業所に入れたログインを、新しい順に表示します（直近 100 件）。'
                  '記録は書き換え・削除できません。',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.onSurfaceVariant),
                );
              }
              final e = list[i - 1];
              final at = e.at;
              return ListTile(
                key: Key('loginEntry_${e.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(e.personal
                    ? Icons.account_circle_outlined
                    : Icons.devices_outlined),
                title: Text(e.personal ? (e.staffName ?? '（名前なし）') : '共用端末'),
                subtitle: Text('${at == null ? '時刻を確定中' : fmt.format(at)}　'
                    '${e.personal ? '個人アカウント（Google）' : '共用端末アカウント'}'),
              );
            },
          );
        },
      ),
    );
  }
}
