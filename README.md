# LinkDay

**放課後等デイサービス運営支援アプリ**

児童発達支援・放課後等デイサービスの日常業務（顧客管理・出席管理・送迎計画・書類出力・空き枠の LINE 通知）をデジタル化し、施設スタッフの業務効率を高める Web アプリケーションです。

| 項目 | 内容 |
|------|------|
| 本番 URL | https://linkday-proud.web.app |
| 予備 URL | https://linkday-proud.firebaseapp.com |
| Firebase プロジェクト | `linkday-proud`（Blaze プラン） |
| バージョン | v1.0（Day 12 時点） |
| テスト | 202 件全緑 |

> 機能一覧・既知の制限・今後の拡張候補は **[docs/release_notes_v1.md](docs/release_notes_v1.md)** を参照してください。

---

## 技術スタック

| 分類 | 技術 |
|---|---|
| フレームワーク | Flutter 3.35.4 / Dart 3.9.2 |
| UI | Material Design 3 (`useMaterial3: true`) |
| ローカル DB | Hive 2.2.3 + hive_flutter 1.1.0（Web では IndexedDB） |
| 認証 | Firebase Authentication（email/password） |
| サーバー処理 | Cloud Functions v2 (Node.js 20 / TypeScript) — `asia-northeast1` |
| クラウド DB | Cloud Firestore（LINE 連携用の 3 コレクションのみ） |
| 配信 | Firebase Hosting |
| 地図 | Google Maps JavaScript API / Geocoding API / Routes API |
| 外部連携 | LINE Messaging API |
| PDF 出力 | pdf 3.11.1 + printing 5.13.4 |
| Excel インポート | excel 2.1.0 + file_picker 8.1.4 |
| 状態管理 | Provider 6.1.5+1 |
| ターゲット | Flutter Web（JS ビルド） |

---

## データの置き場所

**業務データ（児童情報・出席・送迎計画）はクラウドに送信しません。**
ブラウザの端末内ストレージ（Hive / IndexedDB）に保存します。

Firestore に保存するのは LINE 連携に必要な最小限の情報のみです。

| コレクション | 内容 | クライアントからの書き込み |
|-------------|------|------------------------|
| `line_linkage` | 児童 ID と LINE userId の紐付け | 可（認証済み職員のみ） |
| `linking_codes` | 6桁の連携コード（有効期限7日） | 作成・削除のみ |
| `notification_logs` | 通知送信ログ（二重送信の防止キー） | **不可**（Functions のみ） |

> この設計により、児童の個人情報が外部に出ません。
> 一方で、端末のブラウザデータを消すとデータが失われます。
> 定期的な CSV エクスポートによるバックアップを推奨します。

---

## セットアップ手順

### 前提条件

- Flutter 3.35.4 / Dart 3.9.2
- Node.js 20（Cloud Functions 用）
- Firebase CLI
- `linkday-proud` プロジェクトへのアクセス権

### 1. 依存パッケージのインストール

```bash
flutter pub get
cd functions && npm ci && cd ..
```

### 2. Hive アダプターのコード生成

モデル（`lib/models/*.dart`）を変更した場合のみ必要です。

```bash
dart run build_runner build --delete-conflicting-outputs
```

### 3. Google Maps API キーの設定

キーはソースに埋め込まず、アプリの**設定画面から入力**します（端末内に保存）。

1. アプリを起動してログイン
2. ホーム → 設定 → 「Google Maps API キー」に入力
3. 事業所住所を入力して座標を取得

> キーには必ず HTTP リファラ制限をかけてください。
> 詳細は [docs/production_monitoring_setup.md](docs/production_monitoring_setup.md) を参照。

### 4. ローカルで起動

```bash
flutter run -d chrome --web-port 5060
```

---

## ビルドとデプロイ

### Web ビルド

```bash
flutter build web --release
```

> **注意**: 依存パッケージを追加・変更した直後は、必ず `flutter clean` を実行してください。
> ビルドキャッシュ内の `web_plugin_registrant.dart` が古いままだと、
> 新しいプラグインが登録されず `MissingPluginException` が発生します（Day 11 で実際に発生）。
>
> ```bash
> flutter clean && flutter pub get && flutter build web --release
> ```

### Hosting へデプロイ

```bash
firebase use linkday-proud
flutter build web --release
firebase deploy --only hosting
```

### Cloud Functions へデプロイ

```bash
cd functions && npm run build && npm test && cd ..
firebase deploy --only functions
```

### Firestore ルール・インデックス

```bash
firebase deploy --only firestore:rules,firestore:indexes
```

### secrets（LINE のトークン類）

```bash
firebase functions:secrets:set LINE_CHANNEL_ACCESS_TOKEN
firebase functions:secrets:set LINE_CHANNEL_SECRET
firebase deploy --only functions   # 反映には再デプロイが必要
```

> 値をコマンドライン引数やファイルに書かないでください。対話入力で渡します。

---

## キャッシュ戦略（firebase.json）

Flutter Web の `main.dart.js` は**ハッシュ付きファイル名ではありません**（固定名）。
そのため `immutable` を付けると、再デプロイしても古い JS が配信され続けます。

`firebase.json` では以下の方針にしています。

| 対象 | Cache-Control | 理由 |
|------|--------------|------|
| `/`, `/index.html` | `no-cache, must-revalidate` | 更新を即反映させる |
| `main.dart.js` / `flutter.js` / `flutter_bootstrap.js` | `no-cache, must-revalidate` | 固定名のため必ず再検証 |
| `flutter_service_worker.js` | `no-cache, must-revalidate` | 古い SW の固着を防ぐ |
| `canvaskit/**`, `assets/**`, `icons/**` | `public, max-age=86400` | SDK 更新時のみ変化 |

