import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_theme.dart';

/// 読込中はスケルトン、完了で実体へクロスフェードする切替ゲート。
///
/// - 最低表示時間（既定 300ms）: 骨格を出した時点から [minDisplay] が経つまで
///   実体への切替を遅らせる（読込が速すぎても骨格が一瞬だけ点滅しない）。
///   Timer で数えるのでテストの偽時計とも整合する
/// - 最初から読込済み（loading=false で生成）なら骨格を出さず即実体（無駄な待ちなし）
/// - [fillParent] = true（既定）: Stack(fit: expand) で骨格と実体を同じ領域に重ねるため
///   切替でレイアウトシフトが起きない（bounded な領域に置くこと）。
///   false: スクロール内など高さが未確定の場所用。骨格を実体と同寸に作ること
/// - エラー時は骨格のまま放置せず、[errorMessage] と再試行ボタンを出す
/// - 骨格レイヤーは IgnorePointer（切替中も実体の操作を妨げない）
/// - reduce-motion ではクロスフェードを即時切替（最低表示時間は守る）
class SkeletonGate extends StatefulWidget {
  /// 読込中か
  final bool loading;

  /// 読込失敗時のメッセージ（null なら正常）
  final String? errorMessage;

  /// 再試行（null なら再試行ボタンを出さない）
  final VoidCallback? onRetry;

  /// 実体と同じ構造を模した骨格
  final Widget skeleton;

  /// 実体
  final WidgetBuilder builder;

  final Duration minDisplay;
  final bool fillParent;

  const SkeletonGate({
    super.key,
    required this.loading,
    required this.skeleton,
    required this.builder,
    this.errorMessage,
    this.onRetry,
    this.minDisplay = AppMotion.skeletonMinDisplay,
    this.fillParent = true,
  });

  @override
  State<SkeletonGate> createState() => _SkeletonGateState();
}

class _SkeletonGateState extends State<SkeletonGate> {
  /// 骨格を出してから最低表示時間が経ったか
  late bool _minElapsed;
  Timer? _minTimer;

  @override
  void initState() {
    super.initState();
    _minElapsed = !widget.loading;
    if (widget.loading) _startMinTimer();
  }

  void _startMinTimer() {
    _minElapsed = false;
    _minTimer?.cancel();
    _minTimer = Timer(widget.minDisplay, () {
      if (!mounted) return;
      setState(() => _minElapsed = true);
    });
  }

  @override
  void didUpdateWidget(SkeletonGate old) {
    super.didUpdateWidget(old);
    // 再読込が始まったら骨格に戻して最低表示時間を数え直す
    if (!old.loading && widget.loading) _startMinTimer();
  }

  @override
  void dispose() {
    _minTimer?.cancel();
    super.dispose();
  }

  /// 骨格を出すべきか: 読込中、または最低表示時間が未経過
  bool get _showSkeleton => widget.loading || !_minElapsed;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (_showSkeleton) {
      child = KeyedSubtree(
        key: const ValueKey('skeleton'),
        child: IgnorePointer(child: widget.skeleton),
      );
    } else if (widget.errorMessage != null) {
      child = KeyedSubtree(
        key: const ValueKey('error'),
        child: ErrorRetry(
          message: widget.errorMessage!,
          onRetry: widget.onRetry,
        ),
      );
    } else {
      child = KeyedSubtree(
        key: const ValueKey('content'),
        child: widget.builder(context),
      );
    }

    final duration = AppMotion.scaled(context, AppMotion.normal);
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: duration,
      switchInCurve: AppMotion.standard,
      switchOutCurve: AppMotion.standard,
      layoutBuilder: (current, previous) => Stack(
        fit: widget.fillParent ? StackFit.expand : StackFit.loose,
        alignment: Alignment.topCenter,
        children: [...previous, if (current != null) current],
      ),
      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
      child: child,
    );
  }
}

/// 読込失敗の表示（エラー文＋再試行ボタン）
class ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorRetry({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.space3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.error),
            const SizedBox(height: AppTheme.space2),
            Text(
              message,
              textAlign: TextAlign.center,
              key: const Key('errorRetryMessage'),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppTheme.space2),
              ElevatedButton.icon(
                key: const Key('errorRetryButton'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('再試行'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(160, AppTheme.buttonHeight),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
