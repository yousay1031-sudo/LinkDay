import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_theme.dart';

/// 読込中はスケルトン、完了で実体へ切り替えるゲート。
///
/// ## タイミング仕様（AppMotion で一元管理）
/// - 生成時に `loading == false` → 骨格を一切出さず即実体
/// - 読込開始から [showDelay]（既定 120ms）以内に完了 → 骨格を出さず実体を
///   そのまま表示（フェードもしない）。待機中は空白で、追加待ちはゼロ
/// - [showDelay] を超えたら骨格を出す（150ms でフェードイン）。一度出した骨格は
///   [minDisplay]（既定 250ms）経つまで残す（出てすぐ消える点滅を防ぐ）。
///   追加待機が起きるのは「120〜370ms で完了した」場合のみ、最大 250ms
/// - エラーは最低表示時間を待たずに即表示（失敗を隠さない）
///
/// ## 再取得と対象変更
/// - 同じ [contentKey] のまま `loading` が再び true になった（＝再取得）場合、
///   既存の実体を残し、上端に細い「更新中」表示だけを出す（全面骨格に戻さない）
/// - [contentKey] が変わった（＝日付や週など対象が変わった）場合は、旧対象の
///   内容を新対象として見せないよう、初回と同じ手順（猶予→骨格）をやり直す
/// - 古い非同期結果の破棄は呼び出し側の責務（LoadSequencer を使う）
///
/// ## その他
/// - [fillParent] = true（既定）: Stack(fit: expand) で骨格と実体を重ねるため
///   切替でレイアウトシフトが起きない（bounded な領域に置くこと）。
///   false: スクロール内など高さが未確定の場所用
/// - 骨格レイヤーは IgnorePointer・ExcludeSemantics（読み上げは「読み込み中」1 つ）
/// - 切替中の旧表示は操作・読み上げの対象から外す
/// - タイマーは dispose で必ず止める（dispose 後に setState しない）
/// - reduce-motion ではフェードなしで即時切替（タイミング規則は同じ）
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

  /// 表示対象の識別子（日付・週など）。変わると「新しい対象の初回読込」扱い
  final Object? contentKey;

  final Duration showDelay;
  final Duration minDisplay;
  final bool fillParent;

  /// 再取得中に上端の「更新中」表示を出すか
  final bool showRefreshIndicator;

  const SkeletonGate({
    super.key,
    required this.loading,
    required this.skeleton,
    required this.builder,
    this.errorMessage,
    this.onRetry,
    this.contentKey,
    this.showDelay = AppMotion.skeletonShowDelay,
    this.minDisplay = AppMotion.skeletonMinDisplay,
    this.fillParent = true,
    this.showRefreshIndicator = true,
  });

  @override
  State<SkeletonGate> createState() => _SkeletonGateState();
}

enum _Phase {
  /// 読込中だが骨格はまだ出していない（showDelay 待ち）
  pending,

  /// 骨格を表示中
  skeleton,

  /// 実体 or エラーを表示中（再取得中もここ）
  settled,
}

class _SkeletonGateState extends State<SkeletonGate> {
  late _Phase _phase;
  Timer? _showTimer;
  Timer? _minTimer;
  bool _minElapsed = true;

  /// 再取得中で、更新中表示を出す段階か（showDelay 経過後）
  bool _refreshVisible = false;

  _Phase? _lastBuiltPhase;
  String? _lastShownKey;
  bool _keepOutgoing = false;

  @override
  void initState() {
    super.initState();
    if (widget.loading) {
      _phase = _Phase.pending;
      _scheduleSkeleton();
    } else {
      _phase = _Phase.settled;
    }
  }

  void _scheduleSkeleton() {
    _showTimer?.cancel();
    _minTimer?.cancel();
    _minElapsed = false;
    if (widget.showDelay <= Duration.zero) {
      _enterSkeleton();
      return;
    }
    _showTimer = Timer(widget.showDelay, () {
      if (!mounted) return;
      setState(_enterSkeleton);
    });
  }

  void _enterSkeleton() {
    _phase = _Phase.skeleton;
    _minTimer?.cancel();
    _minTimer = Timer(widget.minDisplay, () {
      if (!mounted) return;
      setState(() {
        _minElapsed = true;
        if (!widget.loading) _phase = _Phase.settled;
      });
    });
  }

  void _startRefresh() {
    _showTimer?.cancel();
    _refreshVisible = false;
    if (!widget.showRefreshIndicator) return;
    _showTimer = Timer(widget.showDelay, () {
      if (!mounted || !widget.loading) return;
      setState(() => _refreshVisible = true);
    });
  }

