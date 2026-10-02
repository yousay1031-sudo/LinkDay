import 'package:flutter/material.dart';

import '../models/notification_log.dart';
import '../services/vacancy_notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/vacancy_notice_dialog.dart' show kLineGreen;

/// 空き枠 LINE 通知の送信履歴画面（Day 11）
///
/// 端末内（Hive box 'notification_logs'）の送信記録を日付ごとに表示する。
/// 「いつ・誰に・成功したか」を職員が後から確認できるようにし、
/// 電話フォローの漏れを防ぐ。
class NotificationHistoryScreen extends StatefulWidget {
  const NotificationHistoryScreen({super.key});

  @override
  State<NotificationHistoryScreen> createState() =>
      _NotificationHistoryScreenState();
}

class _NotificationHistoryScreenState extends State<NotificationHistoryScreen> {
  Map<String, List<NotificationLog>> _grouped = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _load() {
    setState(() {
      _grouped = VacancyNotificationService.instance.getLogsGroupedByDate();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dates = _grouped.keys.toList();
    final totalCount =
        _grouped.values.fold<int>(0, (sum, l) => sum + l.length);
    final sentCount = _grouped.values
        .expand((l) => l)
        .where((l) => l.status == NotificationStatus.sent)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LINE通知の履歴'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '再読み込み',
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── サマリー
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              color: kLineGreen.withValues(alpha: 0.06),
              child: Row(
                children: [
                  const Icon(Icons.chat_bubble_outline,
                      size: 18, color: kLineGreen),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      dates.isEmpty
                          ? 'まだ通知の送信履歴はありません'
                          : '送信 $totalCount件（成功 $sentCount件） / '
                              '${dates.length}日分',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: dates.isEmpty
                  ? const _EmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: dates.length,
                      itemBuilder: (context, i) {
                        final dateKey = dates[i];
                        final logs = _grouped[dateKey]!;
                        return _DateGroupCard(
                          dateKey: dateKey,
                          logs: logs,
                          onDeleted: _load,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.inbox_outlined,
                  size: 56, color: AppColors.onSurfaceVariant),
              SizedBox(height: 16),
              Text(
                '送信履歴がありません',
                style: TextStyle(
                    fontSize: 15, color: AppColors.onSurfaceVariant),
              ),
              SizedBox(height: 8),
              Text(
                '出席管理画面で欠席を登録すると、\n'
                '空き枠通知の候補が表示されます。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: AppColors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
}

class _DateGroupCard extends StatelessWidget {
  final String dateKey;
  final List<NotificationLog> logs;
  final VoidCallback onDeleted;

  const _DateGroupCard({
    required this.dateKey,
    required this.logs,
    required this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final sent =
        logs.where((l) => l.status == NotificationStatus.sent).length;
    final failed =
        logs.where((l) => l.status == NotificationStatus.failed).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.event, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  _formatDateKey(dateKey),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                _chip('成功 $sent', AppColors.success),
                if (failed > 0) ...[
                  const SizedBox(width: 6),
                  _chip('失敗 $failed', AppColors.error),
                ],
              ],
            ),
            const Divider(height: 14),
            ...logs.map((l) => _LogTile(log: l, onDeleted: onDeleted)),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w600, color: color)),
      );

  /// "2026-10-02" → "2026年10月2日（金）"
  static String _formatDateKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return key;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return key;
    const names = ['月', '火', '水', '木', '金', '土', '日'];
    final wd = DateTime(y, m, d).weekday;
    return '$y年$m月$d日（${names[wd - 1]}）';
  }
}

class _LogTile extends StatelessWidget {
  final NotificationLog log;
  final VoidCallback onDeleted;

  const _LogTile({required this.log, required this.onDeleted});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (log.status) {
      NotificationStatus.sent => (Icons.check_circle, AppColors.success),
      NotificationStatus.failed => (Icons.error_outline, AppColors.error),
      NotificationStatus.duplicate => (Icons.done_all, AppColors.info),
      NotificationStatus.invalidLineUserId => (
          Icons.link_off,
          AppColors.warning
        ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        log.childName.isEmpty ? log.customerId : log.childName,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      _hhmm(log.sentAt),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
                Text(
                  '${log.statusLabel}'
                  '${log.httpStatus != null ? '（HTTP ${log.httpStatus}）' : ''}'
                  '${log.lineUserIdSuffix != null ? ' ・ U...${log.lineUserIdSuffix}' : ''}',
                  style: TextStyle(fontSize: 11, color: color),
                ),
                if (log.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      log.error!,
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz, size: 18),
            tooltip: '詳細',
            visualDensity: VisualDensity.compact,
            onPressed: () => _showDetail(context),
          ),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(log.childName.isEmpty ? '送信記録' : log.childName,
            style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('対象日', log.dateKey),
                _row('状態', log.statusLabel),
                _row('送信時刻', '${log.sentAt}'),
                if (log.httpStatus != null)
                  _row('HTTPステータス', '${log.httpStatus}'),
                if (log.lineUserIdSuffix != null)
                  _row('LINE ID', 'U...${log.lineUserIdSuffix}'),
                if (log.error != null) _row('エラー', log.error!),
                if (log.message != null) ...[
                  const Divider(height: 18),
                  const Text('送信した文面',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(log.message!,
                        style: const TextStyle(fontSize: 11, height: 1.6)),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => _confirmDelete(ctx),
            child: const Text('この記録を削除'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  /// 送信記録の削除（誤記録の修復用）
  ///
  /// 【注意】端末内の記録のみ削除する。サーバー（Firestore）の
  /// notification_logs は残るため、同じ日付・児童への再送は
  /// サーバー側冪等チェックで引き続きブロックされる。
  Future<void> _confirmDelete(BuildContext dialogContext) async {
    final ok = await showDialog<bool>(
      context: dialogContext,
      builder: (ctx) => AlertDialog(
        title: const Text('記録を削除しますか？'),
        content: const Text(
          'この端末内の送信記録のみを削除します。\n'
          'サーバー側の記録は残るため、同じ日・同じ児童への再送は'
          'ブロックされたままです。',
          style: TextStyle(fontSize: 12, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final parts = log.dateKey.split('-');
    if (parts.length == 3) {
      final date = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
      await VacancyNotificationService.instance
          .deleteLog(date, log.customerId);
    }
    if (!dialogContext.mounted) return;
    Navigator.of(dialogContext).pop();
    onDeleted();
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.onSurfaceVariant)),
            ),
            Expanded(
              child: Text(value, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}
