# ローカル検証環境（Day 15 / エミュレータ方式。2026-11-19 Firestore 移行に合わせて更新）

本番の認証・データ・Hosting に一切触れず、通常のログイン画面を通して画面を確認するための構成。

## 1. 起動・データ投入・終了
```bash
tool/verify/start_emulators.sh          # Auth 127.0.0.1:9099 / Firestore 127.0.0.1:8080 / Functions 127.0.0.1:5001（所属の関数だけ。§1.5）
node tool/verify/seed.mjs               # 認証ユーザー + 事業所・所属・職員・業務データ・slots（認証情報は ~/.linkday_verify/credentials.json、表示しない）
node tool/verify/seed.mjs --reset       # エミュレータ内の Auth/Firestore を全消去して入れ直す
node tool/verify/seed.mjs --reset --data empty   # 業務データなし（空の状態の確認用。事業所・所属・職員は入る）
tool/verify/build_verify.sh             # build/verify_web に出力（MODE=profile も可）
tool/verify/serve_verify.sh             # 127.0.0.1:8765（標準 Chrome で開けるポート。5060 は不可）
tool/verify/test_rules.sh               # ルールテスト（最初に、エミュレータが今の firestore.rules で判定しているか確かめる）
# 終了（配信 8765 も止まる）
tool/verify/stop_emulators.sh
```
- 外部公開しない: エミュレータ・配信とも 127.0.0.1 のみ。共有プレビューが必要なときだけ `BIND=0.0.0.0` と GetServiceUrl を使う。

### 保存先（すべて Firestore、`facilities/{facilityId}/` の下）
| 種類 | ドキュメント | 備考 |
|---|---|---|
| 顧客 | `customers/{顧客ID}` | 在籍終了 = `isActive:false`（削除しない）。「在籍終了の顧客」から在籍に戻せる |
| 週間利用計画 | `scheduleEntries/{YYYY-MM-DD}_{顧客ID}`、`scheduleWeeks/{weekKey}` | マス 1 件 = 1 ドキュメント。週の目印があれば作り直さない。まだ無い週は開いたときに「自動」で作る（通信できなければ作らず再試行） |
| 出席 | `attendance/{YYYY-MM-DD}_{顧客ID}` | 入室・退室・欠席・欠席の取り消しはトランザクション。通信できなければ記録せず「再試行」 |
| 送迎計画 | `transportRoutes/{YYYY-MM-DD}_{pickup|dropoff}_{車両番号}` | 停留所の並びはルートの中 |
| 設定 | `settings/app` | Maps の API キーは置かない（端末の SharedPreferences） |
| 職員 | `staff/{職員ID}` | 担当者の選択用・職員管理。在籍終了 = `isActive:false`。管理者・ログインの許可などは管理者だけが変えられる（ステップ2） |
| 職員の Google メールアドレス | `staffAccounts/{職員ID}` | 管理者だけが読み書きできる（ステップ2） |
| ログイン履歴 | `loginHistory/{uid}_{auth_time}` | 追記だけ。読めるのは管理者だけ（ステップ2） |

- 最上位: 事業所 `facilities/demo-facility`、検証ユーザーの所属 `memberships/{uid}`（クライアントからは書けない）。
- すべての書き込みに `updatedAt`（サーバー時刻）・`updatedByStaffId`・`updatedByStaffName` が付く。自動処理は「自動」、最初の職員登録は「初期設定」、`seed.mjs` の投入は「検証データ」。
- **Hive に残るのは通知履歴（`notification_logs`、端末ごと）だけ**。検証アプリが起動時に投入する（`lib/verify/verify_seed.dart`）。

### seed.mjs が投入するもの（無いときだけ作る。画面で変えた内容は再投入で戻らない）
- 事業所・所属・架空の職員 3 名（職員 春子／夏男／秋子）
- 顧客 61 名（在籍中 60 + 在籍終了 1）… `tool/verify/dummy_customers.mjs`
- 週間利用計画（先週・今週・来週）… `dummy_schedule.mjs`
- 出席（直近 5 日の実績 + 今日の予定/在室/退室済/欠席）… `dummy_attendance.mjs`
- 送迎計画（今日のお迎え 3 台・お送り 2 台）… `dummy_transport.mjs`
- 設定（架空の事業所）… `dummy_settings.mjs`
- Firestore の slots（出席画面の「LINE応募」表示用）
- 規則は `lib/verify/verify_seed.dart` の `buildCustomer` / `buildDemoWeeks` と同じ（ID・氏名・今日の予定がそろう）。片方を変えたらもう片方も変える。

