import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';

/// 処理中スピナー（CircularProgressIndicator の薄いラッパー）。
///
/// 標準のスピナーは OS の「アニメーションを減らす」設定でも回り続けるため、
/// reduce-motion（またはテスト用のループ停止フラグ）のときは
/// 回転しない静的な円弧（value 固定）を表示する。
/// 「処理中であること」は呼び出し側のラベル（「保存中…」等）で伝える。
class AppSpinner extends StatelessWidget {
  final double strokeWidth;
  final Color? color;
  final Animation<Color?>? valueColor;
  final String? semanticsLabel;

  const AppSpinner({
    super.key,
    this.strokeWidth = 4.0,
    this.color,
    this.valueColor,
    this.semanticsLabel,
  });

  /// 静止時に描く円弧の割合
  static const double staticValue = 0.7;

  @override
  Widget build(BuildContext context) {
    final animate = AppMotion.loopingEnabled(context);
    return CircularProgressIndicator(
      value: animate ? null : staticValue,
      strokeWidth: strokeWidth,
      color: color,
      valueColor: valueColor,
      semanticsLabel: semanticsLabel ?? '処理中',
    );
  }
}
