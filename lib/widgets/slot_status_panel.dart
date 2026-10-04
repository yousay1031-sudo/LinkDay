import 'package:flutter/material.dart';

import '../models/slot_info.dart';
import '../theme/app_theme.dart';
import 'vacancy_notice_dialog.dart' show kLineGreen;

/// 利用者 ID → 表示名。見つからなければ null。
typedef CustomerNameResolver = String? Function(String customerId);

/// 枠 1 件の表示内容（ウィジェットとテストで共有する純粋ロジック）
@immutable
class SlotRowView {
  /// 欠席した児童名
  final String absentName;

  /// 状態ラベル（例: 「募集中」「確定」）
  final String label;

  /// 補足（例: 「山田 太郎さん ・ 10:23 に応募」）
  final String detail;

  final SlotState state;

  const SlotRowView({
    required this.absentName,
    required this.label,
    required this.detail,
    required this.state,
  });

  /// [SlotInfo] から表示内容を作る。
  ///
  /// status=filled のときだけ「応募者名＋応募時刻」を出す。
  /// 名前が引けなくても ID は出さず「利用者情報なし」にする
  /// （内部 ID を職員画面に露出しない）。
  static SlotRowView from(
    SlotInfo slot, {
    required DateTime now,
    required CustomerNameResolver nameOf,
  }) {
    final absent = nameOf(slot.sourceAbsent) ?? '（不明な利用者）';
    final state = slot.stateAt(now);
    switch (state) {
      case SlotState.filled:
        final claim = slot.claimedBy!;
        final who = nameOf(claim.customerId) ?? '（利用者情報なし）';
        final t = formatClaimTime(claim.claimedAt);
        return SlotRowView(
          absentName: absent,
          label: '確定',
          detail: t == null ? '$whoさん が応募' : '$whoさん ・ $t に応募',
          state: state,
        );
      case SlotState.open:
        return SlotRowView(
          absentName: absent,
          label: '募集中',
          detail: _untilLabel(slot.expiresAt, slot.notifiedCount),
          state: state,
        );
      case SlotState.released:
        return SlotRowView(
          absentName: absent,
          label: '再募集中',
          detail: '応募者がキャンセルしました。'
              '${_untilLabel(slot.expiresAt, slot.notifiedCount)}',
          state: state,
        );
      case SlotState.expired:
        return SlotRowView(
          absentName: absent,
          label: '受付終了',
          detail: '応募なしで受付時間を過ぎました（通知 ${slot.notifiedCount} 名）',
          state: state,
        );
      case SlotState.unknown:
        return SlotRowView(
          absentName: absent,
          label: '状態不明',
          detail: '枠の状態を判定できません。LINE通知の履歴をご確認ください。',
          state: state,
        );
    }
  }

  static String _untilLabel(DateTime? expiresAt, int notified) {
    final n = '通知 $notified 名';
    if (expiresAt == null) return n;
    return '$n ・ ${formatClaimTime(expiresAt)} まで受付';
  }

  /// "HH:mm"（端末ローカル時刻）。null は null。
  static String? formatClaimTime(DateTime? d) {
    if (d == null) return null;
    final l = d.toLocal();
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

Color _colorOf(SlotState s) {
  switch (s) {
    case SlotState.filled:
      return const Color(0xFF2E7D32);
    case SlotState.open:
      return kLineGreen;
    case SlotState.released:
      return const Color(0xFFEF6C00);
    case SlotState.expired:
      return const Color(0xFF78909C);
    case SlotState.unknown:
      return const Color(0xFFC62828);
  }
}

IconData _iconOf(SlotState s) {
  switch (s) {
    case SlotState.filled:
      return Icons.check_circle;
    case SlotState.open:
      return Icons.campaign_outlined;
    case SlotState.released:
      return Icons.replay;
    case SlotState.expired:
      return Icons.timer_off_outlined;
    case SlotState.unknown:
      return Icons.help_outline;
  }
}

/// 出席画面の集計バー直下に出す「LINE応募」パネル（選択日の枠のみ）
class SlotStatusPanel extends StatelessWidget {
  final List<SlotInfo> slots;
  final DateTime now;
  final CustomerNameResolver nameOf;

  /// 取得エラー（null なら正常）。「応募なし」と誤認させないため明示表示する。
  final String? error;

  const SlotStatusPanel({
    super.key,
    required this.slots,
    required this.now,
    required this.nameOf,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    if (error == null && slots.isEmpty) return const SizedBox.shrink();

    return Container(
      key: const Key('slotStatusPanel'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kLineGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kLineGreen.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.chat_bubble, size: 14, color: kLineGreen),
              SizedBox(width: 6),
              Text(
                'LINE応募',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurface,
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(
              '応募状況を取得できませんでした（$error）',
              key: const Key('slotStatusError'),
              style: const TextStyle(fontSize: 12, color: AppColors.error),
            ),
          ],
          for (final s in slots) ...[
            const SizedBox(height: 6),
            _SlotRow(
              key: ValueKey('slotRow_${s.id}'),
              view: SlotRowView.from(s, now: now, nameOf: nameOf),
            ),
          ],
        ],
      ),
    );
  }
}

class _SlotRow extends StatelessWidget {
  final SlotRowView view;
  const _SlotRow({super.key, required this.view});

  @override
  Widget build(BuildContext context) {
    final color = _colorOf(view.state);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconOf(view.state), size: 12, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                view.label,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${view.absentName}さんの欠席枠　',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(
                  text: view.detail,
                  style: const TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// 欠席カード内に出す小さなチップ（その児童の枠の状態）
class SlotChip extends StatelessWidget {
  final SlotRowView view;
  const SlotChip({super.key, required this.view});

  @override
  Widget build(BuildContext context) {
    final color = _colorOf(view.state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(_iconOf(view.state), size: 12, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'LINE応募: ${view.label}'
              '${view.state == SlotState.filled ? '　${view.detail}' : ''}',
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
