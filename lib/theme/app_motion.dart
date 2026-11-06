import 'package:flutter/material.dart';

/// モーションの一元定義（duration / curve / 閾値）。
///
/// すべてのアニメーション部品はここの値だけを参照する。
/// 数値を変えたいときはこのファイルだけを触ればよい。
///
/// パフォーマンス方針（Flutter Web 前提）:
///  - アニメ対象は opacity / transform のみ。width・height・padding は動かさない
///  - BackdropFilter / ImageFilter.blur は使用禁止（test/ui/ui_guard_test.dart で検査）
///  - OS の「アニメーションを減らす」(MediaQuery.disableAnimations) では全て無効化
class AppMotion {
  AppMotion._();

  // ── duration ──────────────────────────────────────────────
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  // ── curve ─────────────────────────────────────────────────
  static const Curve standard = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;

  /// 成功チェックのみで使う（少しだけ弾む）
  static const Curve emphasized = Curves.easeOutBack;

  // ── 押下フィードバック ────────────────────────────────────
  static const double buttonPressedScale = 0.97;
  static const double cardPressedScale = 0.98;

  // ── 移動量 ───────────────────────────────────────────────
  /// 画面遷移のスライド量（dp）
  static const double pageSlide = 12;

  /// リスト・カード入場の translateY（dp）
  static const double entranceSlide = 12;

  // ── スタガー入場 ─────────────────────────────────────────
  /// 1 要素ごとの遅延
  static const Duration staggerStep = Duration(milliseconds: 35);

  /// 遅延を積み上げる最大インデックス（これ以降は同じ遅延で同時入場）。
  /// 合計 = 35ms × 9 + 250ms = 565ms ≦ 600ms
  static const int staggerMaxIndex = 9;

  /// この件数を超えるリストでは先頭 [staggerHeadCount] 件のみ入場アニメ
  static const int staggerListLimit = 50;
  static const int staggerHeadCount = 10;

  /// スタガー入場の合計時間（遅延 + 本体）
  static Duration get staggerTotal =>
      staggerStep * staggerMaxIndex + normal;

  // ── スケルトン ───────────────────────────────────────────
  /// スケルトンの最低表示時間（読込が速すぎても点滅させない）
  static const Duration skeletonMinDisplay = Duration(milliseconds: 300);

  /// パルス 1 往復の時間
  static const Duration pulsePeriod = Duration(milliseconds: 1100);
  static const double pulseMin = 0.4;
  static const double pulseMax = 0.9;

  // ── テスト用 ─────────────────────────────────────────────
  /// true にすると無限ループするアニメ（スケルトンのパルス・在室ドット）を止める。
  /// ループが残っていると pumpAndSettle が永遠に完了しないため、
  /// pumpAndSettle を使うテストの setUp で true にする。
  @visibleForTesting
  static bool debugDisableLooping = false;

  // ── 判定ヘルパー ─────────────────────────────────────────
  /// OS の「アニメーションを減らす」設定が有効か
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// reduce-motion のとき Duration.zero を返す
  static Duration scaled(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;

  /// 無限ループアニメを動かしてよいか
  static bool loopingEnabled(BuildContext context) =>
      !debugDisableLooping && !reduced(context);

  /// このインデックスの要素に入場アニメを付けるか
  static bool shouldStagger(int index, int total) =>
      total <= staggerListLimit || index < staggerHeadCount;
}
