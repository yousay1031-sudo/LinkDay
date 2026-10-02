# LINE 公式アカウント設定手順（人間がやる作業）

Day 11 で実装した「空き枠 LINE 通知」を**実際に動かすため**に、
人間が LINE / Google Cloud のコンソールで行う必要がある作業をまとめる。
コード側（Cloud Functions / Flutter）は実装済みで、以下が完了すれば稼働する。

> **最重要**: チャネルアクセストークン / チャネルシークレットは
> **Secret Manager にのみ保存**する。リポジトリ・クライアントコード・ログに
> 絶対に書かない。`functions/.gitignore` で `.env` 等をガードしてある。

---

## 0. 全体の流れ

| # | 作業 | 所要 | 担当 |
|---|------|------|------|
| 1 | LINE Developers で Messaging API チャネル作成 | 10分 | 管理者 |
| 2 | チャネルアクセストークン（長期）発行 | 2分 | 管理者 |
| 3 | 応答メッセージ（あいさつ・自動応答）の無効化 | 3分 | 管理者 |
| 4 | Firebase を Blaze プランへ切り替え | 5分 | 管理者 |
| 5 | secrets 設定 → Functions デプロイ | 10分 | 開発 |
| 6 | webhook URL の登録・検証 | 5分 | 管理者 |
| 7 | Firestore ルールのデプロイ | 2分 | 開発 |
| 8 | 自分のアカウントで実送信テスト | 10分 | 管理者 |

---

## 1. LINE Developers で Messaging API チャネルを作成

1. https://developers.line.biz/console/ にログイン
2. プロバイダーを作成（例: `ココスタディ`）
3. 「新規チャネル作成」→ **Messaging API** を選択
4. 入力項目
   - チャネル名: `ココスタディ`（**保護者のトーク一覧に表示される名前**）
   - チャネル説明: `放課後等デイサービス ココスタディ 連絡用`
   - 大業種 / 小業種: 医療・福祉 / 福祉・介護
   - メールアドレス: 事業所の連絡先
5. 利用規約に同意して作成

### チャネルシークレットの取得

作成後のチャネル画面 → **「チャネル基本設定」** タブ
→ **チャネルシークレット** をコピー（手順5で使う）。

---

## 2. チャネルアクセストークン（長期）を発行

1. チャネル画面 → **「Messaging API設定」** タブ
2. 最下部の **「チャネルアクセストークン（長期）」** で **「発行」** をクリック
3. 表示された文字列をコピー（手順5で使う）

> この画面でいつでも再発行できる。漏洩が疑われる場合は即「再発行」し、
> 手順5の secrets 更新 + 再デプロイを行う（旧トークンは無効になる）。

---

## 3. 応答メッセージ・あいさつメッセージを無効化

**この作業を飛ばすと、保護者が連携コードを送っても LINE の自動応答が
先に返ってしまい、連携が成立したか分かりにくくなる。**

1. チャネル画面 → 「Messaging API設定」タブ
   → **「LINE公式アカウント機能」** の「編集」リンク（LINE Official Account Manager が開く）
2. 「応答設定」で以下にする

| 項目 | 設定 | 理由 |
|------|------|------|
| 応答モード | **Bot** | webhook で処理するため |
| あいさつメッセージ | **オフ** | Functions の `follow` イベントで案内を送るため |
| 応答メッセージ | **オフ** | 連携コードの判定を webhook が行うため |
| Webhook | **オン** | 必須 |

---

## 4. Firebase を Blaze（従量課金）プランへ切り替え

**Cloud Functions から外部 API（LINE）を呼ぶには Blaze プランが必須**
（Spark プランは外部ネットワーク送信が禁止されている）。

1. https://console.firebase.google.com/project/linkday-proud/usage/details
2. 「プランを変更」→ **Blaze** を選択
3. 請求先アカウントを紐付け
4. **予算アラートを必ず設定する**（`docs/google_cloud_budget_alert.md` 参照）
   - 推奨: 月 1,000 円で通知

### 想定コスト

本機能の利用規模（1日数件の通知 + 連携 webhook）では、
Cloud Functions の無料枠（200万呼び出し/月）に十分収まるため
**実質 0 円**。Firestore も無料枠内（5万読み取り/日）。

---

## 5. secrets を設定して Functions をデプロイ

```bash
cd /path/to/linkday_app

# Firebase CLI にログイン（初回のみ）
firebase login
firebase use linkday-proud

# ── secrets を登録（対話式。入力値は画面に表示されない）
firebase functions:secrets:set LINE_CHANNEL_ACCESS_TOKEN
# → 手順2 でコピーしたトークンを貼り付けて Enter

firebase functions:secrets:set LINE_CHANNEL_SECRET
# → 手順1 でコピーしたチャネルシークレットを貼り付けて Enter

# 登録確認（値は表示されず、バージョン情報のみ）
firebase functions:secrets:access LINE_CHANNEL_ACCESS_TOKEN --version latest
# ↑ 値が見えてしまうので通常は実行しない。存在確認は下記で十分
firebase functions:secrets:get LINE_CHANNEL_ACCESS_TOKEN

# ── 依存インストール & デプロイ
cd functions && npm ci && npm run build && npm test && cd ..
firebase deploy --only functions
```

デプロイ完了後、出力に以下の URL が表示される（手順6で使う）:

```
Function URL (lineWebhook(asia-northeast1)):
  https://asia-northeast1-linkday-proud.cloudfunctions.net/lineWebhook
```

### デプロイされる関数

| 関数名 | 種別 | リージョン | secrets |
|--------|------|-----------|---------|
| `sendVacancyNotice` | Callable (v2 onCall) | `asia-northeast1` | `LINE_CHANNEL_ACCESS_TOKEN` |
| `lineWebhook` | HTTPS (v2 onRequest) | `asia-northeast1` | `LINE_CHANNEL_ACCESS_TOKEN`, `LINE_CHANNEL_SECRET` |

