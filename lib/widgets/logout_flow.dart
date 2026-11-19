// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/data_session.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../utils/page_reload.dart';

/// ログアウトの一連の流れ（確認ダイアログの「ログアウト」を押した後）。
///
/// 1. 未送信の書き込みの送信完了を待つ（待機中は進行表示）
/// 2. 送れなければ警告を出してログアウトを止める（何も消さない）
/// 3. 送れたら購読停止 → 端末内キャッシュ消去 → サインアウト → 再読み込み
Future<void> runLogout(BuildContext context) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      key: Key('logoutProgress'),
      content: Row(
        children: [
          SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Expanded(child: Text('未送信の記録がないか確認しています…')),
        ],
      ),
    ),
  );

  LogoutOutcome outcome;
  try {
    outcome = await DataSession.instance
        .logout(signOut: AuthService.instance.signOut);
  } on AuthException catch (e) {
    navigator.pop();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.message), backgroundColor: AppColors.error),
    );
    return;
  }
  navigator.pop();

  switch (outcome) {
    case LogoutOutcome.pendingWrites:
      if (!context.mounted) return;
      final retry = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('logoutPendingWrites'),
          title: const Row(
            children: [
              Icon(Icons.cloud_upload_outlined, color: AppColors.warning),
              SizedBox(width: 8),
              Expanded(child: Text('まだ送信されていない記録があります')),
            ],
          ),
          content: const Text(
            '通信が切れているため、この端末で入力した記録がまだサーバーに届いていません。\n'
            'いまログアウトすると記録が失われるため、ログアウトを止めました。\n\n'
            '通信がつながる場所で、もう一度お試しください。',
            style: TextStyle(height: 1.6),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('閉じる')),
            ElevatedButton.icon(
              key: const Key('logoutRetry'),
              onPressed: () => Navigator.of(ctx).pop(true),
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ],
        ),
      );
      if (retry == true && context.mounted) await runLogout(context);
      return;
    case LogoutOutcome.cacheNotCleared:
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('端末内の記録を消せませんでした'),
            content: const Text(
              'ログアウトはしましたが、LinkDay が他のタブでも開いているため、'
              'この端末に残っている記録を消せませんでした。\n'
              'LinkDay を開いているタブをすべて閉じてください。',
              style: TextStyle(height: 1.6),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK')),
            ],
          ),
        );
      }
      reloadPage();
      return;
    case LogoutOutcome.done:
      // 終了した Firestore は使えないため、まっさらな状態から始め直す
      reloadPage();
      return;
  }
}
