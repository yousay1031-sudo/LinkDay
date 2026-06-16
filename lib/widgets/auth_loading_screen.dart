import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Firebase 認証状態確認中に表示するローディング画面
///
/// アプリ起動直後、authStateChanges の最初のイベントが届くまでの間だけ表示される。
/// ユーザーが何も操作しなくても自動的に LoginScreen または HomeScreen に切り替わる。
class AuthLoadingScreen extends StatelessWidget {
  const AuthLoadingScreen({super.key});

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
                      blurRadius: 24,
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

              // ローディングインジケーター
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.primary,
                  ),
                ),
              ),

              const SizedBox(height: 20),

              const Text(
                '読み込み中...',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
