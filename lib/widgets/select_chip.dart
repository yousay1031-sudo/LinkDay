// Flutter 3.50 で material.dart 全体が非推奨（ほかの画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 押して選ぶ選択肢（業務日誌・個別支援計画・職員管理・利用者の編集・計画の一覧で共通）
///
/// - 選んでも位置と大きさは変わらない（印の場所は最初から確保し、文字の太さも変えない）
/// - 選んだもの: 濃い塗り（主色の濃い色）・白い文字・チェックの印
/// - 選んでいないもの: 白地・枠・空の丸の印（色だけに頼らず、印の形でも分かる）
/// - 見た目の高さも押せる範囲も 48
class SelectChip extends StatelessWidget {
  const SelectChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.fontSize = 14,
  });

  final String label;
  final bool selected;

  /// null なら押せない（見た目も押せない状態）
  final ValueChanged<bool>? onSelected;
  final double fontSize;

  /// 選んだときの塗り（白い文字と十分な差がある濃い色）
  static const Color selectedFill = AppColors.primaryDark;

  @override
  Widget build(BuildContext context) {
    final enabled = onSelected != null;
    final fg = selected
        ? Colors.white
        : (enabled ? AppColors.onSurface : AppColors.onSurfaceVariant);
    return SizedBox(
      height: 48,
      child: FilterChip(
        label: Text(label),
        labelStyle: TextStyle(
            fontSize: fontSize, color: fg, fontWeight: FontWeight.w600),
        avatar: Icon(
          selected ? Icons.check_circle : Icons.circle_outlined,
          size: 18,
          color: selected ? Colors.white : AppColors.onSurfaceVariant,
        ),
        selected: selected,
        onSelected: onSelected,
        showCheckmark: false,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        backgroundColor: Colors.white,
        selectedColor: selectedFill,
        // 押せない状態でも、選んだものは塗りで分かる（少し薄く）
        disabledColor: selected
            ? selectedFill.withValues(alpha: 0.6)
            : const Color(0xFFF2F2F2),
        // 枠の太さも変えない（大きさが変わらないように）
        side: BorderSide(
            color: selected ? selectedFill : AppColors.divider, width: 1.5),
      ),
    );
  }
}
