import 'package:flutter/material.dart';

import '../services/monthly_usage_service.dart';
import '../theme/app_theme.dart';

/// 月間支給量の残日数チップ（Day 9）
///
/// 色分け（仕様）:
///   残 > 5        → 通常（secondary）
///   残 1〜5       → 橙（warning）
///   残 0 以下     → 赤（error）
///   見込み超過    → 赤枠 + 警告アイコン
class MonthlyUsageChip extends StatelessWidget {
  final MonthlyUsage usage;
  final bool compact;

  const MonthlyUsageChip({
    super.key,
    required this.usage,
    this.compact = false,
  });

  /// 残日数に応じた基本色
  static Color colorFor(MonthlyUsage u) {
    if (u.isExhausted) return AppColors.error;
    if (u.isLow) return AppColors.warning;
    return AppColors.secondary;
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(usage);
    final over = usage.isOverProjected;
    // 見込み超過は赤枠で強調（基本色が橙/青でも枠は赤）
    final borderColor = over ? AppColors.error : color.withValues(alpha: 0.4);

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor, width: over ? 1.5 : 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (over) ...[
            Icon(Icons.warning_amber_rounded,
                size: compact ? 11 : 13, color: AppColors.error),
            SizedBox(width: compact ? 3 : 4),
          ],
          Text(
            compact ? usage.usageLabel : usage.chipLabel,
            softWrap: false,
            style: TextStyle(
              fontSize: compact ? 10 : 11.5,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 支給超過見込みの警告バナー（児童詳細セクション用）
class OverProjectedBanner extends StatelessWidget {
  final MonthlyUsage usage;

  const OverProjectedBanner({super.key, required this.usage});

  @override
  Widget build(BuildContext context) {
    if (!usage.isOverProjected) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 18, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '今月の支給日数を超過する見込みです。'
                  '超過分は利用者負担となる可能性があります',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColors.error,
                      fontWeight: FontWeight.w600,
                      height: 1.4),
                ),
                const SizedBox(height: 3),
                Text(
                  '支給量 ${usage.available}日 / 見込み ${usage.projectedTotal}日'
                  '（超過 ${usage.overProjectedDays}日）',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 当月カレンダー（実績=緑 / 予定=青 / 欠席=灰 / 今日=枠線）
class MonthlyUsageCalendar extends StatelessWidget {
  final MonthlyUsage usage;
  final DateTime today;

  const MonthlyUsageCalendar({
    super.key,
    required this.usage,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final lastDay = MonthlyUsageService.lastDayOfMonth(usage.month);
    // 月初の曜日（月曜始まりのグリッドに揃えるための先頭空白数）
    final firstWeekday = DateTime(usage.month.year, usage.month.month, 1).weekday;
    final leading = firstWeekday - 1; // 月曜=1 → 0 個
    final isCurrentMonth = MonthlyUsageService.isSameMonth(usage.month, today);

    const dayLabels = ['月', '火', '水', '木', '金', '土', '日'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 曜日ヘッダー
        Row(
          children: [
            for (int i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(
                    dayLabels[i],
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: i == 5
                          ? AppColors.secondary
                          : i == 6
                              ? AppColors.error
                              : AppColors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 3,
            crossAxisSpacing: 3,
            childAspectRatio: 1,
          ),
          itemCount: leading + lastDay,
          itemBuilder: (_, i) {
            if (i < leading) return const SizedBox.shrink();
            final day = i - leading + 1;
            final kind = usage.dayKinds[day] ?? DayUsageKind.none;
            final isToday = isCurrentMonth && today.day == day;

            final (bg, fg) = switch (kind) {
              DayUsageKind.actual => (AppColors.success, Colors.white),
              DayUsageKind.planned => (AppColors.secondary, Colors.white),
              DayUsageKind.absent => (AppColors.divider, AppColors.onSurfaceVariant),
              DayUsageKind.none => (Colors.transparent, AppColors.onSurfaceVariant),
            };

            return Container(
              decoration: BoxDecoration(
                color: kind == DayUsageKind.none
                    ? Colors.transparent
                    : bg.withValues(alpha: kind == DayUsageKind.absent ? 0.6 : 0.85),
                borderRadius: BorderRadius.circular(5),
                border: isToday
                    ? Border.all(color: AppColors.primary, width: 2)
                    : Border.all(color: AppColors.divider.withValues(alpha: 0.5)),
              ),
              alignment: Alignment.center,
              child: Text(
                '$day',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight:
                      isToday || kind != DayUsageKind.none ? FontWeight.w700 : FontWeight.normal,
                  color: kind == DayUsageKind.none ? fg : fg,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        // 凡例
        Wrap(
          spacing: 10,
          runSpacing: 4,
          children: [
            _legend('実績', AppColors.success),
            _legend('予定', AppColors.secondary),
            _legend('欠席', AppColors.divider),
            _legend('今日', Colors.transparent, border: AppColors.primary),
          ],
        ),
      ],
    );
  }

  Widget _legend(String label, Color color, {Color? border}) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                  color: border ?? AppColors.divider,
                  width: border != null ? 2 : 1),
            ),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: AppColors.onSurfaceVariant)),
        ],
      );
}

/// 数値サマリー（支給量 / 実績 / 今後予定 / 実績残 / 見込み残）
class MonthlyUsageStats extends StatelessWidget {
  final MonthlyUsage usage;

  const MonthlyUsageStats({super.key, required this.usage});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            _stat('支給量', '${usage.available}', AppColors.onSurface,
                suffix: '日',
                note: usage.availableFallback
                    ? '設定値${usage.rawAvailable}→既定'
                    : null),
            _stat('実績', '${usage.usedActual}', AppColors.success, suffix: '日'),
            _stat('今後予定', '${usage.plannedRemaining}', AppColors.secondary,
                suffix: '日'),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _stat('実績残', '${usage.remainingActual}',
                usage.isExhausted
                    ? AppColors.error
                    : usage.isLow
                        ? AppColors.warning
                        : AppColors.success,
                suffix: '日'),
            _stat(
                '見込み残',
                '${usage.remainingProjected}',
                usage.isOverProjected ? AppColors.error : AppColors.success,
                suffix: '日',
                note: usage.isOverProjected
                    ? '超過${usage.overProjectedDays}日'
                    : null),
            _stat('見込み合計', '${usage.projectedTotal}', AppColors.onSurfaceVariant,
                suffix: '日'),
          ],
        ),
      ],
    );
  }

  Widget _stat(String label, String value, Color color,
          {String suffix = '', String? note}) =>
      Expanded(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value,
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w700, color: color)),
                if (suffix.isNotEmpty)
                  Text(suffix,
                      style: TextStyle(fontSize: 11, color: color)),
              ],
            ),
            Text(label,
                style: const TextStyle(
                    fontSize: 10.5, color: AppColors.onSurfaceVariant)),
            if (note != null)
              Text(note,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 9, color: color)),
          ],
        ),
      );
}