### 画面での動き
- ログイン後は所属事業所を確認してからホーム画面に進む。所属が無いアカウントは「事業所に登録されていません」画面になる。
- 画面上部の帯で担当者を選ぶ。選んだ担当者は「選んだ日」と一緒に端末へ保存し、日付が変わると未選択に戻る。ログアウトすると端末の保存も消える。未選択で記録を変える操作をすると選択を求められ、選ばなければ何も保存しない。
- 他の端末の変更は、画面を開き直さずに届く。
- ログアウト時、まだ送信されていない記録があればログアウトを止めて知らせる（黙って消さない）。送信済みなら端末内の Firestore キャッシュも消す。
- ルールのテスト: `tool/verify/test_rules.sh`（起動中のエミュレータに別プロジェクトID `demo-linkday-rules` で接続。検証データは消さない）。
  - 最初に `tool/verify/check_rules_loaded.mjs` が、いまの firestore.rules を検証用（demo-linkday）とテスト用（demo-linkday-rules）の両方に読み込ませ、検証用で「所属は読める／所属なし・未認証は拒否／担当者の記録がない書き込みは拒否」を実際に試す。古いルールのままなら NG で止まり、ルールテストは実行しない。判定だけ試すときは `--check-only`。

## 1.5 ステップ2（Google ログインと職員管理。2026-11-25 追加）

### Functions エミュレータ（所属の関数だけ・LINE の関数は読み込まない）
- `start_emulators.sh` は Functions エミュレータ（127.0.0.1:5001）も起動する。読み込むのは `tool/verify/functions_account/`（`functions/lib/account` だけを読み込む入口）で、`firebase.emulator.json` の Functions はこの入口だけを指す。**LINE の関数（sendVacancyNotice / lineWebhook）は検証環境では読み込まれもしない。**
  - 起動前に `npm --prefix functions run build` を行い、入口から `functions/node_modules` へのリンクを作る（リンクは git に入れない）。`functions/node_modules` が無ければ先に `(cd functions && npm ci --no-audit --no-fund --ignore-scripts)`。
- **秘密情報を渡さない**: `functions/.secret.local` などがあれば起動を中断する。`LINE_CHANNEL_*` の環境変数も外す。
- **外部への接続を止めて記録する**: `tool/verify/block_external.cjs` を `NODE_OPTIONS=--require` で読み込ませ、エミュレータの Node の処理（firebase-tools 本体・Functions の実行環境・npm）がループバック以外へ接続しようとしたら止めて `/tmp/linkday_emulator_net.log` に記録する（宛先・ポートだけ。中身は記録しない）。起動時に件数を表示する。合格条件は 0 件。
  - 2026-11-25 に見つけて止めたもの（送信されていない）: firebase-tools が資格情報を探す GCE の metadata サーバー（169.254.169.254・metadata.google.internal）と、Functions の SDK の最新版を調べる `npm show`（registry.npmjs.org）。`METADATA_SERVER_DETECTION=none` と `npm_config_offline=true` で、試みないようにした。
- 古い構成（Functions なし）で起動中なら、`start_emulators.sh` は止まるよう案内する。`stop_emulators.sh` → `start_emulators.sh` で起動し直す。

### Google ログインの模擬（本物の Google には接続しない）
- 検証ビルドのログイン画面で「Googleでログイン」を押すと、「検証用：Google ログインの模擬」の画面が出る。ダミーのアドレスを入れると、Auth エミュレータへ署名のない JSON を Google の ID トークンとして渡してログインする（`AuthService.signInWithEmulatorGoogle`）。本番のポップアップ（`signInWithPopup`）は検証環境では確かめられない（手順書の公開後の確認に入れた）。
- seed.mjs の職員（アドレスは実在しない `.invalid`）:

| 職員 | 管理者 | ログインの許可 | Google メールアドレス |
|---|---|---|---|
| 職員 春子 | はい（最初の管理者） | はい | `haruko@example.invalid` |
| 職員 夏男 | いいえ | はい | `natsuo@example.invalid` |
| 職員 秋子 | いいえ | いいえ | なし（共用端末だけを使う） |

- 登録の無いアドレス（例 `stranger@example.invalid`）でログインすると「このアカウントは事業所に登録されていません」になる。
- 共用端末アカウント（従来のメールアドレスとパスワード）の動きは変えていない。

