# LinkDay — 開発者向け運用ガイド

## 目次

1. [プロジェクト概要](#プロジェクト概要)
2. [ビルドコマンド](#ビルドコマンド)
3. [Service Worker キャッシュ問題と対策](#service-worker-キャッシュ問題と対策)
4. [キャッシュクリア手順](#キャッシュクリア手順)
5. [開発者向けデバッグ機能](#開発者向けデバッグ機能)
6. [Firebase Authentication 注意事項](#firebase-authentication-注意事項)
7. [フォルダ構成](#フォルダ構成)

---

## プロジェクト概要

**LinkDay** は放課後等デイサービス向けの運営支援 Web アプリです。
Firebase Authentication による認証を実装しており、登録済みユーザーのみがログインできます。

- **Firebase プロジェクト**: `linkday-proud`
- **Flutter バージョン**: 3.35.4（固定）
- **Dart バージョン**: 3.9.2（固定）

---

## ビルドコマンド

### 開発・本番共通: 必ずこのコマンドを使うこと

```bash
flutter build web --release --pwa-strategy=none
```

> **`--pwa-strategy=none` は必須です。**
> 省略すると `flutter_service_worker.js` が生成され、
> ブラウザが古いビルドをキャッシュし続けるバグが再発します。

### ローカルプレビュー起動（ポート 5060）

```bash
cd build/web && python3 -c "
import http.server, socketserver
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('X-Frame-Options', 'ALLOWALL')
        self.send_header('Content-Security-Policy', 'frame-ancestors *')
        super().end_headers()
with socketserver.TCPServer(('0.0.0.0', 5060), H) as s:
    s.serve_forever()
"
```

### まとめて実行（ビルド + サーバー起動）

```bash
flutter build web --release --pwa-strategy=none && \
cd build/web && python3 -m http.server 5060 --bind 0.0.0.0
```

---

## Service Worker キャッシュ問題と対策

### 問題の背景

Flutter Web はデフォルトで `flutter_service_worker.js` を生成します。
この Service Worker はすべての JS・アセットをアグレッシブにキャッシュするため、
再ビルド後も**ブラウザが古いバージョンを使い続ける**ことがあります。

### 発生した具体的なバグ（Turn 4 で調査）

- Firebase Authentication を実装したが、ブラウザが旧ビルド（仮ログイン版）を
  Service Worker キャッシュから配信し続けた
- **シークレットウィンドウ**（キャッシュなし）では正常動作
- 通常ウィンドウでは未登録ユーザーでもログイン成功してしまう症状

### 恒久対策（3 層構造）

#### 対策 1: `--pwa-strategy=none` でビルド

Service Worker 自体を生成しないため、根本的にキャッシュ問題が発生しません。

#### 対策 2: `web/index.html` に SW 自動更新ロジック（既実装）

```
controllerchange → sessionStorage フラグ付き自動リロード
ready.then → waiting 状態 SW に SKIP_WAITING を送信
updatefound → installing SW が installed になったら SKIP_WAITING
```

仮に Service Worker が残っていても、新 SW を即時 activate させます。

#### 対策 3: `flutter_bootstrap.js` のキャッシュバスティング（既実装）

```html
<script>
  var script = document.createElement('script');
  script.src = 'flutter_bootstrap.js?v=' + new Date().getTime();
  script.async = true;
  document.body.appendChild(script);
</script>
```

ページを開くたびに新鮮なタイムスタンプで `flutter_bootstrap.js` を取得します。

---

## キャッシュクリア手順

### 方法 A: URL に `?nocache=1` を追加（最も確実）

1. ブラウザのアドレスバーに移動
2. URL の末尾に `?nocache=1` を追加して Enter
   ```
   https://example.com/?nocache=1
   ```
3. ページが自動でリロードされ、すべての Service Worker が unregister されます

> `index.html` のスクリプトが `?nocache=1` を検出して
> 自動的に SW を全削除 → クリーン URL に戻します。

### 方法 B: シークレットウィンドウで開く

キャッシュが一切ない状態で動作確認できます。
ユーザーへの一時的な案内として有効です。

### 方法 C: Chrome DevTools でクリア

1. `F12` → **Application** タブを開く
2. 左メニュー **Storage** → **Clear site data** をクリック
3. ページをリロード

または:

1. `F12` → **Application** タブ
2. 左メニュー **Service Workers** → **Unregister** をクリック
3. ページをリロード

### 方法 D: 開発者向けキャッシュクリアボタン（DEBUG ビルドのみ）

DEBUG ビルド時のみ AppBar 右上に `🧹` アイコンが表示されます。
タップすると確認ダイアログが出て、`?nocache=1` 遷移が実行されます。
**リリースビルドでは tree-shaking により完全除去されます。**

---

## 開発者向けデバッグ機能

### キャッシュクリアボタン

- **表示条件**: `kDebugMode == true`（`flutter run` または `flutter build --debug`）
- **場所**: AppBar 右上（ログアウトボタンの左隣）
- **アイコン**: `Icons.cleaning_services_outlined`
- **動作**: 確認ダイアログ → `?nocache=1` 付き URL に遷移
- **本番 release ビルド**: `kDebugMode == false` → ボタン非表示（tree-shaking で除去）

```dart
// home_screen.dart の AppBar actions
if (kDebugMode)
  IconButton(
    icon: const Icon(Icons.cleaning_services_outlined),
    tooltip: '[DEV] キャッシュクリア',
    onPressed: () => _onClearCache(context),
  ),
```

---

## Firebase Authentication 注意事項

### AuthGate パターン

```dart
// widgets/auth_gate.dart
StreamBuilder<User?>(
  stream: AuthService.instance.authStateChanges,
  builder: (context, snapshot) {
    if (snapshot.connectionState == ConnectionState.waiting)
      return const AuthLoadingScreen();
    if (snapshot.hasData && snapshot.data != null)
      return const HomeScreen();
    return const LoginScreen();
  },
)
```

- `Navigator.pushReplacementNamed` は**使わない**
- Firebase の `authStateChanges` Stream が画面を自動切り替えする

### エラーメッセージ

`services/auth_service.dart` の `_localizeAuthError` で
Firebase エラーコードを日本語に変換しています:

| Firebase エラーコード | 表示メッセージ |
|---|---|
| `user-not-found` | メールアドレスが登録されていません |
| `wrong-password` | パスワードが正しくありません |
| `invalid-credential` | メールアドレスまたはパスワードが正しくありません |
| `too-many-requests` | ログイン試行回数が多すぎます... |
| `network-request-failed` | ネットワークエラーが発生しました... |

### 本番運用時の注意

- デモアカウント・ゲストモードは実装しないこと
- メール＋パスワード認証のみ使用
- Firebase Console で「Email/Password」プロバイダが有効化されていること

---

## フォルダ構成

```
lib/
├── README.md                 ← このファイル
├── main.dart                 ← エントリポイント（Firebase 初期化 + AuthGate）
├── firebase_options.dart     ← Web 用 FirebaseOptions 定数
├── screens/
│   ├── login_screen.dart     ← ログイン画面（Firebase Auth 接続済み）
│   └── home_screen.dart      ← ホーム画面（8メニューグリッド）
├── services/
│   └── auth_service.dart     ← AuthService シングルトン + AuthException
├── theme/
│   └── app_theme.dart        ← AppColors + AppTheme.lightTheme（Material 3）
└── widgets/
    ├── auth_gate.dart        ← StreamBuilder 認証ゲート
    └── auth_loading_screen.dart ← Firebase 初期化待機画面
```

---

*最終更新: Turn 5（Service Worker キャッシュ恒久対策）*
