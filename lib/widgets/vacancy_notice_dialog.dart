import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/settings_service.dart';
import '../services/vacancy_notification_service.dart';
import '../theme/app_theme.dart';

/// LINE ブランドカラー
const Color kLineGreen = Color(0xFF06C755);

/// ダイアログの戻り値
///
/// 【BUG-002 の教訓】
/// 「キャンセルしたのに処理が走る」事故を防ぐため、
/// showDialog の戻り値は null / [cancelled] / [send] を厳密に区別する。
/// null（バリアタップ・戻るキー・画面破棄）は必ず「送らない」として扱う。
@immutable
class VacancyNoticeDialogResult {
  /// 送信するか（false または null 相当なら送らない）
  final bool shouldSend;

  /// 送信対象（shouldSend == false のときは空）
  final List<VacancyCandidate> selected;

  /// 実際に送る文面
  final String message;

  const VacancyNoticeDialogResult._({
    required this.shouldSend,
    required this.selected,
    required this.message,
  });

  const VacancyNoticeDialogResult.cancelled()
      : shouldSend = false,
        selected = const [],
        message = '';

  factory VacancyNoticeDialogResult.send(
    List<VacancyCandidate> selected,
    String message,
  ) =>
      VacancyNoticeDialogResult._(
        shouldSend: true,
        selected: selected,
        message: message,
      );
}

/// 空き枠通知の候補確認ダイアログ
///
/// 欠席登録の直後に表示し、職員が宛先を確認・取捨選択してから送信する。
/// 「既定 ON、職員が外せる」方式。未連携の児童は別枠グレー表示（送信対象外）。
class VacancyNoticeDialog extends StatefulWidget {
  final VacancyCandidateResult candidates;

  /// 欠席した児童名（見出しに表示）
  final String absentChildName;

  const VacancyNoticeDialog({
    super.key,
    required this.candidates,
    required this.absentChildName,
  });

  /// ダイアログを表示する。
  ///
  /// 戻り値が null の場合（バリアタップ・戻るキー）は必ず
  /// [VacancyNoticeDialogResult.cancelled] に正規化して返す。
  static Future<VacancyNoticeDialogResult> show(
    BuildContext context, {
    required VacancyCandidateResult candidates,
    required String absentChildName,
  }) async {
    final result = await showDialog<VacancyNoticeDialogResult>(
      context: context,
      // 誤タップでの送信を防ぐため、明示操作のみで閉じる
      barrierDismissible: true,
      builder: (_) => VacancyNoticeDialog(
        candidates: candidates,
        absentChildName: absentChildName,
      ),
    );
    // null は「キャンセル」として厳密に扱う（何も送らない）
    return result ?? const VacancyNoticeDialogResult.cancelled();
  }

  @override
  State<VacancyNoticeDialog> createState() => _VacancyNoticeDialogState();
}

class _VacancyNoticeDialogState extends State<VacancyNoticeDialog> {
  /// customerId → チェック状態
  final Map<String, bool> _checked = {};
  late TextEditingController _messageCtrl;
  bool _editingMessage = false;

  @override
  void initState() {
    super.initState();
    // 既定 ON（送信可能なものだけ）。送信済み・未連携は OFF 固定。
    for (final c in widget.candidates.linked) {
      _checked[c.customerId] = c.canNotify;
    }
    _messageCtrl = TextEditingController(
      text: VacancyNotificationService.instance.buildMessage(
        widget.candidates.date,
      ),
    );
  }

  @override
  void dispose() {
    _messageCtrl.dispose();
    super.dispose();
  }

  List<VacancyCandidate> get _selected => widget.candidates.linked
      .where((c) => c.canNotify && (_checked[c.customerId] ?? false))
      .toList();