## 2. 本番へ誤接続しない仕組み
- 切替は `--dart-define=LINKDAY_VERIFY=true`（コンパイル時。debug 限定ではなく release/profile 可）。通常ビルドは `const false` で検証コードは tree-shake される。
- プロジェクトIDは `demo-*` 必須・`linkday-proud` 拒否・ホストはループバックのみ（`VerifyConfig.validate`）。
- 起動時にエミュレータへ事前疎通。失敗したら `VerifyFailureApp` を出して終了し、本番へはフォールバックしない。
- 検証構成は `FirebaseOptions` もダミー（apiKey `demo-api-key`）。Functions はループバック宛、LINE 送信は `remoteEnabled:false` で遮断。Functions エミュレータは所属の関数だけを読み込み、LINE の関数は読み込まない（§1.5）。
- seed.mjs は `guard.mjs` で対象を検証し、本番ID・非ループバック・エミュレータ未設定を拒否。
- 検証ビルド出力は `build/verify_web`。Hosting の `public` は `build/web` なので混在しない。**検証ビルドを `firebase deploy` しないこと。**
- 画面下に Firebase SDK の「Running in emulator mode」バナーと検証ストリップが出る。

## 3. 状態の再現手順
| 状態 | 手順 |
|---|---|
| 通常 | `node tool/verify/seed.mjs --reset`（業務データは Firestore。`?verify_data=normal` は Hive の通知履歴だけを入れ直す） |
| 空 | `node tool/verify/seed.mjs --reset --data empty`（`?verify_data=empty` は Hive の通知履歴だけを空にする） |
| 通信が切れた状態 | Chrome の開発者ツールでオフライン（入室・退室・まだ無い週の作成は「再試行」になる。顧客・週間計画などの編集は端末に残り、通信が戻ると送られる） |
| 読込（スケルトン） | localStorage `flutter.verify_delay_ms` = `3000` |
| エラー | localStorage `flutter.verify_faults` = `"attendance"`（他: usage / weekly / transport / settings）。解除してから「再試行」 |
| Firestore側エラー | Firestore エミュレータを停止 |

## 4. 既知の問題（原因未確定のものは断定しない）
- **【対応済み 2026-11-19】再読み込みで認証が本番エンドポイントへ出ていた**（main=bc3ca0c の検証ビルドでも再現していた）
  - 原因: Web 版 firebase_auth は `Firebase.initializeApp` の中で Auth を作り、保存済みログインの確認 `accounts:lookup` をその場で始める。`useAuthEmulator` はその後なので、ログイン状態が保存されていると最初の通信が本物の `identitytoolkit.googleapis.com` へ出て、エミュレータ設定は黙って失敗する（プラグインがエラーを握りつぶす）。以後のログイン `accounts:signInWithPassword` も本物宛てになる。Google が 400 を返すとログアウト状態になり再ログインも失敗する。Google へ届かない環境（通信失敗）ではログイン状態が保たれたままホーム画面に進み、ログアウト→再読み込み→再ログインはエミュレータで成功する（保存済みログインが無い起動ではエミュレータ設定が間に合うため）。
  - 対策（検証構成のみ）: `lib/verify/verify_auth_guard*.dart`。`Firebase.initializeApp` の前に、Auth の JS モジュールが `window.firebase_auth` に入る時点で `initializeAuth` を包み、Auth を作った直後（通信前）に `connectAuthEmulator` を呼ぶ。仕掛けられない・働かなかった場合は起動失敗画面で止める（本番へフォールバックしない）。通常ビルドの出力は変わらない（main.dart.js が同一であることを確認）。
  - 確認方法: Chrome の通信記録（CDP。ページ・Service Worker・WebSocket）で、ログイン→担当者選択→再読み込み→ログアウト→再読み込み→再ログイン→再読み込みの間 `*.googleapis.com` 宛て 0 件。
  - 修正前に、検証用のダミー資格情報が本物の宛先へ送られた可能性があるため作り直した（下記の手順）。
