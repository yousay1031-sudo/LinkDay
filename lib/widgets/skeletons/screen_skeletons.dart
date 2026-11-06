import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../motion/skeleton.dart';

/// 各画面の「最終レイアウトと同構造」のスケルトン集。
///
/// 骨格は実画面と同じ列数・カード比率・行数で組む（クロスフェード時に
/// レイアウトがずれないように）。列数やアスペクト比は実画面側の値を
/// 引数で受け取り、重複定義を避ける。
/// 骨格の中身は静的な Container のみ。パルスは [SkeletonPulse] が 1 枚で担当する。

// ── 共通: グリッド骨格 ─────────────────────────────────────────

class _GridSkeleton extends StatelessWidget {
  final int columns;
  final double aspectRatio;
  final EdgeInsets padding;
  final double spacing;
  final Widget Function(int index) cardBuilder;

  const _GridSkeleton({
    required this.columns,
    required this.aspectRatio,
    required this.padding,
    required this.spacing,
    required this.cardBuilder,
  });

  @override
  Widget build(BuildContext context) {
    // 画面を埋める分だけ（実画面と同じ列数・比率）。スクロールはさせない。
    return SkeletonPulse(
      child: LayoutBuilder(
        builder: (context, c) {
          final cardW =
              (c.maxWidth - padding.horizontal - spacing * (columns - 1)) /
                  columns;
          final cardH = cardW / aspectRatio;
          final rows =
              ((c.maxHeight - padding.vertical + spacing) / (cardH + spacing))
                  .ceil()
                  .clamp(1, 8);
          return ClipRect(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              maxHeight: double.infinity,
              child: Padding(
                padding: padding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var r = 0; r < rows; r++) ...[
                      if (r > 0) SizedBox(height: spacing),
                      Row(
                        children: [
                          for (var col = 0; col < columns; col++) ...[
                            if (col > 0) SizedBox(width: spacing),
                            SizedBox(
                              width: cardW,
                              height: cardH,
                              child: cardBuilder(r * columns + col),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── 出席管理 ──────────────────────────────────────────────────

/// 出席画面: 集計バー（5 チップ）＋カードグリッド
class AttendanceSkeleton extends StatelessWidget {
  final int columns;
  final double aspectRatio;
  final double padding;

  const AttendanceSkeleton({
    super.key,
    required this.columns,
    required this.aspectRatio,
    required this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('attendanceSkeleton'),
      children: [
        // 集計バー（実物: 白背景・横並びチップ・縦 padding 10 / チップ高 ≒ 32）
        SkeletonPulse(
          child: Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: const Row(
              children: [
                SkeletonBox(width: 84, height: 32, radius: 16),
                SizedBox(width: 8),
                SkeletonBox(width: 96, height: 32, radius: 16),
                SizedBox(width: 8),
                SkeletonBox(width: 90, height: 32, radius: 16),
                SizedBox(width: 8),
                SkeletonBox(width: 84, height: 32, radius: 16),
                SizedBox(width: 12),
                SkeletonBox(width: 96, height: 32, radius: 16),
              ],
            ),
          ),
        ),
        Expanded(
          child: _GridSkeleton(
            columns: columns,
            aspectRatio: aspectRatio,
            padding: EdgeInsets.all(padding),
            spacing: 12,
            cardBuilder: (_) => const _AttendanceCardSkeleton(),
          ),
        ),
      ],
    );
  }
}

class _AttendanceCardSkeleton extends StatelessWidget {
  const _AttendanceCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SkeletonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 氏名 + ステータスバッジ
          Row(
            children: [
              Expanded(child: SkeletonBox.line(height: 15, width: 100)),
              SizedBox(width: 8),
              SkeletonBox(width: 48, height: 18, radius: 4),
            ],
          ),
          SizedBox(height: 8),
          // 入室 / 退室チップ
          Row(
            children: [
              Expanded(child: SkeletonBox(height: 36, radius: 8)),
              SizedBox(width: 8),
              Expanded(child: SkeletonBox(height: 36, radius: 8)),
            ],
          ),
          Spacer(),
          // ボタン群
          SkeletonBox(height: 36, radius: 8),
        ],
      ),
    );
  }
}

// ── 顧客管理 ──────────────────────────────────────────────────

/// 顧客一覧: カードグリッド（氏名・ふりがな・曜日チップ・バッジ）
class CustomerListSkeleton extends StatelessWidget {
  final int columns;
  final double aspectRatio;

  const CustomerListSkeleton({
    super.key,
    required this.columns,
    required this.aspectRatio,
  });

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('customerListSkeleton'),
      child: _GridSkeleton(
        columns: columns,
        aspectRatio: aspectRatio,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        spacing: 12,
        cardBuilder: (_) => columns == 1
            ? const _CustomerRowSkeleton()
            : const _CustomerCardSkeleton(),
      ),
    );
  }
}

class _CustomerCardSkeleton extends StatelessWidget {
  const _CustomerCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SkeletonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox.line(height: 16, width: 110),
          SizedBox(height: 4),
          SkeletonBox.line(height: 11, width: 70),
          SizedBox(height: 8),
          Row(
            children: [
              SkeletonBox(width: 22, height: 22, radius: 11),
              SizedBox(width: 4),
              SkeletonBox(width: 22, height: 22, radius: 11),
              SizedBox(width: 4),
              SkeletonBox(width: 22, height: 22, radius: 11),
            ],
          ),
          Spacer(),
          Row(
            children: [
              SkeletonBox(width: 76, height: 22, radius: 11),
              Spacer(),
              SkeletonBox(width: 56, height: 18, radius: 9),
            ],
          ),
        ],
      ),
    );
  }
}

