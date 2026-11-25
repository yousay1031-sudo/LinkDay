// Flutter 3.50 で widgets.dart は非推奨ではない（material.dart は使わない）
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 入力中の欄が、スクロールで画面（スクロールの表示範囲）の外に完全に出たら
/// フォーカスを外す。
///
/// 理由（Flutter Web の不具合への対処）:
/// 読み上げ（semantics）が有効なブラウザでは、入力欄ごとに DOM の `<input>` が作られる。
/// フォーカスのある入力欄は画面外でも保持されるが、`<input>` は画面外に出ると消え、
/// 戻ってきたときに空の `<input>` が新しく作られる。エンジンはその空の値を
/// 「入力された内容」としてアプリに送り返すため、保存前の入力が消える
/// （engine: semantics/text_field.dart の activate → selectionchange → handleChange）。
/// フォーカスを外した入力欄ではこの送り返しが起きないことを確かめたので、
/// 画面外に出た時点でフォーカスを外す。入力した内容はそのまま残る。
///
/// 外すのは、スクロールが入力欄を表示範囲から遠ざけているときだけ。隠れていた入力中の欄を
/// 見える所まで動かすスクロール（カーソルを見せるための自動スクロールなど）では外さない。
class UnfocusOffscreenTextField extends StatelessWidget {
  const UnfocusOffscreenTextField({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (n) {
        unfocusIfOffscreen(scrollDelta: n.scrollDelta);
        return false;
      },
      child: child,
    );
  }

  /// 入力中の欄が表示範囲の外に完全に出ていればフォーカスを外す（外したら true）。
  ///
  /// [scrollDelta] は今回のスクロール量（正 = 先へ進む）。欄が表示範囲の前（上）にあって
  /// 戻る向き、または後ろ（下）にあって進む向きのスクロールは、欄を見せる方向なので外さない。
  @visibleForTesting
  static bool unfocusIfOffscreen({double? scrollDelta}) {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (focus == null || ctx == null || !ctx.mounted) return false;
    // 文字の入力欄だけ（ボタン等のフォーカスはそのまま）
    if (ctx.findAncestorWidgetOfExactType<EditableText>() == null) return false;
    final scrollable = Scrollable.maybeOf(ctx);
    final box = ctx.findRenderObject();
    if (scrollable == null || box is! RenderBox || !box.hasSize) return false;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return false;
    final position = scrollable.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return false;
    }
    // 入力欄の上端が表示範囲の上端に来るときのスクロール位置 = 入力欄の位置
    final start = viewport.getOffsetToReveal(box, 0.0).offset;
    final extent =
        position.axis == Axis.vertical ? box.size.height : box.size.width;
    final visibleStart = position.pixels;
    final visibleEnd = position.pixels + position.viewportDimension;
    final delta = scrollDelta ?? 0;
    // 後ろ（下）に出ていて遠ざかる / 前（上）に出ていて遠ざかる
    final awayAfter = start >= visibleEnd && delta <= 0;
    final awayBefore = start + extent <= visibleStart && delta >= 0;
    if (!awayAfter && !awayBefore) return false;
    focus.unfocus();
    return true;
  }
}
