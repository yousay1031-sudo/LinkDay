import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'staggered.dart';

/// 空状態（データ 0 件）の共通表示: アイコン + 案内文 + 次の操作への導線。
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;

  /// 次の操作への導線（ボタン等）
  final List<Widget> actions;

  /// アイコンの色（既定は薄いグレー）
  final Color? iconColor;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actions = const [],
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? AppColors.onSurfaceVariant;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.space4),
        child: StaggeredItem(
          index: 0,
          total: 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child:
                    Icon(icon, size: 48, color: color.withValues(alpha: 0.6)),
              ),
              const SizedBox(height: AppTheme.space3),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurface,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: AppTheme.space1),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: AppTheme.space3),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: AppTheme.space1,
                  runSpacing: AppTheme.space1,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
