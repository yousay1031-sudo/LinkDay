import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import 'press_scale.dart';

/// 押下フィードバック付きボタン群。
///
/// 標準ボタンを PressableScale（scale 0.97・transform のみ）で包むだけの薄いラッパー。
/// - key / onPressed / style / child などは内側の標準ボタンへそのまま渡す
///   （`find.byKey` や `tester.widget<IconButton>` は従来どおり内側のボタンに当たる）
/// - レイアウトは標準ボタンと同一（Listener と Transform は制約を素通しする）
/// - 無効（onPressed == null）のときは縮めない
/// - elevation の変化は AppTheme 側（押下で 0 へ段階変化・影はアニメさせない）

class AppElevatedButton extends StatelessWidget {
  final Key? buttonKey;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final Widget? child;
  final Widget? _icon;
  final Widget? _label;

  const AppElevatedButton({
    Key? key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    required this.child,
  })  : buttonKey = key,
        _icon = null,
        _label = null,
        super(key: null);

  const AppElevatedButton.icon({
    Key? key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    required Widget icon,
    required Widget label,
  })  : buttonKey = key,
        child = null,
        _icon = icon,
        _label = label,
        super(key: null);

  @override
  Widget build(BuildContext context) {
    final b = _icon != null
        ? ElevatedButton.icon(
            key: buttonKey,
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            icon: _icon,
            label: _label!,
          )
        : ElevatedButton(
            key: buttonKey,
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            child: child,
          );
    return PressableScale(
        scale: AppMotion.buttonPressedScale,
        enabled: onPressed != null,
        child: b);
  }
}

class AppFilledButton extends StatelessWidget {
  final Key? buttonKey;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final bool autofocus;
  final Widget? child;
  final Widget? _icon;
  final Widget? _label;

  const AppFilledButton({
    Key? key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.autofocus = false,
    required this.child,
  })  : buttonKey = key,
        _icon = null,
        _label = null,
        super(key: null);

  const AppFilledButton.icon({
    Key? key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.autofocus = false,
    required Widget icon,
    required Widget label,
  })  : buttonKey = key,
        child = null,
        _icon = icon,
        _label = label,
        super(key: null);

  @override
  Widget build(BuildContext context) {
    final b = _icon != null
        ? FilledButton.icon(
            key: buttonKey,
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            autofocus: autofocus,
            icon: _icon,
            label: _label!,
          )
        : FilledButton(
            key: buttonKey,
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            autofocus: autofocus,
            child: child!,
          );
    return PressableScale(
        scale: AppMotion.buttonPressedScale,
        enabled: onPressed != null,
        child: b);
  }
}

class AppOutlinedButton extends StatelessWidget {
  final Key? buttonKey;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final Widget? child;
  final Widget? _icon;
  final Widget? _label;

  const AppOutlinedButton({
    Key? key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    required this.child,
  })  : buttonKey = key,
        _icon = null,
        _label = null,
        super(key: null);

  const AppOutlinedButton.icon({
    Key? key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    required Widget icon,
    required Widget label,
  })  : buttonKey = key,
        child = null,
        _icon = icon,
        _label = label,
        super(key: null);

  @override
  Widget build(BuildContext context) {
    final b = _icon != null
        ? OutlinedButton.icon(
            key: buttonKey,
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            icon: _icon,
            label: _label!,
          )
        : OutlinedButton(
            key: buttonKey,
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            child: child,
          );
    return PressableScale(
        scale: AppMotion.buttonPressedScale,
        enabled: onPressed != null,
        child: b);
  }
}

class AppTextButton extends StatelessWidget {
  final Key? buttonKey;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final Widget? child;
  final Widget? _icon;
  final Widget? _label;

  const AppTextButton({
    Key? key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    required this.child,
  })  : buttonKey = key,
        _icon = null,
        _label = null,
        super(key: null);

  const AppTextButton.icon({
    Key? key,
    required this.onPressed,
    this.onLongPress,
    this.style,
    required Widget icon,
    required Widget label,
  })  : buttonKey = key,
        child = null,
        _icon = icon,
        _label = label,
        super(key: null);

  @override
  Widget build(BuildContext context) {
    final b = _icon != null
        ? TextButton.icon(
            key: buttonKey,
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            icon: _icon,
            label: _label!,
          )
        : TextButton(
            key: buttonKey,
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: style,
            child: child!,
          );
    return PressableScale(
        scale: AppMotion.buttonPressedScale,
        enabled: onPressed != null,
        child: b);
  }
}

class AppIconButton extends StatelessWidget {
  final Key? buttonKey;
  final VoidCallback? onPressed;
  final Widget icon;
  final String? tooltip;
  final Color? color;
  final double? iconSize;
  final EdgeInsetsGeometry? padding;
  final BoxConstraints? constraints;
  final VisualDensity? visualDensity;

  const AppIconButton({
    Key? key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.color,
    this.iconSize,
    this.padding,
    this.constraints,
    this.visualDensity,
  })  : buttonKey = key,
        super(key: null);

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      scale: AppMotion.buttonPressedScale,
      enabled: onPressed != null,
      child: IconButton(
        key: buttonKey,
        onPressed: onPressed,
        icon: icon,
        tooltip: tooltip,
        color: color,
        iconSize: iconSize,
        padding: padding,
        constraints: constraints,
        visualDensity: visualDensity,
      ),
    );
  }
}

class AppExtendedFab extends StatelessWidget {
  final Key? buttonKey;
  final VoidCallback? onPressed;
  final Widget icon;
  final Widget label;
  final Color? backgroundColor;
  final Color? foregroundColor;

  const AppExtendedFab({
    Key? key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.backgroundColor,
    this.foregroundColor,
  })  : buttonKey = key,
        super(key: null);

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      scale: AppMotion.buttonPressedScale,
      enabled: onPressed != null,
      child: FloatingActionButton.extended(
        key: buttonKey,
        onPressed: onPressed,
        icon: icon,
        label: label,
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
      ),
    );
  }
}