class _CustomerRowSkeleton extends StatelessWidget {
  const _CustomerRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SkeletonCard(
      child: Row(
        children: [
          SkeletonBox.circle(size: 48),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox.line(height: 16, width: 120),
                SizedBox(height: 6),
                SkeletonBox.line(height: 11, width: 80),
                SizedBox(height: 6),
                SkeletonBox.line(height: 12, width: 100),
              ],
            ),
          ),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SkeletonBox(width: 76, height: 22, radius: 11),
              SizedBox(height: 4),
              SkeletonBox(width: 56, height: 18, radius: 9),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 送迎計画 ──────────────────────────────────────────────────

/// 送迎計画: アクションバー＋ルートカード（車両ヘッダー＋停留所行）
class TransportSkeleton extends StatelessWidget {
  const TransportSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: SingleChildScrollView(
        key: const Key('transportSkeleton'),
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          children: [
            // アクションバー
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: const Row(
                children: [
                  SkeletonBox(width: 120, height: 32, radius: 16),
                  Spacer(),
                  SkeletonBox(width: 110, height: 36, radius: 8),
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < 2; i++)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SkeletonCard(
                  padding: EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SkeletonBox.circle(size: 36),
                          SizedBox(width: 12),
                          Expanded(child: SkeletonBox.line(height: 16)),
                          SizedBox(width: 12),
                          SkeletonBox(width: 64, height: 24, radius: 12),
                        ],
                      ),
                      SizedBox(height: 12),
                      _StopRowSkeleton(),
                      _StopRowSkeleton(),
                      _StopRowSkeleton(),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StopRowSkeleton extends StatelessWidget {
  const _StopRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SkeletonBox.circle(size: 24),
          SizedBox(width: 12),
          Expanded(child: SkeletonBox.line(height: 13)),
          SizedBox(width: 24),
          SkeletonBox.line(width: 44, height: 12),
        ],
      ),
    );
  }
}

// ── 週間利用計画 ──────────────────────────────────────────────

/// 週間計画: 週ヘッダー＋（広幅: 表 / 狭幅: タブ＋日別カード）
class WeeklyScheduleSkeleton extends StatelessWidget {
  final bool wide;
  const WeeklyScheduleSkeleton({super.key, required this.wide});

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('weeklySkeleton'),
      children: [
        // 週情報ヘッダー（実物: 白・縦 10）
        SkeletonPulse(
          child: Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: const Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox.line(width: 160, height: 14),
                      SizedBox(height: 4),
                      SkeletonBox.line(width: 90, height: 11),
                    ],
                  ),
                ),
                SkeletonBox(width: 40, height: 20, radius: 10),
                SizedBox(width: 8),
                SkeletonBox.line(width: 56, height: 12),
              ],
            ),
          ),
        ),
        Expanded(
          child: SkeletonPulse(
            child: wide
                ? const _WeeklyTableSkeleton()
                : const _WeeklyTabSkeleton(),
          ),
        ),
      ],
    );
  }
}

