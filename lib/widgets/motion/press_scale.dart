import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';

/// 押している間だけ子を scale で縮める（transform のみ・レイアウト不変）。
///
/// - Listener でポインタを観測するだけなので、子の InkWell / GestureDetector の
///   ジェスチャ（タップ・スクロール・長押し・ホバー）には一切干渉しない
/// - 次の場合は押下状態を必ず解除する（縮んだまま残らない）:
///   ポインタ up / cancel、タッチスロップを超える移動（＝スクロール開始）、
///   [enabled] が false に変わった、reduce-motion に切り替わった
/// - 無効（[enabled] = false）・reduce-motion では縮めない
/// - ウィジェット木の形は常に同じ（設定が変わっても子の State を失わない）
/// - キーボード操作（Enter / Space）は子のボタンがそのまま処理する。
///   scale はポインタ専用の視覚効果で、フォーカス表示はテーマ側の責務
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
  int? _pointer;
  Offset? _origin;

  /// テスト用: 現在押下状態として縮めているか
  @visibleForTesting
  bool get debugIsPressed => _down;

  void _set(bool v) {
    if (_down == v || !mounted) return;
    setState(() => _down = v);
  }

  void _release() {
    _pointer = null;
    _origin = null;
    _set(false);
  }

  @override
  void didUpdateWidget(PressableScale old) {
    super.didUpdateWidget(old);
    if (!widget.enabled && _down) {
      _pointer = null;
      _origin = null;
      _down = false; // build 中なので setState 不要
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context) && _down) {
      _pointer = null;
      _origin = null;
      _down = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && !AppMotion.reduced(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (!active || _pointer != null) return;
        _pointer = e.pointer;
        _origin = e.position;
        _set(true);
      },
      onPointerMove: (e) {
        if (e.pointer != _pointer || _origin == null) return;
        // スクロール・ドラッグが始まったら押下表示をやめる
        if ((e.position - _origin!).distance > kTouchSlop) _release();
      },
      onPointerUp: (e) {
        if (e.pointer == _pointer) _release();
      },
      onPointerCancel: (e) {
        if (e.pointer == _pointer) _release();
      },
      child: AnimatedScale(
        scale: (active && _down) ? widget.scale : 1.0,
        duration: active ? AppMotion.fast : Duration.zero,
        curve: AppMotion.standard,
        child: widget.child,
      ),
    );
  }
}
