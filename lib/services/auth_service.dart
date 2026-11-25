import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../verify/verify_config.dart';

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

  /// Google でログイン（職員の個人アカウント）。
  ///
  /// ポップアップで Google のアカウントを選ぶ（リダイレクト方式は、Hosting と認証の
  /// ドメインが違うとブラウザの保存領域の分離で失敗することがあるため使わない）。
  /// 事業所に入れるかどうかは、ログイン後に所属を確かめて決める（DataSession）。
  Future<UserCredential> signInWithGoogle() async {
    try {
      final provider = GoogleAuthProvider()
        ..setCustomParameters({'prompt': 'select_account'});
      final credential = await _auth.signInWithPopup(provider);
      debugPrint('[AuthService] Google でサインイン成功');
      return credential;
    } on FirebaseAuthException catch (e) {
      debugPrint('[AuthService] Google サインイン失敗: ${e.code}');
      throw AuthException(_localizeAuthError(e.code), code: e.code);
    } catch (e) {
      debugPrint('[AuthService] 予期しないエラー: $e');
      throw const AuthException('予期しないエラーが発生しました。再度お試しください。');
    }
  }

  /// 【検証構成のみ】Auth エミュレータへ、Google ログインの模擬を行う。
  ///
  /// エミュレータは署名のない JSON を Google の ID トークンとして受け付ける
  /// （本物の Google には接続しない）。通常ビルドでは使えない。
  Future<UserCredential> signInWithEmulatorGoogle(String email) async {
    if (!VerifyConfig.enabled) {
      throw StateError('検証構成でのみ使えます');
    }
    final e = email.trim().toLowerCase();
    final claims = jsonEncode({
      'sub': 'verify-google-${e.replaceAll(RegExp(r'[^a-z0-9]'), '-')}',
      'email': e,
      'email_verified': true,
    });
    try {
      return await _auth
          .signInWithCredential(GoogleAuthProvider.credential(idToken: claims));
    } on FirebaseAuthException catch (err) {
      throw AuthException(_localizeAuthError(err.code), code: err.code);
    }
  }

  /// いまのアカウントが Google でログインしたものか
  bool get isGoogleUser =>
      _auth.currentUser?.providerData
          .any((p) => p.providerId == 'google.com') ??
      false;

  /// Google でログインした直後に、所属を作ってもらう（Cloud Functions）。
  ///
  /// サーバーは認証トークンの確認済みメールアドレスだけを使う（ここからは何も送らない）。
  /// 作れたら true。登録が無い・許可が無いときは false（理由は返らない）。
  Future<bool> claimMembership() async {
    final res = await FirebaseFunctions.instanceFor(region: 'asia-northeast1')
        .httpsCallable('claimStaffMembership')
        .call<Map<String, dynamic>>();
    return res.data['ok'] == true;
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
      case 'popup-blocked':
        return 'ログインの画面（ポップアップ）がブラウザに止められました。'
            'ポップアップを許可してから、もう一度押してください';
      case 'popup-closed-by-user':
      case 'cancelled-popup-request':
        return 'Google のログインが途中で閉じられました。もう一度押してください';
      case 'unauthorized-domain':
        return 'このアドレスからは Google でログインできません。管理者にお問い合わせください';
      case 'admin-restricted-operation':
        return '新しいアカウントの作成が止められています。管理者にお問い合わせください';
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
