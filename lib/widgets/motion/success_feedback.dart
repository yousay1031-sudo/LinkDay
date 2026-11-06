import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_theme.dart';

/// 保存・確定の成功を伝えるチェックマーク（scale + opacity のみ）。
class SuccessCheck extends StatefulWidget {
  final double size;
  final Color color;

  const SuccessCheck({
    super.key,
    this.size = 20,
    this.color = Colors.white,
  });

  @override
  State<SuccessCheck> createState() => _SuccessCheckState();
}

class _SuccessCheckState extends State<SuccessCheck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: AppMotion.slow);
    _scale = Tween<double>(begin: 0.4, end: 1)
        .animate(CurvedAnimation(parent: _ctrl, curve: AppMotion.emphasized));
    _opacity = CurvedAnimation(
        parent: _ctrl, curve: const Interval(0, 0.5, curve: Curves.easeOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _ctrl.value = 1;
    } else if (_ctrl.status == AnimationStatus.dismissed) {
      _ctrl.forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(
        scale: _scale,
        child: Icon(Icons.check_circle, size: widget.size, color: widget.color),
      ),
    );
  }
}

/// 成功スナックバー（チェックマーク付き）。
///
/// SnackBar 自体の入場はテーマ既定のスライドイン。メッセージ文言は
/// 呼び出し元がそのまま渡す（既存テキストを変えない）。
void showSuccessSnack(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 2),
}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: AppColors.success,
        duration: duration,
        content: Row(
          children: [
            const SuccessCheck(),
            const SizedBox(width: AppTheme.space1),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}
