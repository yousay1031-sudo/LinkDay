import 'verify_auth_guard_stub.dart'
    if (dart.library.js_interop) 'verify_auth_guard_web.dart' as impl;

/// 【検証構成のみ】Auth を、通信を始める前にエミュレータへ向ける仕掛け。
///
/// 背景（2026-11-19 調査）: Web 版の firebase_auth は Firebase.initializeApp の中で
/// Auth を作り、保存済みのログイン状態を確かめる通信（accounts:lookup）を
/// その場で始める。アプリ側の useAuthEmulator はその後に呼ばれるため、
/// ログイン状態が保存されていると、最初の通信が本物の identitytoolkit.googleapis.com
/// へ出てしまい、さらにエミュレータ設定が黙って失敗する（以後のログインも本物宛て）。
///
/// 対策: Firebase.initializeApp の前に [install] を呼ぶ。Auth の JS モジュールが
/// 読み込まれた時点で initializeAuth を包み、Auth が作られた直後（通信が始まる前）に
/// connectAuthEmulator を呼ぶ。初期化後は [connected] で包みが働いたかを確かめ、
/// 働いていなければ起動を止める（本番へはフォールバックしない）。
///
/// 通常ビルドでは VerifyConfig.enabled が const false のため呼ばれない。
class VerifyAuthGuard {
  VerifyAuthGuard._();

  /// [origin] 例: http://127.0.0.1:9099（ループバックであることは VerifyConfig.validate 済み）
  ///
  /// 仕掛けられなければ false（呼び出し側は Firebase を初期化せずに止める）。
  static bool install(String origin) => impl.install(origin);

  /// initializeAuth の直後にエミュレータへ向けられたか。
  static bool get connected => impl.connected;
}
