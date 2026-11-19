# ローカル検証環境（Day 15 / エミュレータ方式）

本番の認証・データ・Hosting に一切触れず、通常のログイン画面を通して画面を確認するための構成。

## 1. 起動・データ投入・終了
```bash
tool/verify/start_emulators.sh          # Auth 127.0.0.1:9099 / Firestore 127.0.0.1:8080（Java 17 + firebase-tools）
node tool/verify/seed.mjs               # ローカル認証ユーザー + Firestore slots（認証情報は ~/.linkday_verify/credentials.json、表示しない）
tool/verify/build_verify.sh             # build/verify_web に出力（MODE=profile も可）
tool/verify/serve_verify.sh             # 127.0.0.1:8765（標準 Chrome で開けるポート。5060 は不可）
# 終了
tool/verify/stop_emulators.sh
```
- 顧客・出席・週間計画・設定・送迎計画・通知履歴は Hive(IndexedDB) のため、検証アプリが起動時に自分で投入する（顧客 60 件 + 非在籍 1 件）。
- 外部公開しない: エミュレータ・配信とも 127.0.0.1 のみ。共有プレビューが必要なときだけ `BIND=0.0.0.0` と GetServiceUrl を使う。

### Firestore 移行（作業中）で増えたもの
- `seed.mjs` は、事業所 `demo-facility`、検証ユーザーの所属 `memberships/{uid}`、架空の職員3名（職員 春子／夏男／秋子）も投入する。職員は無いときだけ作る（画面で変えた内容は再投入で戻らない。全消去は `--reset`）。
- ログイン後は所属事業所を確認してからホーム画面に進む。所属が無いアカウントは「事業所に登録されていません」画面になる。
- 画面上部の帯で担当者を選ぶ（端末ごとに保存）。未選択で記録を変える操作をすると選択を求められる。
- ルールのテスト: `tool/verify/test_rules.sh`（起動中のエミュレータに別プロジェクトID `demo-linkday-rules` で接続。検証データは消さない）。
- まだ Firestore に移していない種類（顧客・出席・週間計画・設定・送迎・通知履歴）は、従来どおり Hive 側をアプリが起動時に投入する。

## 2. 本番へ誤接続しない仕組み
- 切替は `--dart-define=LINKDAY_VERIFY=true`（コンパイル時。debug 限定ではなく release/profile 可）。通常ビルドは `const false` で検証コードは tree-shake される。
- プロジェクトIDは `demo-*` 必須・`linkday-proud` 拒否・ホストはループバックのみ（`VerifyConfig.validate`）。
- 起動時にエミュレータへ事前疎通。失敗したら `VerifyFailureApp` を出して終了し、本番へはフォールバックしない。
- 検証構成は `FirebaseOptions` もダミー（apiKey `demo-api-key`）。Functions はループバック宛、LINE 送信は `remoteEnabled:false` で遮断。
- seed.mjs は `guard.mjs` で対象を検証し、本番ID・非ループバック・エミュレータ未設定を拒否。
- 検証ビルド出力は `build/verify_web`。Hosting の `public` は `build/web` なので混在しない。**検証ビルドを `firebase deploy` しないこと。**
- 画面下に Firebase SDK の「Running in emulator mode」バナーと検証ストリップが出る。

## 3. 状態の再現手順
| 状態 | 手順 |
|---|---|
| 通常 | 既定 / `?verify_data=normal`（全消去して再投入） |
| 空 | `?verify_data=empty` |
| 読込（スケルトン） | localStorage `flutter.verify_delay_ms` = `3000` |
| エラー | localStorage `flutter.verify_faults` = `"attendance"`（他: usage / weekly / transport / settings）。解除してから「再試行」 |
| Firestore側エラー | Firestore エミュレータを停止 |

## 4. 既知の問題（原因未確定のものは断定しない）
- **【要対応・安全装置の穴】再読み込みで認証が本番エンドポイントへ出る**（2026-11-19 確認。main=bc3ca0c の検証ビルドでも再現）: ログイン済みでページを再読み込みすると、保存済みセッションの確認 `accounts:lookup` が `identitytoolkit.googleapis.com`（本物の Google）へ送られ 400 で失敗し、ログアウト状態になる。その後に再ログインすると `accounts:signInWithPassword` も同じく本物へ送られる（検証用のダミー資格情報）。`demo-api-key` のため受理はされないが「ループバックのみ」の前提に反する。Firebase.initializeApp 時に Auth が保存済みセッションの確認を始め、その後の useAuthEmulator が効かないためと見られる（原因は未確定）。**対応方針が決まるまで、検証構成では再読み込み後に再ログインしない。**
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