---

## 6. webhook URL を登録して検証

1. LINE Developers → チャネル → 「Messaging API設定」タブ
2. **Webhook URL** に手順5の URL を貼り付けて「更新」
   ```
   https://asia-northeast1-linkday-proud.cloudfunctions.net/lineWebhook
   ```
3. **「検証」** ボタンを押す → **「成功」** と表示されることを確認
4. **Webhookの利用** を **オン** にする

> 「検証」で失敗する場合は `firebase functions:log --only lineWebhook` を確認。
> `invalid signature rejected` が出ていれば `LINE_CHANNEL_SECRET` が
> 間違っている（手順5をやり直す）。

---

## 7. Firestore セキュリティルールをデプロイ

```bash
firebase deploy --only firestore:rules,firestore:indexes
```

ルール全文は `firestore.rules`。要点:

- 未認証は全面拒否
- `line_linkage` / `linking_codes`: 認証済み職員のみ read/write（形式検証つき）
- `notification_logs`: クライアントは **read のみ**。
  作成・更新・削除は Cloud Functions（Admin SDK）だけ
  → 「送信済み」判定を改ざんして二重送信することができない
- 上記以外のコレクションは全面拒否

---

## 8. 実送信テスト（開発用の自分のアカウントで）

1. スマホの LINE で、作成した公式アカウントを **友だち追加**
   （「Messaging API設定」タブの QR コードから）
2. 「連携コードを送信してください」という案内が届くことを確認
3. LinkDay アプリ → 児童管理 → 任意の児童を編集
   → 「LINE連携コード発行」→ 6桁コードが表示される
4. LINE のトークにそのコードを送信
   → **「連携が完了しました」** と返信が届く
5. LinkDay → 同じ画面で「連携状況を同期」→ **「連携済み（U...xxxx）」** 表示
6. 出席管理画面 → その児童**以外**を欠席登録
   → 候補ダイアログに手順3の児童が出る → 「送信する」
7. スマホに空き枠通知が届くことを確認

### ログ確認

```bash
firebase functions:log --only sendVacancyNotice --limit 20
```

成功時のログ例（**トークンは一切出力されない**）:
```
[sendVacancyNotice] push result {"date":"2026-10-02","customerId":"...",
  "lineUserId":"U****3f2a","status":"sent","httpStatus":200}
[sendVacancyNotice] done {"date":"2026-10-02","sent":1,"failed":0,...}
```

---

## 9. 運用上の注意

### 月間無料メッセージ数の上限（最重要）

LINE 公式アカウントの **コミュニケーションプラン** による制限:

| プラン | 月額 | 無料メッセージ数 | 超過時 |
|--------|------|-----------------|--------|
| **コミュニケーション（無料）** | 0円 | **200通/月** | **送信不可**（追加購入なし） |
| ライト | 5,500円 | 5,000通/月 | 追加不可 |
| スタンダード | 16,500円 | 30,000通/月 | 〜3円/通で追加可 |

**無料プランは 200通/月で止まる。**
1回の欠席で 5 件通知すると、月 40 回の欠席で上限に達する。
実運用では以下を守ること:

- 候補ダイアログで**本当に来られそうなご家庭だけチェックを残す**
  （既定は全 ON なので、不要な宛先は外す）
- 月の送信数は LINE Official Account Manager の「分析」で確認
- 通数が足りない場合はライトプランへ変更を検討

> カウント対象は push / multicast。webhook の reply は**無料**
> （連携コードのやり取りは通数を消費しない）。

### 二重送信・誤送信の防止機構（実装済み）

| 層 | 仕組み |
|----|--------|
| UI | 候補ダイアログで宛先を確認・チェックを外せる。キャンセルは何も送らない |
| クライアント | Hive の送信済み記録がある宛先はリクエストに含めない |
| サーバー | `notification_logs/{date}_{customerId}` を `create` で予約。既存なら `duplicate` を返し push しない |
| サーバー | `lineUserId` が `U + 32桁hex` でない宛先は送信しない |
| サーバー | 1リクエスト最大 50 宛先。同一 `customerId` の重複は正規化 |
| ルール | `notification_logs` はクライアントから書けない（改ざん不可） |

### トークンを失効させたいとき

1. LINE Developers で「チャネルアクセストークン（長期）」を**再発行**
2. `firebase functions:secrets:set LINE_CHANNEL_ACCESS_TOKEN` で更新
3. `firebase deploy --only functions`（新しい secret バージョンを参照させる）

---

## 10. トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| 「ログインの有効期限が切れています」 | Firebase Auth の ID トークン失効 | 再サインイン |
| 「LINE チャネルアクセストークンが未設定です」 | secrets 未設定 or 未再デプロイ | 手順5をやり直す |
| webhook 検証が失敗する | `LINE_CHANNEL_SECRET` 相違 | 手順5で再設定 |
| 送信が `failed` / HTTP 400 | 保護者が友だち解除/ブロック | 電話で連絡。連携解除して再連携 |
| 送信が `failed` / HTTP 429 | 月間通数の上限超過 | プラン変更を検討 |
| 候補が 0 件になる | 全員その日の予定あり / 支給量残なし | 正常動作（ダイアログに理由表示） |
| 「送信済み」と出て送れない | 同日同児童への二重送信ブロック | 仕様。履歴画面で状況確認 |

---

## 関連ドキュメント

- `docs/guardian_line_link_guide.md` — 保護者に配る連携手順書（印刷用）
- `docs/google_cloud_budget_alert.md` — 予算アラート設定
- `firestore.rules` — セキュリティルール全文
