# LinkDay

**放課後等デイサービス運営支援アプリ**

児童発達支援・放課後等デイサービスの日常業務（顧客管理・出席管理・書類出力）をデジタル化し、施設スタッフの業務効率を最大化するWebアプリケーションです。将来的にはSaaS展開を予定しています。

---

## 技術スタック

| 分類 | 技術 |
|---|---|
| フレームワーク | Flutter 3.35.4 / Dart 3.9.2 |
| UI | Material Design 3 (`useMaterial3: true`) |
| ローカル DB | Hive 2.2.3 + hive_flutter 1.1.0 (IndexedDB on Web) |
| 認証 | Firebase Authentication (email/password) |
| PDF 出力 | pdf 3.11.1 + printing 5.13.4 |
| Excel インポート | excel 2.1.0 + file_picker 8.1.4 |
| 状態管理 | Provider 6.1.5+1 |
| コード生成 | hive_generator 2.0.1 + build_runner 2.4.13 |
| ターゲット | Flutter Web (JS ビルド) / Android APK |

---

## 現在の実装状況

### ✅ Day 1 — 基盤構築
- Flutter プロジェクト初期化
- `AppTheme` (Material 3 テーマ / `#F57C00` ベースカラー)
- `AuthGate` (StreamBuilder<User?> 認証ゲート)
- `HomeScreen` (レスポンシブ 4/3/2/1 列グリッドメニュー)
- `LoginScreen` (email + password フォーム)

### ✅ Day 2 — Firebase 認証 + キャッシュ対策
- Firebase Authentication 統合
- `AuthService` シングルトン (日本語エラーメッセージ)
- Service Worker キャッシュ恒久対策:
  - `--pwa-strategy=none` ビルド (SW 空ファイル化)
  - `web/index.html` 3 層防御 (controllerchange + skipWaiting + `?nocache=1`)
  - `flutter_bootstrap.js?v=<timestamp>` キャッシュバスティング

### ✅ Day 3 — 顧客管理 + Excel 一括インポート
- `Customer` モデル (Hive typeId=0 / 19 フィールド / UUID 自動生成)
- `CustomerService` (CRUD / 検索 / 月次リセット)
- `CustomerManagementScreen` (レスポンシブグリッド / 検索バー / 期限アラートカード)
- `CustomerEditScreen` (6 セクションフォーム / ふりがな自動変換)
- `ImportCustomersScreen` (5 ステップ Excel インポートウィザード)
- 受給者証期限切れバッジ (ホーム画面 AppBar)
- `KanaUtil` (ひらがな↔カタカナ変換 / 半角カナ全角化)

### ✅ Day 4 — 当日出席管理 + PDF 出力
- `AttendanceStatus` enum (Hive typeId=2 / 4 ステータス: 予定/在室中/退室済/欠席)
- `AttendanceRecord` モデル (Hive typeId=1 / dateKey ベース管理)
- `AttendanceService`:
  - `ensureTodayScheduledRecords` (定期利用曜日から自動生成)
  - `markPresent` / `markDeparted` / `markAbsent` / `resetAbsent`
  - `updateCheckInTime` / `updateCheckOutTime` (手動時刻修正)
  - `getTodaySummary` / `getUnprocessedCount`
- `AttendancePdfService` (A4 縦 / サービス提供実績記録票 / Noto Sans JP)
- `AttendanceScreen`:
  - 集計バー (予定/在室中/退室済/欠席/空き枠)
  - AnimatedContainer カードグリッド (4/3/2/1 列)
  - 欠席理由ダイアログ (5 選択肢 + 自由入力)
  - LINE 通知確認ダイアログ (UI のみ / 送信は TODO)
  - タップで TimePicker が開く時刻チップ
  - 日付変更 / PDF 出力ボタン
- ホーム画面: 出席管理接続 / 未処理バッジ (緑丸) / 本日利用人数表示

---

## セットアップ手順