`no-cache` は「キャッシュしない」ではなく「毎回サーバーに確認する」という意味です。
変更がなければ 304 が返るため、転送量はほとんど増えません。

---

## テストと静的解析

```bash
flutter analyze            # 警告ゼロを維持
flutter test               # 202 件
cd functions && npm test   # 41 件
```

---

## Hive TypeID 管理

**TypeID は一度割り当てたら変更しないでください。** 既存データが読めなくなります。

| TypeID | クラス |
|--------|--------|
| 0 | `Customer` |
| 1 | `AttendanceRecord` |
| 2 | `AttendanceStatus` |
| 3 | `WeeklySchedule` |
| 4 | `DailySlot` |
| 5 | `ScheduleStatus` |
| 6 | `ScheduleEntry` |
| 7 | `AppSettings` |
| 8 | `TransportVehicleRoute` |
| 9 | `TransportStop` |
| 10 | `TransportType` |
| 11 | `NotificationLog` |
| 12 | `NotificationStatus` |

フィールドを追加する場合は、既存のフィールド番号を変えず、末尾に追加してください。

---

## ディレクトリ構成

```
linkday_app/
├── lib/
│   ├── main.dart                  # 起動・Hive 初期化・Firebase 初期化
│   ├── firebase_options.dart      # Firebase 設定（Web キーは公開前提）
│   ├── models/                    # Hive モデル（*.g.dart は生成物）
│   │   ├── customer.dart
│   │   ├── attendance_record.dart
│   │   ├── weekly_schedule.dart
│   │   ├── app_settings.dart
│   │   ├── transport_plan.dart
│   │   └── notification_log.dart
│   ├── services/
│   │   ├── auth_service.dart
│   │   ├── customer_service.dart
│   │   ├── customer_import_service.dart
│   │   ├── customer_export_service.dart
│   │   ├── attendance_service.dart
│   │   ├── weekly_schedule_service.dart
│   │   ├── monthly_usage_service.dart       # 支給量の残日数集計
│   │   ├── settings_service.dart
│   │   ├── transport_plan_service.dart      # 送迎グループ分け・ルート
│   │   ├── transport_location_resolver.dart # 住所→座標の解決
│   │   ├── google_maps_service.dart         # APIキーのマスク処理を含む
│   │   ├── maps_js_service.dart             # JS Interop（Geocoder/Routes）
│   │   ├── maps_loader.dart                 # Maps JS の多重ロード防止
│   │   ├── maps_bridge*.dart                # Web/非Web の条件付き実装
│   │   ├── vacancy_notification_service.dart # 空き枠 LINE 通知
│   │   └── *_pdf_service.dart               # 各種 PDF 出力
│   ├── screens/                   # 12 画面
│   ├── widgets/
│   ├── theme/
│   └── utils/
├── functions/                     # Cloud Functions（TypeScript）
│   └── src/
│       ├── index.ts
│       ├── config.ts              # リージョン・コレクション名
│       ├── sendVacancyNotice.ts   # 通知送信（Callable）
│       └── lineWebhook.ts         # LINE webhook（HTTPS）
├── docs/                          # 運用手順書（下記参照）
├── test/                          # 202 件
├── firebase.json                  # Hosting / Functions / Firestore 設定
├── firestore.rules                # セキュリティルール
└── firestore.indexes.json
```

---

## ドキュメント

| ファイル | 内容 | 読む人 |
|---------|------|-------|
| [docs/release_notes_v1.md](docs/release_notes_v1.md) | 機能一覧・既知の制限・今後の拡張候補 | 全員 |
| [docs/firebase_auth_production_setup.md](docs/firebase_auth_production_setup.md) | 認証のセキュリティ設定手順 | 管理者 |
| [docs/production_monitoring_setup.md](docs/production_monitoring_setup.md) | Maps キー・予算・LINE 残枠・障害対応 | 管理者 |
| [docs/google_cloud_budget_alert.md](docs/google_cloud_budget_alert.md) | Maps API の予算・クォータ詳細 | 管理者 |
| [docs/line_official_account_setup.md](docs/line_official_account_setup.md) | LINE 公式アカウントの作成・連携 | 管理者 |
| [docs/guardian_line_link_guide.md](docs/guardian_line_link_guide.md) | 保護者向けの LINE 連携案内 | 保護者配布用 |
| [docs/day10_audit_report.md](docs/day10_audit_report.md) | 本番前総点検の記録 | 開発 |

---

## セキュリティについて

- `lib/firebase_options.dart` の `apiKey` は **Web クライアントに配布される前提の公開値**です。
  秘密情報ではなく、ブラウザの開発者ツールからも見えます。
  悪用防止は **Authentication の承認済みドメイン** と **Firestore セキュリティルール** で担保しています。
- **Google Maps の API キーは別管理**で、リポジトリに含めません。
  アプリの設定画面から入力し、端末内に保存します。HTTP リファラ制限が必須です。
- LINE のチャネルアクセストークンとシークレットは **Secret Manager にのみ**保存します。
  リポジトリ・クライアントコード・ログには一切含めません。
- Admin SDK キーや Service Account 秘密鍵はリポジトリに含まれていません。

---

## ライセンス

**Proprietary** — 社内利用専用。無断複製・再配布禁止。
将来的な SaaS 展開を予定しています。