- **ダミー資格情報の作り直し**: `rm ~/.linkday_verify/credentials.json && node tool/verify/seed.mjs --reset`（エミュレータ内の Auth/Firestore を全消去し、新しいパスワードで作り直す。値は表示しない）。
- **外部通信の合格条件（2026-11-19 承認）**: 「資格情報やデータを含む外部通信が 0 件」。検証中に1件でも出たら作業を止めて相談する。確かめ方は Chrome の通信記録（CDP。ページ・Service Worker・WebSocket）で、ループバック（127.0.0.1）以外の宛先を一覧にする。
- **認められている外部取得（静的ファイルのみ。資格情報・データを含まない）**: 検証ビルドも通常ビルドと同じく、次を Google の配信元から取得する。これ以外の宛先（特に `*.googleapis.com`）が出たら条件違反。
  - `www.gstatic.com/flutter-canvaskit/…`（画面描画エンジン）
  - `www.gstatic.com/firebasejs/11.9.1/…`（Firebase JS SDK）
  - `fonts.gstatic.com/s/roboto/…`、`fonts.gstatic.com/s/notosansjp/…`（フォント）
  - `fonts.gstatic.com/s/notosanssc/…`、`…/notosanstc/…`、`…/notosanshk/…`、`…/notosanskr/…`（2026-11-19 承認）: 中国語（簡体・繁体・香港）・韓国語の Noto フォント。通信が切れていて日本語フォントを読めない間に、描画エンジンが代わりのフォントとして取りに行くとみられる（推測）。日本語フォントと同じ配信元の静的なフォントファイルで、**資格情報・データを含まない**（URL はフォントのファイルを指すだけ）。
  - `www.google.com/images/cleardot.gif?zx=<乱数>`（2026-11-19 承認）: **通信が切れている間だけ**出る Firestore JS SDK の接続確認とみられる取得。ヘッダーは Referer（`http://127.0.0.1:8765/`）・User-Agent・sec-ch-ua だけで、**資格情報・データ・Cookie は含まない**。検証ではブラウザがオフラインのため送信されなかった（ERR_INTERNET_DISCONNECTED）。
- **エミュレータのルールが古いまま残ることがある**（2026-11-19、原因未確定）: ブランチの書き直し（rebase）で firestore.rules が一時的に古い版へ戻った後、エミュレータは「Rules updated」と表示しながら、main の旧ルール（業務データ全面拒否）のまま判定していた。ファイルを touch しても直らず、`stop_emulators.sh` → `start_emulators.sh` → `seed.mjs` で解消した。ログイン後に「データを読み込めませんでした」になり、エラーに `false for 'get' @ L129` のような旧ルールの行番号が出たら、エミュレータを起動し直す。
- **Service Worker 初回再読込**: 新規プロファイルの初回訪問で canvaskit.js / canvaskit.wasm / main.dart.js が `ERR_ABORTED` になり再読込される。記録のみ。根拠なく削除・改修しない。
- **テンキー「−」例外**: keydown key='-' code='NumpadSubtract' location=3 で `TypeError: Cannot read properties of null (reading 'toString')`。スタック: main.dart.js:45055 ← 44913 ← 45075 ← 51302 ← 45009 ← 45021 ← 44943/44949 ← 7433。エンジン側マップ `[45,null,null,8589935149]` が関与する可能性はあるが、原因は未確定でエンジン不具合とは断定しない。
- **setSelectionRange InvalidStateError**: ログイン画面の email 入力中にコンソールへ出る（main.dart.js:49400）。原因未確認。画面操作は継続できた。
- **自動入力で先頭1文字欠落**: Tab 直後の即時入力で発生。500ms 待てば回避。実機での再現は未確認。
- パスワードに `-` を含めると上記テンキー例外に当たるため、生成パスワードは英数字のみ。

## Day15 追補: 入力不具合の切り分け結果（docs/day15_input_investigation/）
- 先頭1文字欠落: ログイン画面で Tab 直後に即入力すると、セマンティクスON時のみ再現（待機0/ON: 11/24 失敗、待機100ms/ON: 0/16、待機0/OFF: 0/16）。
  Tab 後に focusout/focusin が 21〜33ms 遅れて届き、その間の文字が前の入力欄に入る。エンジン側フォーカス遅延と自動入力速度の組合せを示唆。アプリ不具合は未確立。人手入力・日本語IMEは未確認。
- setSelectionRange 例外: セマンティクスON + type=email の DOM 入力で発生（ON 12/12、OFF 0/12）。コンソールのみ・値と保存は影響なし。
- テンキー「−」例外: puppeteer press('NumpadSubtract') が keydown location=3 / keyup location=1 を送り、エンジンの kWebLogicalLocationMap が null となり TypeError。CDP の isKeypad:true を両方に付けると発生しない。実機テンキーは未確認。
- スクリプトは docs/day15_input_investigation/scripts/（認証情報は含まない）。
