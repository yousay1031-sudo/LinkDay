import 'package:flutter/material.dart';

import 'reduced_motion_query_stub.dart'
    if (dart.library.js_interop) 'reduced_motion_query_web.dart' as query;

/// OS の「視差効果を減らす / アニメーションを減らす」を
/// `MediaQuery.disableAnimations` に反映するスコープ。
///
/// Flutter 3.35 の Web エンジンは CSS の `prefers-reduced-motion` を
/// `AccessibilityFeatures.disableAnimations` に反映しない
/// （engine の computeAccessibilityFeatures は highContrast のみ設定）。
/// そのため Web ではここで matchMedia を購読し、MediaQuery を上書きする。
/// Android 等ではエンジン側が反映済みなので素通しする。
///
/// MaterialApp.builder で包むこと（全画面・ダイアログに効く）。
class ReducedMotionScope extends StatefulWidget {
  final Widget child;
  const ReducedMotionScope({super.key, required this.child});

  @override
  State<ReducedMotionScope> createState() => _ReducedMotionScopeState();
}

class _ReducedMotionScopeState extends State<ReducedMotionScope> {
  bool _reduce = false;
  void Function()? _unsubscribe;

  @override
  void initState() {
    super.initState();
    _reduce = query.prefersReducedMotion();
    _unsubscribe = query.listenReducedMotion((v) {
      if (mounted && v != _reduce) setState(() => _reduce = v);
    });
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null || !_reduce || mq.disableAnimations) return widget.child;
    return MediaQuery(
      data: mq.copyWith(disableAnimations: true),
      child: widget.child,
    );
  }
}
