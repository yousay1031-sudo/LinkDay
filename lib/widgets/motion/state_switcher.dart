import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';

/// 「最重要情報」用の状態切替。
///
/// 業務上の最重要情報（LINE 応募の確定者・欠席ステータス・集計数値）は、
/// 切替の途中でも一瞬たりとも見えなくならないことを最優先する。
///  - 旧表示は切替と同時に取り除く（フェードアウトで薄くしない）
///  - 新表示は不透明度 0.7 から始めて 250ms 以内に 1.0（0 から始めない）
///  - わずかな上方向スライド（4dp）で「変わった」ことだけを伝える
///
/// reduce-motion では即時に置き換える。
class StateSwitcher extends StatelessWidget {
  /// 状態が変わったときに変わる値（Key の元）
  final Object stateKey;
  final Widget child;
  final AlignmentGeometry alignment;

  const StateSwitcher({
    super.key,
    required this.stateKey,
    required this.child,
    this.alignment = Alignment.centerLeft,
  });

  static const double _startOpacity = 0.7;
  static const double _slide = 4;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) {
      return KeyedSubtree(key: ValueKey(stateKey), child: child);
    }
    return AnimatedSwitcher(
      duration: AppMotion.normal,
      reverseDuration: Duration.zero,
      switchInCurve: AppMotion.standard,
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: [...previous, if (current != null) current],
      ),
      transitionBuilder: (child, animation) {
        final opacity =
            Tween<double>(begin: _startOpacity, end: 1).animate(animation);
        return FadeTransition(
          opacity: opacity,
          child: AnimatedBuilder(
            animation: animation,
            child: child,
            builder: (context, c) => Transform.translate(
              offset: Offset(0, (1 - animation.value) * _slide),
              child: c,
            ),
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey(stateKey), child: child),
    );
  }
}

/// 数値の変化を StateSwitcher で見せる（0.7→1.0 + 4dp）。
/// 値が変わらない再ビルドでは何も起きない。
class AnimatedCount extends StatelessWidget {
  final int value;
  final TextStyle? style;

  const AnimatedCount({super.key, required this.value, this.style});

  @override
  Widget build(BuildContext context) {
    return StateSwitcher(
      stateKey: value,
      alignment: Alignment.center,
      child: Text('$value', style: style),
    );
  }
}
