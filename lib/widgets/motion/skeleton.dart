import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_theme.dart';

/// スケルトン骨格の塗り色（ブランド色には依存しない中立グレー）
const Color kSkeletonColor = Color(0xFFE3E3E3);

/// スケルトン全体を 1 枚のレイヤーとして opacity だけ往復させる（パルス）。
///
/// シマー（ShaderMask）は saveLayer が走り Flutter Web では重いため、
/// opacity のみを動かすパルスを採用している。コントローラはこのウィジェットに
/// 1 つだけで、子の骨格（SkeletonBox 等）は静的な Container。
///
/// reduce-motion / テスト用フラグでは静止（opacity 固定）。
class SkeletonPulse extends StatefulWidget {
  final Widget child;
  const SkeletonPulse({super.key, required this.child});

  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  bool _looping = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: AppMotion.pulsePeriod);
    _opacity = Tween<double>(begin: AppMotion.pulseMin, end: AppMotion.pulseMax)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shouldLoop = AppMotion.loopingEnabled(context);
    if (shouldLoop == _looping) return;
    _looping = shouldLoop;
    if (shouldLoop) {
      _ctrl.repeat(reverse: true);
    } else {
      _ctrl.stop();
      // 静止時は中間の濃さで固定（骨格が読み取れる程度）
      _ctrl.value = 0.6;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '読み込み中',
      container: true,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: FadeTransition(opacity: _opacity, child: widget.child),
        ),
      ),
    );
  }
}

/// 骨格の 1 パーツ（角丸の塗りつぶし）。静的で軽い。
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double? height;
  final double radius;
  final Color color;

  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = 6,
    this.color = kSkeletonColor,
  });

  /// テキスト 1 行ぶんの骨格
  const SkeletonBox.line({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 4,
    this.color = kSkeletonColor,
  });

  /// 円（アイコン・アバター用）
  const SkeletonBox.circle({
    super.key,
    required double size,
    this.color = kSkeletonColor,
  })  : width = size,
        height = size,
        radius = 999;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 白いカード枠の骨格（影なし。実カードの外形に合わせる）
class SkeletonCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  const SkeletonCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.radius = AppTheme.cardBorderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: AppColors.divider),
      ),
      child: child,
    );
  }
}
