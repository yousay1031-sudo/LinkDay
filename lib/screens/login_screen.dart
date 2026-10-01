import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // ログイン処理
  // ─────────────────────────────────────────────

  Future<void> _handleLogin() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isLoading = true);

    try {
      await AuthService.instance.signInWithEmailAndPassword(
        email: _emailController.text,
        password: _passwordController.text,
      );
      // 成功時: AuthGate の StreamBuilder が自動で HomeScreen に切り替えるため
      // Navigator による手動遷移は不要
    } on AuthException catch (e) {
      if (!mounted) return;
      _showErrorSnackBar(e.message);
    } catch (e) {
      if (!mounted) return;
      _showErrorSnackBar('予期しないエラーが発生しました。再度お試しください。');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─────────────────────────────────────────────
  // パスワードリセット
  // ─────────────────────────────────────────────

  void _handleForgotPassword() {
    final resetEmailController = TextEditingController(
      // ログインフォームに入力済みのメールを初期値にセット
      text: _emailController.text,
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _PasswordResetDialog(
        emailController: resetEmailController,
      ),
    ).then((_) {
      resetEmailController.dispose();
    });
  }

  // ─────────────────────────────────────────────
  // SnackBar ヘルパー
  // ─────────────────────────────────────────────

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 40),

                  // ロゴエリア（既存デザイン維持）
                  _buildLogoSection(),

                  const SizedBox(height: 48),

                  // ログインフォーム（既存デザイン維持）
                  _buildLoginForm(),

                  const SizedBox(height: 24),

                  // ログインボタン（既存デザイン維持）
                  _buildLoginButton(),

                  const SizedBox(height: 16),

                  // パスワード忘れリンク（既存デザイン維持）
                  _buildForgotPasswordLink(),

                  const SizedBox(height: 40),

                  // バージョン情報（既存デザイン維持）
                  _buildVersionInfo(),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // ウィジェット分割（既存デザイン100%維持）
  // ─────────────────────────────────────────────

  Widget _buildLogoSection() {
    return Column(
      children: [
        // ロゴアイコン
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(
            Icons.child_care,
            size: 48,
            color: Colors.white,
          ),
        ),

        const SizedBox(height: 20),

        // アプリ名
        const Text(
          'LinkDay',
          style: TextStyle(
            fontSize: 40,
            fontWeight: FontWeight.w800,
            color: AppColors.primary,
            letterSpacing: 1.5,
          ),
        ),

        const SizedBox(height: 8),

        // サブタイトル
        const Text(
          '放課後等デイサービス管理システム',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: AppColors.onSurfaceVariant,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildLoginForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // メールアドレス
          const Text(
            'メールアドレス',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enabled: !_isLoading,
            decoration: const InputDecoration(
              hintText: 'example@linkday.jp',
              prefixIcon: Icon(Icons.email_outlined),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'メールアドレスを入力してください';
              }
              if (!RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$').hasMatch(value)) {
                return '正しいメールアドレスを入力してください';
              }
              return null;
            },
          ),

          const SizedBox(height: 20),

          // パスワード
          const Text(
            'パスワード',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            enabled: !_isLoading,
            onFieldSubmitted: (_) => _handleLogin(),
            decoration: InputDecoration(
              hintText: '8文字以上のパスワード',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: _isLoading
                    ? null
                    : () {
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
              ),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'パスワードを入力してください';
              }
              if (value.length < 6) {
                return '6文字以上のパスワードを入力してください';
              }
              return null;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLoginButton() {
    return SizedBox(
      height: AppTheme.buttonHeight,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleLogin,
        child: _isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : const Text(
                'ログイン',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
      ),
    );
  }

  Widget _buildForgotPasswordLink() {
    return Center(
      child: TextButton(
        onPressed: _isLoading ? null : _handleForgotPassword,
        child: const Text(
          'パスワードを忘れた方はこちら',
          style: TextStyle(
            fontSize: 13,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }

  Widget _buildVersionInfo() {
    return const Center(
      child: Text(
        'Version 1.0.0',
        style: TextStyle(
          fontSize: 11,
          color: AppColors.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// パスワードリセットダイアログ（別ウィジェットに分離）
// ─────────────────────────────────────────────

class _PasswordResetDialog extends StatefulWidget {
  final TextEditingController emailController;

  const _PasswordResetDialog({required this.emailController});

  @override
  State<_PasswordResetDialog> createState() => _PasswordResetDialogState();
}

class _PasswordResetDialogState extends State<_PasswordResetDialog> {
  final _formKey = GlobalKey<FormState>();
  bool _isSending = false;

  Future<void> _sendResetEmail() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSending = true);

    try {
      await AuthService.instance.sendPasswordResetEmail(
        email: widget.emailController.text,
      );

      if (!mounted) return;
      Navigator.of(context).pop();

      // 親 Scaffold の SnackBar に表示するため、
      // ダイアログを閉じてから ScaffoldMessenger を使う
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'パスワード再設定メールを送信しました。\nメールをご確認ください。',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          duration: const Duration(seconds: 5),
        ),
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  e.message,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('予期しないエラーが発生しました。'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_reset, color: AppColors.primary),
          SizedBox(width: 8),
          Text(
            'パスワードのリセット',
            style: TextStyle(fontSize: 18),
          ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '登録済みのメールアドレスを入力してください。\nパスワード再設定用のリンクを送信します。',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: widget.emailController,
                keyboardType: TextInputType.emailAddress,
                enabled: !_isSending,
                decoration: const InputDecoration(
                  labelText: 'メールアドレス',
                  hintText: 'example@linkday.jp',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'メールアドレスを入力してください';
                  }
                  if (!RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$')
                      .hasMatch(value)) {
                    return '正しいメールアドレスを入力してください';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _isSending ? null : () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        ElevatedButton.icon(
          onPressed: _isSending ? null : _sendResetEmail,
          icon: _isSending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Icon(Icons.send, size: 18),
          label: Text(_isSending ? '送信中...' : '送信'),
        ),
      ],
    );
  }
}
