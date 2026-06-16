import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../screens/home_screen.dart';
import '../screens/login_screen.dart';
import '../services/auth_service.dart';
import 'auth_loading_screen.dart';

/// Firebase 認証状態に応じて表示する画面を切り替えるゲートウィジェット
///
/// ┌─ ConnectionState.waiting ─────────────────────→ AuthLoadingScreen
/// ├─ snapshot.hasData (User != null) ──────────────→ HomeScreen
/// └─ snapshot.hasData == false (User == null) ─────→ LoginScreen
///
/// routesベースの画面遷移ではなく、
/// StreamBuilder による宣言的な状態管理を行う。
/// ログイン・ログアウト時は Navigator なしで自動切り替えされる。
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.instance.authStateChanges,
      builder: (context, snapshot) {
        // ── 1. Firebase SDK が認証状態を確認中（起動直後のみ）
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const AuthLoadingScreen();
        }

        // ── 2. エラー発生時（通常は起きないが念のため）
        if (snapshot.hasError) {
          return _ErrorScreen(error: snapshot.error.toString());
        }

        // ── 3. ログイン済み → ホーム画面
        if (snapshot.hasData && snapshot.data != null) {
          return const HomeScreen();
        }

        // ── 4. 未ログイン → ログイン画面
        return const LoginScreen();
      },
    );
  }
}

/// 予期しないエラーが発生した場合の最終フォールバック画面
class _ErrorScreen extends StatelessWidget {
  final String error;

  const _ErrorScreen({required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 56,
                  color: Color(0xFFE53935),
                ),
                const SizedBox(height: 16),
                const Text(
                  'アプリの起動に失敗しました',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF757575),
                  ),
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: () {
                    // ページリロードで再試行
                    // ignore: deprecated_member_use
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (_) => const AuthGate(),
                      ),
                      (_) => false,
                    );
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
