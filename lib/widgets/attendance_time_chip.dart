import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// タップで TimePicker を開く時刻チップ
///
/// 例: 入室時刻「09:30」をタップすると TimePicker が開き、
///     選択確定後に onTimeChanged コールバックが呼ばれる。
class AttendanceTimeChip extends StatelessWidget {
  /// 現在の時刻（null の場合は "—" 表示）
  final DateTime? time;

  /// ラベル（例: "入室", "退室"）
  final String label;

  /// 時刻が変更された際のコールバック
  final Future<void> Function(DateTime newTime)? onTimeChanged;

  /// 編集不可フラグ（欠席時など）
  final bool readOnly;

  const AttendanceTimeChip({
    super.key,
    required this.label,
    this.time,
    this.onTimeChanged,
    this.readOnly = false,
  });

  Future<void> _onTap(BuildContext context) async {
    if (readOnly || onTimeChanged == null) return;

    final initial = time != null
        ? TimeOfDay(hour: time!.hour, minute: time!.minute)
        : TimeOfDay.now();

    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: '$label時刻を修正',
      confirmText: '確定',
      cancelText: 'キャンセル',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );

    if (picked == null) return;
    if (!context.mounted) return;

    // 現在の日付を保持したまま時刻のみ変更
    final base = time ?? DateTime.now();
    final newTime = DateTime(
      base.year,
      base.month,
      base.day,
      picked.hour,
      picked.minute,
    );
    await onTimeChanged!(newTime);
  }

  @override
  Widget build(BuildContext context) {
    final hasTime = time != null;
    final timeStr = hasTime ? _formatTime(time!) : '—';
    final canEdit = !readOnly && onTimeChanged != null;

    return InkWell(
      onTap: canEdit ? () => _onTap(context) : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: hasTime
              ? AppColors.secondary.withValues(alpha: 0.08)
              : Colors.grey.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasTime
                ? AppColors.secondary.withValues(alpha: 0.3)
                : Colors.grey.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                color: hasTime
                    ? AppColors.secondary
                    : AppColors.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 1),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeStr,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: hasTime
                        ? AppColors.onSurface
                        : AppColors.onSurfaceVariant,
                  ),
                ),
                if (canEdit && hasTime) ...[
                  const SizedBox(width: 2),
                  Icon(
                    Icons.edit,
                    size: 10,
                    color: AppColors.secondary.withValues(alpha: 0.6),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
