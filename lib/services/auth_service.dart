import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Firebase Authentication の操作をラップするサービスクラス
///
/// - サインイン / サインアウト / パスワードリセット / ユーザー作成
/// - FirebaseAuthException を日本語メッセージに変換
/// - authStateChanges ストリームを公開（AuthGate で利用）
class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ─────────────────────────────────────────────
  // Public getters
  // ─────────────────────────────────────────────

  /// 認証状態の変化を通知するストリーム
  /// AuthGate の StreamBuilder に渡す
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// 現在ログイン中のユーザー（未ログインなら null）
  User? get currentUser => _auth.currentUser;

  /// ログイン中かどうか
  bool get isSignedIn => _auth.currentUser != null;

  // ─────────────────────────────────────────────
  // Auth operations
  // ─────────────────────────────────────────────

  /// メール＋パスワードでサインイン
  ///
  /// 成功時: [UserCredential] を返す
  /// 失敗時: [AuthException] を throw（日本語メッセージ付き）
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      debugPrint('[AuthService] サインイン成功: ${credential.user?.email}');
      return credential;
    } on FirebaseAuthException catch (e) {
      debugPrint('[AuthService] サインイン失敗: ${e.code} / ${e.message}');
      throw AuthException(_localizeAuthError(e.code), code: e.code);
    } catch (e) {
      debugPrint('[AuthService] 予期しないエラー: $e');
      throw const AuthException('予期しないエラーが発生しました。再度お試しください。');
    }
  }

  /// サインアウト
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      debugPrint('[AuthService] サインアウト完了');
    } on FirebaseAuthException catch (e) {
      debugPrint('[AuthService] サインアウト失敗: ${e.code}');
      throw AuthException(_localizeAuthError(e.code), code: e.code);
    }
  }

  /// パスワードリセットメールを送信
  ///
  /// 成功時: 正常終了
  /// 失敗時: [AuthException] を throw
  Future<void> sendPasswordResetEmail({required String email}) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      debugPrint('[AuthService] パスワードリセットメール送信: $email');
    } on FirebaseAuthException catch (e) {
      debugPrint('[AuthService] パスワードリセット失敗: ${e.code}');
      throw AuthException(_localizeAuthError(e.code), code: e.code);
    } catch (e) {
      debugPrint('[AuthService] 予期しないエラー: $e');
      throw const AuthException('予期しないエラーが発生しました。再度お試しください。');
    }
  }

  /// 新規ユーザーをメール＋パスワードで作成（管理者が職員を追加する用途）
  ///
  /// 成功時: [UserCredential] を返す
  /// 失敗時: [AuthException] を throw
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      debugPrint('[AuthService] ユーザー作成成功: ${credential.user?.email}');
      return credential;
    } on FirebaseAuthException catch (e) {
      debugPrint('[AuthService] ユーザー作成失敗: ${e.code}');
      throw AuthException(_localizeAuthError(e.code), code: e.code);
    } catch (e) {
      debugPrint('[AuthService] 予期しないエラー: $e');
      throw const AuthException('予期しないエラーが発生しました。再度お試しください。');
    }
  }

  // ─────────────────────────────────────────────
  // Error localization
  // ─────────────────────────────────────────────

  /// FirebaseAuth エラーコードを日本語メッセージに変換する
  String _localizeAuthError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'このメールアドレスのユーザーは存在しません';
      case 'wrong-password':
        return 'メールアドレスまたはパスワードが違います';
      case 'invalid-credential':
        return 'メールアドレスまたはパスワードが違います';
      case 'invalid-email':
        return 'メールアドレスの形式が正しくありません';
      case 'user-disabled':
        return 'このアカウントは無効化されています。管理者にお問い合わせください';
      case 'too-many-requests':
        return '試行回数が多すぎます。しばらく待ってから再試行してください';
      case 'network-request-failed':
        return 'ネットワークエラーが発生しました。接続を確認してください';
      case 'email-already-in-use':
        return 'このメールアドレスは既に登録されています';
      case 'weak-password':
        return 'パスワードが弱すぎます（8文字以上を推奨）';
      case 'requires-recent-login':
        return '再認証が必要です。一度ログアウトして再度ログインしてください';
      case 'operation-not-allowed':
        return 'この操作は現在許可されていません';
      case 'account-exists-with-different-credential':
        return '同じメールアドレスで別の方法で登録されています';
      default:
        return 'エラーが発生しました（コード: $code）。再度お試しください';
    }
  }
}

// ─────────────────────────────────────────────
// AuthException — 日本語メッセージ付きカスタム例外
// ─────────────────────────────────────────────

/// AuthService がスローするカスタム例外
class AuthException implements Exception {
  /// ユーザーに見せる日本語メッセージ
  final String message;

  /// Firebase Auth エラーコード（任意）
  final String? code;

  const AuthException(this.message, {this.code});

  @override
  String toString() => 'AuthException(code: $code, message: $message)';
}
