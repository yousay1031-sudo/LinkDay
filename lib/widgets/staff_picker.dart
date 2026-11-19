// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/staff_session.dart';
import '../models/staff.dart';
import '../services/staff_service.dart';
import '../theme/app_theme.dart';

/// 担当者を選ぶダイアログ。選ばれた職員を返す（キャンセルは null）。
///
/// [reason] を渡すと見出しの下に表示する（記録しようとして求められた場合など）。
/// 選択の保存は呼び出し側ではなくここで行う（StaffSession.select）。
Future<Staff?> showStaffPicker(BuildContext context, {String? reason}) {
  return showDialog<Staff>(
    context: context,
    builder: (ctx) => _StaffPickerDialog(reason: reason),
  );
}

class _StaffPickerDialog extends StatelessWidget {
  const _StaffPickerDialog({this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([StaffService.instance, StaffSession.instance]),
      builder: (context, _) {
        final staff = StaffService.instance.getActiveStaff();
        final currentId = StaffSession.instance.current?.id;
        return AlertDialog(
          key: const Key('staffPickerDialog'),
          title: const Row(
            children: [
              Icon(Icons.badge_outlined, color: AppColors.primary),
              SizedBox(width: 8),
              Text('担当者を選んでください'),
            ],
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (reason != null) ...[
                  Text(reason!,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.onSurfaceVariant)),
                  const SizedBox(height: 12),
                ],
                if (staff.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '職員がまだ登録されていません。\n'
                      '設定画面の「職員（担当者）」から名前を追加してください。',
                      key: Key('staffPickerEmpty'),
                      style: TextStyle(height: 1.6),
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final s in staff)
                          ListTile(
                            key: Key('staffPick_${s.id}'),
                            leading: Icon(
                              s.id == currentId
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              color: s.id == currentId
                                  ? AppColors.primary
                                  : AppColors.onSurfaceVariant,
                            ),
                            title: Text(s.name,
                                style: const TextStyle(fontSize: 16)),
                            minVerticalPadding: 12,
                            onTap: () async {
                              await StaffSession.instance.select(s);
                              if (context.mounted) Navigator.of(context).pop(s);
                            },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }
}