  @override
  Widget build(BuildContext context) {
    final d = widget.candidates.date;
    final dateLabel = '${d.month}/${d.day}';
    final notifiable = widget.candidates.notifiable;
    final alreadySent = widget.candidates.alreadyNotified;
    final unlinked = widget.candidates.unlinked;
    final settings = SettingsService.instance.getSettings();

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: kLineGreen.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.chat_bubble_outline,
                color: kLineGreen, size: 18),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('空き枠のLINE通知', style: TextStyle(fontSize: 17)),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 見出し
              Text(
                '${widget.absentChildName} さんの欠席により、'
                '本日（$dateLabel）に空きが出ました。',
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 4),
              Text(
                notifiable.isEmpty
                    ? '現在、通知できるご家庭はありません。'
                    : '以下の ${notifiable.length} 件のご家庭に通知しますか？',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: notifiable.isEmpty
                      ? AppColors.onSurfaceVariant
                      : AppColors.onSurface,
                ),
              ),
              const SizedBox(height: 12),

              // ── 送信可能な候補
              if (notifiable.isNotEmpty) ...[
                _sectionLabel('通知対象（チェックを外すと送信しません）',
                    Icons.check_circle_outline, kLineGreen),
                const SizedBox(height: 6),
                ...notifiable.map(_candidateTile),
                const SizedBox(height: 12),
              ],

              // ── 既に通知済み
              if (alreadySent.isNotEmpty) ...[
                _sectionLabel('送信済み（二重送信を防ぐため再送しません）',
                    Icons.done_all, AppColors.info),
                const SizedBox(height: 6),
                ...alreadySent.map(_sentTile),
                const SizedBox(height: 12),
              ],

              // ── 未連携（送信対象外）
              if (unlinked.isNotEmpty) ...[
                _sectionLabel('LINE未連携（送信できません／電話案内の参考）',
                    Icons.phone_outlined, AppColors.onSurfaceVariant),
                const SizedBox(height: 6),
                ...unlinked.map(_unlinkedTile),
                const SizedBox(height: 12),
              ],

              if (widget.candidates.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '空き枠を埋められる候補が見つかりませんでした。\n'
                    '（当日利用予定・支給量残なし・在籍なし のいずれかに該当）',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: AppColors.onSurfaceVariant),
                  ),
                ),

              // ── 文面プレビュー
              if (notifiable.isNotEmpty) ...[
                const Divider(height: 20),
                Row(
                  children: [
                    const Icon(Icons.article_outlined,
                        size: 15, color: AppColors.onSurfaceVariant),
                    const SizedBox(width: 6),
                    const Text('送信される文面',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 30),
                      ),
                      icon: Icon(_editingMessage ? Icons.done : Icons.edit,
                          size: 14),
                      label: Text(_editingMessage ? '編集を終了' : '今回だけ編集',
                          style: const TextStyle(fontSize: 11)),
                      onPressed: () =>
                          setState(() => _editingMessage = !_editingMessage),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (_editingMessage)
                  TextField(
                    controller: _messageCtrl,
                    maxLines: 6,
                    minLines: 4,
                    style: const TextStyle(fontSize: 12, height: 1.5),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: '※この変更は今回の送信のみに適用されます',
                      helperStyle: TextStyle(fontSize: 10),
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: kLineGreen.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: kLineGreen.withValues(alpha: 0.25)),
                    ),
                    child: Text(
                      _messageCtrl.text,
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  '事業所名「${settings.facilityName}」・回答期限'
                  '「${settings.vacancyReplyDeadline}」は設定画面で変更できます。',
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          // キャンセルは明示的に cancelled を返す（null 経路でも同じ扱い）
          onPressed: () => Navigator.of(context)
              .pop(const VacancyNoticeDialogResult.cancelled()),
          child: const Text('送信しない'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: kLineGreen),
          icon: const Icon(Icons.send, size: 16),
          label: Text(_selected.isEmpty
              ? '送信する'
              : '送信する（${_selected.length}件）'),
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                    VacancyNoticeDialogResult.send(
                      _selected,
                      _messageCtrl.text.trim(),
                    ),
                  ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text, IconData icon, Color color) => Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ),
        ],
      );

  Widget _candidateTile(VacancyCandidate c) {
    final checked = _checked[c.customerId] ?? false;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: checked ? kLineGreen.withValues(alpha: 0.05) : null,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: checked
              ? kLineGreen.withValues(alpha: 0.35)
              : AppColors.divider,
        ),
      ),
      child: CheckboxListTile(
        value: checked,
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        activeColor: kLineGreen,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6),
        onChanged: (v) =>
            setState(() => _checked[c.customerId] = v ?? false),
        title: Text(c.childName,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        subtitle: Text(
          '残${c.remainingProjected}日 ・ ${c.regularDaysLabel} ・ '
          '${VacancyNotificationService.maskLineUserId(c.lineUserId)}',
          style: const TextStyle(
              fontSize: 11, color: AppColors.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _sentTile(VacancyCandidate c) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.info.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.info.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            const Icon(Icons.done_all, size: 15, color: AppColors.info),
            const SizedBox(width: 8),
            Expanded(
              child: Text(c.childName,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
            ),
            Text(
              '送信済み（${c.existingLog?.statusLabel ?? ''}）',
              style: const TextStyle(fontSize: 11, color: AppColors.info),
            ),
          ],
        ),
      );

  Widget _unlinkedTile(VacancyCandidate c) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            const Icon(Icons.link_off,
                size: 15, color: AppColors.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${c.childName}（残${c.remainingProjected}日・'
                '${c.regularDaysLabel}）',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.onSurfaceVariant),
              ),
            ),
            const Text('LINE未連携',
                style: TextStyle(
                    fontSize: 11, color: AppColors.onSurfaceVariant)),
          ],
        ),
      );
}

