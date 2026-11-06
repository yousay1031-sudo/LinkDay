import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';

/// 押している間だけ子を scale で縮める（transform のみ・レイアウト不変）。
///
/// Listener でポインタを観測するだけなので、子の InkWell / GestureDetector の
/// ジェスチャ（タップ・スクロール・長押し）には一切干渉しない。
/// reduce-motion のときは何もしない（素の子を返す）。
class PressableScale extends StatefulWidget {
  final Widget child;
  final double scale;
  final bool enabled;

  const PressableScale({
    super.key,
    required this.child,
    this.scale = AppMotion.cardPressedScale,
    this.enabled = true,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v || !mounted) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || AppMotion.reduced(context)) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        child: widget.child,
      ),
    );
  }
}
