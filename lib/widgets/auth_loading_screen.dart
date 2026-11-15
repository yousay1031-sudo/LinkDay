import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'motion/app_spinner.dart';

/// Firebase 認証状態確認中に表示するローディング画面
///
/// アプリ起動直後、authStateChanges の最初のイベントが届くまでの間だけ表示される。
/// ユーザーが何も操作しなくても自動的に LoginScreen または HomeScreen に切り替わる。
///
/// - ロゴ・アプリ名は web/index.html の起動ローダーと同じ配置・色にしてあり、
///   HTML → Flutter の切替で位置が跳ねない
/// - 確認は通常一瞬で終わるため、インジケーターと「読み込み中」は
///   [AppMotion.skeletonShowDelay] 経過後にだけ出す（点滅防止）
/// - [slowThreshold] を過ぎても終わらない場合は「時間がかかっている」旨と
///   再読み込みの案内を出す（ローダーで状況を隠し続けない）
class AuthLoadingScreen extends StatefulWidget {
  const AuthLoadingScreen({super.key});

  static const Duration slowThreshold = Duration(seconds: 10);

  @override
  State<AuthLoadingScreen> createState() => _AuthLoadingScreenState();
}

class _AuthLoadingScreenState extends State<AuthLoadingScreen> {
  bool _showIndicator = false;
  bool _slow = false;
  Timer? _indicatorTimer;
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    _indicatorTimer = Timer(AppMotion.skeletonShowDelay, () {
      if (mounted) setState(() => _showIndicator = true);
    });
    _slowTimer = Timer(AuthLoadingScreen.slowThreshold, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _indicatorTimer?.cancel();
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // アプリアイコン
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.child_care,
                  size: 52,
                  color: Colors.white,
                ),
              ),

              const SizedBox(height: 28),

              // アプリ名
              const Text(
                'LinkDay',
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                  letterSpacing: 1.5,
                ),
              ),

              const SizedBox(height: 8),

              // サブタイトル
              const Text(
                '放課後等デイサービス管理システム',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.onSurfaceVariant,
                  letterSpacing: 0.3,
                ),
              ),

              const SizedBox(height: 56),

              // ローディングインジケーター（遅れて表示・領域は常に確保）
              AnimatedOpacity(
                opacity: _showIndicator ? 1 : 0,
                duration: AppMotion.scaled(context, AppMotion.fast),
                child: Semantics(
                  label: _showIndicator ? 'ログイン状態を確認中' : null,
                  liveRegion: _showIndicator,
                  child: const ExcludeSemantics(
                    child: Column(
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: AppSpinner(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.primary,
                            ),
                          ),
                        ),
                        SizedBox(height: 20),
                        Text(
                          'ログイン状態を確認中…',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              if (_slow) ...[
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    '確認に時間がかかっています。\n'
                    '通信状態を確認し、改善しない場合はページを再読み込みしてください。',
                    key: Key('authLoadingSlow'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: AppColors.warning,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