/// 送信結果の表示ダイアログ
class VacancySendResultDialog extends StatelessWidget {
  final VacancySendResult result;

  const VacancySendResultDialog({super.key, required this.result});

  static Future<void> show(
    BuildContext context,
    VacancySendResult result,
  ) =>
      showDialog<void>(
        context: context,
        builder: (_) => VacancySendResultDialog(result: result),
      );

  @override
  Widget build(BuildContext context) {
    final fatal = result.fatalError;
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            fatal != null
                ? Icons.error_outline
                : (result.failedCount > 0
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline),
            color: fatal != null
                ? AppColors.error
                : (result.failedCount > 0
                    ? AppColors.warning
                    : AppColors.success),
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              fatal != null ? '送信できませんでした' : '送信結果',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (fatal != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(fatal,
                      style: const TextStyle(fontSize: 12, height: 1.5)),
                )
              else
                Text(result.summaryLabel,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              if (result.items.isNotEmpty) ...[
                const SizedBox(height: 12),
                ...result.items.map((item) {
                  final isOk = item.status.name == 'sent';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          isOk ? Icons.check : Icons.close,
                          size: 15,
                          color: isOk ? AppColors.success : AppColors.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${item.childName.isEmpty ? item.customerId : item.childName}'
                                ' — ${_statusLabel(item)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              if (item.error != null)
                                Text(
                                  item.error!,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: AppColors.onSurfaceVariant),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
              if (result.failedCount > 0) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '失敗したご家庭には LINE が届いていません。'
                    'お手数ですがお電話でご連絡ください。',
                    style: TextStyle(fontSize: 11, height: 1.5),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }

  String _statusLabel(VacancySendResultItem item) {
    switch (item.status.name) {
      case 'sent':
        return '送信成功';
      case 'duplicate':
        return '既に送信済み';
      case 'invalidLineUserId':
        return 'LINE ID が不正';
      default:
        return '送信失敗'
            '${item.httpStatus != null ? '（HTTP ${item.httpStatus}）' : ''}';
    }
  }
}

/// 連携コード表示ダイアログ（顧客編集画面から呼ぶ）
class LinkingCodeDialog extends StatelessWidget {
  final String code;
  final String childName;
  final DateTime expiresAt;

  const LinkingCodeDialog({
    super.key,
    required this.code,
    required this.childName,
    required this.expiresAt,
  });

  static Future<void> show(
    BuildContext context, {
    required String code,
    required String childName,
    required DateTime expiresAt,
  }) =>
      showDialog<void>(
        context: context,
        builder: (_) => LinkingCodeDialog(
          code: code,
          childName: childName,
          expiresAt: expiresAt,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: kLineGreen.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.qr_code_2, color: kLineGreen, size: 18),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('LINE連携コード', style: TextStyle(fontSize: 17)),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$childName さんの保護者にお渡しするコードです。',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 14),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 16),
                  decoration: BoxDecoration(
                    color: kLineGreen.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: kLineGreen.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    code,
                    style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 8,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.copy, size: 15),
                  label: const Text('コードをコピー',
                      style: TextStyle(fontSize: 12)),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('連携コードをコピーしました'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('保護者への案内手順',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    SizedBox(height: 6),
                    Text(
                      '1. 事業所の LINE 公式アカウントを友だち追加\n'
                      '2. トーク画面に上のコード（6桁）を送信\n'
                      '3. 「連携が完了しました」と返信が届けば完了',
                      style: TextStyle(fontSize: 11, height: 1.7),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.schedule,
                      size: 14, color: AppColors.warning),
                  const SizedBox(width: 6),
                  Text(
                    '有効期限: ${expiresAt.year}/${expiresAt.month}/${expiresAt.day} まで（7日間）',
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
      ],
    );
  }
}