### 前提条件
- Flutter SDK 3.35.4
- Dart SDK 3.9.2
- Firebase プロジェクト設定済み (`lib/firebase_options.dart` が存在すること)

### 1. 依存パッケージのインストール

```bash
flutter pub get
```

### 2. Hive アダプターのコード生成

```bash
dart run build_runner build --delete-conflicting-outputs
```

> 生成ファイル:
> - `lib/models/customer.g.dart` (CustomerAdapter)
> - `lib/models/attendance_record.g.dart` (AttendanceRecordAdapter / AttendanceStatusAdapter)

### 3. 開発サーバーで起動

```bash
flutter run -d chrome
```

---

## ビルド

```bash
# Web リリースビルド（Service Worker 無効化 - キャッシュ問題対策）
flutter build web --release --pwa-strategy=none

# ビルド後の静的ファイルをローカルサーブ
python3 -m http.server 8080 --directory build/web
```

> **注意**: `--pwa-strategy=none` は必須オプションです。
> 省略すると Service Worker が古いビルドをキャッシュし、
> 認証状態が正しく反映されなくなる問題が発生します。
> 詳細は `lib/README.md` を参照してください。

---

## Hive TypeID 管理

| TypeID | クラス / Enum | ファイル |
|---|---|---|
| 0 | `Customer` | `lib/models/customer.dart` |
| 1 | `AttendanceRecord` | `lib/models/attendance_record.dart` |
| 2 | `AttendanceStatus` | `lib/models/attendance_record.dart` |

> **重要**: TypeID の重複は Hive の致命的エラーを引き起こします。
> 新モデル追加時は必ず 3 以降を使用してください。

---

## 今後の実装予定

| 機能 | 優先度 |
|---|---|
| Day 5: 週間利用計画 | 高 |
| Day 6: 翌日予約選択 | 高 |
| Day 7: 送迎計画 | 高 |
| Day 8: 業務日誌 | 中 |
| Day 9: 個別支援計画 | 中 |
| Day 10: 職員管理 | 低 |
| LINE 通知送信 (欠席空き枠) | 中 |
| SaaS 展開 (Firestore 同期 + tenantId) | 将来 |

---

## ディレクトリ構成

```
lib/
├── firebase_options.dart       # Firebase Web 設定
├── main.dart                   # エントリポイント / Hive 初期化
├── README.md                   # 開発者向け運用ガイド
├── models/
│   ├── customer.dart           # 顧客モデル (typeId=0)
│   ├── customer.g.dart         # build_runner 生成
│   ├── attendance_record.dart  # 出席レコード + ステータス (typeId=1,2)
│   └── attendance_record.g.dart
├── services/
│   ├── auth_service.dart       # Firebase Auth ラッパー
│   ├── customer_service.dart   # 顧客 CRUD
│   ├── attendance_service.dart # 出席管理 CRUD
│   └── attendance_pdf_service.dart # PDF 出力
├── screens/
│   ├── login_screen.dart
│   ├── home_screen.dart
│   ├── customer_management_screen.dart
│   ├── customer_edit_screen.dart
│   ├── import_customers_screen.dart
│   └── attendance_screen.dart
├── widgets/
│   ├── auth_gate.dart
│   ├── auth_loading_screen.dart
│   ├── attendance_status_badge.dart
│   └── attendance_time_chip.dart
├── theme/
│   └── app_theme.dart          # AppColors / AppTheme
└── utils/
    └── kana_util.dart          # ひらがな↔カタカナ変換
```

---

## ライセンス

**Proprietary** — 社内利用専用。無断複製・再配布禁止。  
将来的なSaaS展開を予定しています。

---

## セキュリティについて

- `lib/firebase_options.dart` に含まれる `apiKey` は Firebase Web API の公開設計仕様に準拠しています
- Firebase Console で **承認済みドメイン制限** を設定していることを前提とします
- Admin SDK キーや Service Account 秘密鍵はこのリポジトリに含まれていません