  void _onLoadEnd() {
    _showTimer?.cancel();
    _refreshVisible = false;
    switch (_phase) {
      case _Phase.pending:
        _phase = _Phase.settled;
      case _Phase.skeleton:
        if (widget.errorMessage != null || _minElapsed) {
          _minTimer?.cancel();
          _phase = _Phase.settled;
        }
      // それ以外は _minTimer の満了で settled へ
      case _Phase.settled:
        break;
    }
  }

  @override
  void didUpdateWidget(SkeletonGate old) {
    super.didUpdateWidget(old);
    final keyChanged = old.contentKey != widget.contentKey;
    if (widget.loading) {
      if (keyChanged) {
        // 対象が変わった: 旧対象の内容は見せない
        _refreshVisible = false;
        _phase = _Phase.pending;
        _scheduleSkeleton();
      } else if (!old.loading) {
        if (_phase == _Phase.settled && old.errorMessage == null) {
          _startRefresh(); // 再取得: 既存の内容を残す
        } else {
          _phase = _Phase.pending; // エラー後の再試行など
          _scheduleSkeleton();
        }
      }
    } else if (old.loading) {
      _onLoadEnd();
    } else if (_phase == _Phase.skeleton && widget.errorMessage != null) {
      _onLoadEnd();
    }
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _minTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget child;
    switch (_phase) {
      case _Phase.pending:
        // 猶予中は骨格を「見えない状態」で置き、領域の高さだけ確保する
        // （fillParent=false でも骨格が出た瞬間にレイアウトが跳ねない）。
        // TickerMode でパルスも止める（見えないアニメを回さない）
        child = KeyedSubtree(
          key: const ValueKey('pending'),
          child: TickerMode(
            enabled: false,
            child: IgnorePointer(
              child: Opacity(opacity: 0, child: widget.skeleton),
            ),
          ),
        );
      case _Phase.skeleton:
        child = KeyedSubtree(
          key: const ValueKey('skeleton'),
          child: IgnorePointer(child: widget.skeleton),
        );
      case _Phase.settled:
        if (widget.errorMessage != null && !widget.loading) {
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
    }

    final reduced = AppMotion.reduced(context);
    // 猶予内に完了した（骨格を一度も出していない）切替はフェードせず即表示
    final instant =
        _lastBuiltPhase == _Phase.pending && _phase == _Phase.settled;
    final shownKey = (child.key as ValueKey<String>).value;
    if (shownKey != _lastShownKey) {
      // 表示が切り替わった瞬間: 旧表示が骨格だったときだけフェードアウトを見せる
      _keepOutgoing = _lastShownKey == 'skeleton';
      _lastShownKey = shownKey;
    }
    _lastBuiltPhase = _phase;
    final duration = (reduced || instant)
        ? Duration.zero
        : (_phase == _Phase.skeleton ? AppMotion.fast : AppMotion.normal);
    final switcher = AnimatedSwitcher(
      duration: duration,
      reverseDuration: duration,
      switchInCurve: AppMotion.standard,
      switchOutCurve: AppMotion.standard,
      layoutBuilder: (current, previous) => Stack(
        fit: widget.fillParent ? StackFit.expand : StackFit.loose,
        alignment: Alignment.topCenter,
        children: [
          // 退場フェードを見せるのは「骨格 → 内容/エラー」のときだけ。
          // 見えない猶予レイヤーや、対象変更・再試行で外れた旧内容/旧エラーは
          // 即座に取り除く（旧日付のデータを新日付として一瞬でも見せない）。
          // 退場中の骨格も操作・読み上げの対象にしない
          // （AnimatedSwitcher は子を独自キーで包むため、切替時に記録した
          //   _keepOutgoing で判定する）
          if (_keepOutgoing)
            for (final p in previous)
              IgnorePointer(child: ExcludeSemantics(child: p)),
          if (current != null) current,
        ],
      ),
      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
      child: child,
    );

    if (!_refreshVisible || _phase != _Phase.settled) return switcher;
    return Stack(
      fit: widget.fillParent ? StackFit.expand : StackFit.loose,
      children: [
        switcher,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: RefreshingBar(reduced: reduced),
        ),
      ],
    );
  }
}

/// 再取得中を示す上端の細いバー（既存内容の上に重ねる）。
/// reduce-motion では動かない静的なバー。
class RefreshingBar extends StatelessWidget {
  final bool reduced;
  const RefreshingBar({super.key, required this.reduced});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('skeletonGateRefreshing'),
      label: '更新中',
      liveRegion: true,
      child: reduced
          ? Container(
              height: 3,
              color: AppColors.primary.withValues(alpha: 0.6),
            )
          : const LinearProgressIndicator(
              minHeight: 3,
              color: AppColors.primary,
              backgroundColor: Colors.transparent,
            ),
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
