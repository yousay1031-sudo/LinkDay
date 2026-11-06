import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';

/// 入場演出の「窓」。リスト 1 つにつき 1 つ持つ。
///
/// 窓が開いている間に build された要素だけが入場アニメを行い、
/// 窓が閉じた後（= スクロールで後から現れた要素・再ビルド）は即時表示する。
/// これによりスクロール中にカードがもたつきながら現れることを防ぐ。
class StaggerGroup {
  bool _open = true;
  Timer? _timer;

  StaggerGroup() {
    // 入場シーケンスの合計（遅延＋本体）が過ぎたら閉じる
    _timer = Timer(AppMotion.staggerTotal, () => _open = false);
  }

  bool get isOpen => _open;

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// [StaggerGroup] の寿命をウィジェットツリーに結びつける。
/// 内容が初めて表示されるとき（スケルトン→実体）に新しい窓が作られる。
class StaggerScope extends StatefulWidget {
  final Widget child;
  const StaggerScope({super.key, required this.child});

  static StaggerGroup? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_StaggerInherited>()?.group;

  @override
  State<StaggerScope> createState() => _StaggerScopeState();
}

class _StaggerScopeState extends State<StaggerScope> {
  late final StaggerGroup _group = StaggerGroup();

  @override
  void dispose() {
    _group.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _StaggerInherited(group: _group, child: widget.child);
}

class _StaggerInherited extends InheritedWidget {
  final StaggerGroup group;
  const _StaggerInherited({required this.group, required super.child});

  @override
  bool updateShouldNotify(_StaggerInherited old) => old.group != group;
}

/// リスト・カードの入場（opacity 0→1 + translateY 12dp→0）。
///
/// - 遅延は index × 35ms、ただし index 9 で頭打ち（合計 600ms 以内）
/// - total が 50 件超のときは先頭 10 件のみ（以降は即時表示）
/// - [StaggerScope] の窓が閉じた後に build された要素は即時表示
/// - reduce-motion では即時表示
/// - 完了後は RepaintBoundary 付きの素の子に戻る（常時のレイヤー負荷なし）
class StaggeredItem extends StatefulWidget {
  final int index;
  final int total;
  final Widget child;

  const StaggeredItem({
    super.key,
    required this.index,
    required this.total,
    required this.child,
  });

  @override
  State<StaggeredItem> createState() => _StaggeredItemState();
}

class _StaggeredItemState extends State<StaggeredItem>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  Animation<double>? _t;
  Timer? _delayTimer;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;

    final group = StaggerScope.maybeOf(context);
    final animate = !AppMotion.reduced(context) &&
        AppMotion.shouldStagger(widget.index, widget.total) &&
        (group?.isOpen ?? true);
    if (!animate) return;

    final c = AnimationController(vsync: this, duration: AppMotion.normal);
    _ctrl = c;
    _t = CurvedAnimation(parent: c, curve: AppMotion.standard);
    final step = widget.index.clamp(0, AppMotion.staggerMaxIndex);
    final delay = AppMotion.staggerStep * step;
    if (delay == Duration.zero) {
      c.forward();
    } else {
      _delayTimer = Timer(delay, () {
        if (mounted) c.forward();
      });
    }
    c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    final t = _t;
    if (c == null || t == null || c.isCompleted) {
      return RepaintBoundary(child: widget.child);
    }
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: t,
        child: widget.child,
        builder: (context, child) => Opacity(
          opacity: t.value,
          child: Transform.translate(
            offset: Offset(0, (1 - t.value) * AppMotion.entranceSlide),
            child: child,
          ),
        ),
      ),
    );
  }
}
