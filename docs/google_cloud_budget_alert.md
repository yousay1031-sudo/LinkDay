# Google Cloud 予算アラート設定手順書

LinkDay は Google Maps Platform（Maps JavaScript API / Geocoding / Routes API）を
利用しており、**従量課金**です。想定外の呼び出し（キー流出・無限ループ・
大量一括ジオコーディング）による高額請求を防ぐため、**予算アラートの設定は必須**です。

対象プロジェクト: Google Maps API キーを発行した Google Cloud プロジェクト

---

## 0. 前提

- Google Cloud コンソールへのアクセス権（課金アカウントの「請求管理者」または「請求アカウント管理者」）
- 請求先アカウントがプロジェクトにリンク済みであること

> 注意: 予算アラートは **通知のみ**で、超過時に API を自動停止はしません。
> 強制的に止めたい場合は後述の「4. APIキー制限とクォータ上限」を併用してください。

---

## 1. 予算の作成

1. [Google Cloud コンソール](https://console.cloud.google.com/) を開く
2. 左上のハンバーガーメニュー → **「お支払い」(Billing)**
3. 対象の請求先アカウントを選択
4. 左メニュー → **「予算とアラート」(Budgets & alerts)**
5. 上部の **「予算を作成」(CREATE BUDGET)** をクリック

## 2. 予算のスコープ設定

| 項目 | 推奨設定 |
|------|---------|
| 名前 | `LinkDay Maps API 予算` |
| 時間範囲 | 毎月 (Monthly) |
| プロジェクト | LinkDay の Maps キーを発行したプロジェクトのみ |
| サービス | `Maps JavaScript API` / `Geocoding API` / `Routes API` に絞ると精度が上がる |
| 割引・クレジット | 「クレジットを割引として含める」をオンにする<br>（Google Maps の毎月の無料枠を反映させるため） |

## 3. 金額とアラートしきい値

**金額 (Target amount)**

- 「指定額」(Specified amount) を選択
- 事業所 1 拠点・児童 10〜30 名程度の想定運用であれば **月 3,000 円** 程度から開始
  （実績を 2〜3 ヶ月見て調整）

**アラートのしきい値 (Alert thresholds)**

実際の費用に対して以下の 4 段階を設定することを推奨します。

| しきい値 | 種別 | 意図 |
|---------|------|------|
| 50%  | 実際の費用 (Actual) | 月中の進捗確認 |
| 90%  | 実際の費用 (Actual) | 早期警告 |
| 100% | 実際の費用 (Actual) | 予算到達 |
| 100% | 予測額 (Forecasted) | 「このペースなら超える」事前警告 |

**通知先**

- 「メール通知をこの予算の管理者と費用管理者に送信する」をオンにする
- 追加で運用担当者へ飛ばしたい場合は **Cloud Monitoring の通知チャンネル** を作成し、
  予算作成画面の「Monitoring 通知チャンネルを管理する」から選択する

最後に **「完了」(FINISH)** をクリックして保存します。

---

## 4. APIキー制限とクォータ上限（併用を強く推奨）

予算アラートは通知のみなので、**実際の流出被害を止めるのはキー制限とクォータ**です。

### 4-1. HTTP リファラー制限

1. コンソール → **「APIとサービス」→「認証情報」**
2. LinkDay が使用している API キーを開く
3. 「アプリケーションの制限」→ **「HTTP リファラー（ウェブサイト）」** を選択
4. 本番で使うドメインのみ許可（例）
   ```
   https://linkday.example.com/*
   https://<your-project>.pages.dev/*
   ```
5. 「API の制限」→ **「キーを制限」** を選び、以下のみ許可
   - Maps JavaScript API
   - Geocoding API
   - Routes API

> LinkDay はブラウザ上の Maps JavaScript API 経由で
> ジオコーディング／ルート計算を行うため、キーは必然的に
> クライアントへ露出します。**リファラー制限が唯一の実効的な防御**です。

### 4-2. 1 日あたりのクォータ上限

1. コンソール → **「APIとサービス」→「有効なAPIとサービス」**
2. 各 API（Geocoding / Routes 等）を開き **「割り当て」(Quotas)** タブ
3. `Requests per day` を編集し、運用実態に合わせた上限を設定
   - 目安: 児童 30 名 × 送迎場所 3 件 ≒ 90 件/日 を超えることは通常ないため、
     Geocoding は **500 requests/day** 程度で十分
4. 上限に達すると API はエラーを返すため、**課金が物理的に止まります**

---

## 5. 設定後の確認

- [ ] 「予算とアラート」一覧に `LinkDay Maps API 予算` が表示されている
- [ ] しきい値が 50% / 90% / 100%(実績) / 100%(予測) の 4 件登録されている
- [ ] 通知先メールアドレスが運用担当者に届く状態になっている
- [ ] API キーに HTTP リファラー制限がかかっている
- [ ] Geocoding / Routes API に 1 日あたりのクォータ上限が設定されている

---

## 6. LinkDay 側のコスト抑制の仕組み（実装済み）

参考として、アプリ側でも以下の対策が入っています。

| 対策 | 実装箇所 |
|------|---------|
| ジオコード候補のセッションキャッシュ（同一クエリの再呼び出しを回避） | `lib/services/maps_js_service.dart` の `_candidateCache` |
| Maps JS API の多重ロード防止 | `lib/services/maps_loader.dart`（`_loaded` / `_loadedKey`） |
| 起動時に Geocoder / Routes API を自動呼び出ししない（ユーザー操作起点のみ） | 各画面の `initState` は Hive 読み出しのみ |
| APIキー未設定時は Haversine 距離による内部計算へフォールバック（API を呼ばない） | `lib/services/transport_plan_service.dart` |
| 解決済み座標を Hive に永続化し、再ジオコーディングを回避 | `Customer.transportLocationLats/Lngs/Status` |
| 上書きインポート時も解決済み座標を保持（再ジオコード不要） | `lib/services/customer_import_service.dart`（Day 10 修正） |