class _WeeklyTableSkeleton extends StatelessWidget {
  const _WeeklyTableSkeleton();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // ヘッダー行
          Container(
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          for (var r = 0; r < 8; r++)
            Container(
              height: 44,
              decoration: const BoxDecoration(
                border: Border(
                    bottom: BorderSide(color: AppColors.divider, width: 0.5)),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  const SkeletonBox.line(width: 90, height: 13),
                  const Spacer(),
                  for (var d = 0; d < 7; d++) ...[
                    const SkeletonBox(width: 28, height: 20, radius: 10),
                    const SizedBox(width: 24),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _WeeklyTabSkeleton extends StatelessWidget {
  const _WeeklyTabSkeleton();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        children: [
          // タブバー（7 日）
          Container(
            color: Colors.white,
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                for (var i = 0; i < 7; i++)
                  const Expanded(
                    child: Center(
                        child: SkeletonBox(width: 28, height: 28, radius: 6)),
                  ),
              ],
            ),
          ),
          for (var i = 0; i < 5; i++)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SkeletonCard(
                child: Row(
                  children: [
                    SkeletonBox.circle(size: 36),
                    SizedBox(width: 12),
                    Expanded(child: SkeletonBox.line(height: 14)),
                    SizedBox(width: 12),
                    SkeletonBox(width: 72, height: 28, radius: 14),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── 月間支給量（顧客編集画面内のセクション） ────────────────────

/// 月間支給量セクション:
/// 月ラベル行 / 6 つの数値 / カレンダー（曜日見出し + 5〜6 週）
/// 実物（[MonthlyUsageStats] + [MonthlyUsageCalendar]）の行数・グリッドと一致させる。
class MonthlyUsageSkeleton extends StatelessWidget {
  const MonthlyUsageSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Column(
        key: const Key('monthlyUsageSkeleton'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SkeletonBox.line(width: 80, height: 13),
              Spacer(),
              SkeletonBox(width: 120, height: 24, radius: 12),
            ],
          ),
          const SizedBox(height: 12),
          for (var row = 0; row < 2; row++) ...[
            if (row > 0) const SizedBox(height: 10),
            Row(
              children: [
                for (var i = 0; i < 3; i++)
                  const Expanded(
                    child: Column(
                      children: [
                        SkeletonBox.line(width: 36, height: 20),
                        SizedBox(height: 4),
                        SkeletonBox.line(width: 44, height: 10),
                      ],
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          // カレンダー: 曜日見出し + 7 列グリッド（6 週ぶん）
          LayoutBuilder(
            builder: (context, c) {
              const gap = 3.0;
              final cell = (c.maxWidth - gap * 6) / 7;
              return Column(
                children: [
                  const SkeletonBox.line(height: 10),
                  const SizedBox(height: 4),
                  for (var w = 0; w < 5; w++) ...[
                    if (w > 0) const SizedBox(height: gap),
                    Row(
                      children: [
                        for (var d = 0; d < 7; d++) ...[
                          if (d > 0) const SizedBox(width: gap),
                          SkeletonBox(width: cell, height: cell, radius: 5),
                        ],
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// ── 設定 ──────────────────────────────────────────────────────

/// 設定画面: セクションカード（見出し + 入力欄）の縦並び
class SettingsSkeleton extends StatelessWidget {
  const SettingsSkeleton({super.key});

  /// 設定画面で実際に非同期待ちがあるのは API キー欄だけ
  /// （他の項目は Hive から同期で取得済み）。その入力欄と同寸の骨格。
  @override
  Widget build(BuildContext context) {
    return const SkeletonPulse(
      child: Column(
        key: Key('settingsSkeleton'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 入力欄（TextFormField 相当の高さ 56）
          SkeletonBox(height: 56, radius: AppTheme.controlBorderRadius),
          SizedBox(height: 4),
          // 注記 3 行（11pt × 1.5 行間）
          SkeletonBox.line(height: 11),
          SizedBox(height: 6),
          SkeletonBox.line(height: 11),
          SizedBox(height: 6),
          SkeletonBox.line(width: 160, height: 11),
        ],
      ),
    );
  }
}

// ── 地図画面（停留所パネル） ────────────────────────────────────

/// 地図画面: 左の停留所パネルの骨格（地図本体には重ねない）
class MapStopPanelSkeleton extends StatelessWidget {
  const MapStopPanelSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          key: const Key('mapPanelSkeleton'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 5; i++) ...[
              const Row(
                children: [
                  SkeletonBox.circle(size: 24),
                  SizedBox(width: 8),
                  Expanded(child: SkeletonBox.line(height: 12)),
                ],
              ),
              const SizedBox(height: 14),
            ],
          ],
        ),
      ),
    );
  }
}
