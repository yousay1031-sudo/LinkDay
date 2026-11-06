import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';

/// 画面遷移: フェード + 右から 12dp のスライド（全プラットフォーム共通）。
///
/// 旧画面側（secondaryAnimation）は動かさない（描画コストを抑える）。
/// transform と opacity のみ。reduce-motion のときは遷移なし。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.normal;

  @override
  Duration get reverseTransitionDuration => AppMotion.fast;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.reduced(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: AppMotion.standard,
      reverseCurve: AppMotion.exit,
    );
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        child: child,
        builder: (context, c) => Transform.translate(
          offset: Offset((1 - curved.value) * AppMotion.pageSlide, 0),
          child: c,
        ),
      ),
    );
  }
}
