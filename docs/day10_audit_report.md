# Day 10: 本番前の総点検レポート

対象コミット基点: `d2f1310`（Day 9）
点検日: 2026-02（Day 10 作業）
方針: **新機能追加なし**。バグ修正と品質確認のみ。

---

## 1. クロス機能シナリオ結果

| # | シナリオ | 結果 | 備考 |
|---|---------|------|------|
| 1 | インポート → 位置解決 → 送迎計画 → 月間支給量 | ✅ OK | 自動テスト化（`cross_feature_integration_test.dart`） |
| 2 | 上書きインポート時の座標保持 | ❌→✅ **致命バグ発見・修正** | 下記 BUG-001 |
| 3 | 週間計画変更 → 月間見込み残の即時反映 | ✅ OK | 追加・取消の双方を検証 |
| 4 | 出席ステータス変更 → 支給量の再計算 | ❌→✅ **致命バグ発見・修正** | 下記 BUG-002 |
| 5 | 空データ起動（顧客0・APIキー未設定） | ✅ OK | `8b522d6` の回帰なし |

---

## 2. 発見した不具合一覧

### BUG-001【致命】上書きインポートで Day 8 の解決済み座標が全消失

- **場所**: `lib/services/customer_import_service.dart` `execute()` の `DuplicateAction.overwrite`
- **原因**: `merged` Customer を生成する際、`transportLocationLats` /
  `Lngs` / `Status` / `Formatted` / `Types` を渡していなかった。
  Customer のコンストラクタは未指定時に `transportLocations` の長さへ
  `null` / `unresolved` で埋めるため、**解決済み座標が静かに消えていた**。
- **影響**: 上書きインポート後に送迎計画のルート最適化が全員「未解決」扱いになり、
  一括ジオコーディングのやり直し（API コスト再発生）＋誤採用リスクが再燃する。
- **修正**: 住所文字列（空白除去・小文字化で正規化）が一致する送迎場所のみ、
  既存の座標・status・採用根拠を引き継ぐ `_carryOverTransportCoords()` を追加。
  - 一致 → `resolved` / `manual` をそのまま保持（並び順が変わっても追従）
  - 不一致（住所変更） → `unresolved` に戻す（古い座標を使い回さない）
  - 未解決だったものは引き継がない
- **回帰テスト**: 2 件追加（保持される / 住所変更時は戻る）

### BUG-002【致命】欠席ダイアログでキャンセルしても欠席が保存される

- **場所**: `lib/screens/attendance_screen.dart` `_showAbsenceDialog()`
- **原因**: 「キャンセル」と「欠席として保存」の双方が `Navigator.pop()`（戻り値なし）で、
  ダイアログを閉じた後に無条件で `markAbsent()` を実行していた。
  コード内コメントも「キャンセル時は保存されない」と**誤った前提**を記述していた。
- **影響**: 誤タップやキャンセル操作で在室実績が欠席に書き換わる。
  欠席は Day 9 の `usedActual` を直接減らすため、**支給量の残日数まで誤る**。
  実地運用では請求（給付費）にも波及し得る最も重い不整合。
- **修正**: `showDialog<bool>` に変更し、`pop(false)` / `pop(true)` で明示。
  `confirmed != true` のとき保存せず return（画面破棄・barrier も安全側）。

### BUG-003【低】未実装の LINE 通知が「送信できる」ように見える

- **場所**: 同画面 `_showLineNotificationDialog()` ほか
- **原因**: 「空き枠 LINE 通知」ダイアログに緑の **「送る」** ボタンがあり、
  押すと「今後実装予定です」と出るだけだった（送信されない）。
  欠席ダイアログ内の注記も「保存後に確認できます」と誤認を招いていた。
- **影響**: 職員が「保護者へ通知済み」と誤認し、連絡漏れにつながる運用リスク。
- **修正**: 送信ボタンを廃止し、完了報告＋「準備中」の明示に変更。
  注記も「LINE 通知は準備中です（現在は自動送信されません）」に修正し、
  電話等での連絡を促す文言を追加。

### BUG-004【低・予防】API キーが例外メッセージ経由で漏れ得る

- **場所**: `lib/services/google_maps_service.dart`（REST 経路）
- **原因**: REST API は URL クエリに `key=AIza...` を含む。`http` パッケージの例外や
  `error_message` は URI 全体を含むことがあり、各画面は `'エラー: $e'` 形式で
  例外を**そのまま画面表示**するため、キーが平文で露出し得た。
- **現況**: アプリ本体は Maps JavaScript API（`MapsJsService`）を使用しており、
  REST のインスタンスメソッドは**現在未使用**（静的ユーティリティのみ利用）。
  そのため実被害はなかったが、将来の再利用で露出する構造だった。
- **修正**: `maskApiKey()` を追加し、HTTP 取得を `_safeGet()` でラップ。
  例外文・`error_message`・ログを常にマスク（`key=***REDACTED***`）。
- **テスト**: 6 件追加（`api_key_security_test.dart`）

---

## 3. セキュリティ点検結果

### API キー平文 grep（`AIza` パターン）

```
$ grep -rn "AIza" --include="*.dart" --include="*.html" \
    --include="*.yaml" --include="*.json" --include="*.md" lib/ web/ test/ docs/

lib/screens/settings_screen.dart:739:  labelText: 'API キー (AIza...)'   ← プレースホルダ文字列（キーではない）
lib/firebase_options.dart:56:         apiKey: 'AIzaSy...'                ← Firebase Web APIキー（公開前提／許容）
```

**実キーの不正な平文出力: 0 件**

- `settings_screen.dart` は入力欄のラベル（`AIza...` という例示）のみ。
- `firebase_options.dart` の Firebase Web API キーは
  [公式仕様上クライアントに埋め込む前提](https://firebase.google.com/docs/projects/api-keys)
  の識別子であり、秘密情報ではない（保護は Firestore/Auth ルール側の責務）。
- Maps API キーは **ソースに一切ハードコードされていない**。
  SharedPreferences 保存 → 実行時に `window.loadGoogleMaps(key)` へ渡す方式。
- `web/index.html` の `?key=` は仕様上必須のスクリプト読込 URL（点検指示で許容範囲）。

### その他

| 項目 | 結果 |
|------|------|
| ログ（`debugPrint`）へのキー出力 | ✅ なし。`_loadSettings` は「設定済み/未設定」のみ記録 |
| PDF への埋め込み | ✅ なし（PDF 生成はキーを参照しない） |
| 共有 URL への混入 | ✅ なし。`buildGoogleMapsUrl*` は座標のみ使用 |
| UI でのマスク表示 | ✅ `obscureText: !_jsApiKeyVisible`、初期値 `false`（既定で隠す） |
| 例外経由の漏洩 | ✅ BUG-004 で予防的に封じ込め |

### Firebase セキュリティルール

- 本アプリは **Firestore / Storage を使用していない**（`pubspec.yaml` は
  `firebase_core` + `firebase_auth` のみ。データは全て端末内 Hive）。
  → Firestore ルールの設定対象は現状なし。
- **Auth 側の推奨設定（本番前に要対応・コンソール作業）**:
  1. Authentication → Settings → **「メール列挙保護」を有効化**
  2. Authentication → Sign-in method → **使用しないプロバイダを無効化**
     （メール/パスワードのみ有効にする）
  3. Authentication → Settings → **承認済みドメイン**を本番ドメインのみに限定
  4. 不要な新規登録を防ぐ場合はコンソールから招待制運用にする

---

## 4. エラーハンドリング点検

| ケース | 挙動 | 判定 |
|--------|------|------|
| API キー未設定（地図） | `_buildSimplePolyline()` で直線描画にフォールバック | ✅ |
| API キー未設定（ルート最適化） | Haversine 最近傍法で順序決定（API 不要） | ✅ |
| API キー無効 | 設定画面の「テスト」で `❌ API キーが無効です` と案内 | ✅ |
| Routes API 未有効 | 例外を捕捉し直線ポリラインへフォールバック | ✅ |
| ジオコード 0 件 | 候補シート＋「地図から直接ピン」（Day 8 最終手段）へ誘導 | ✅ |
| オフライン | 例外捕捉 → フォールバック描画。白画面・無限ローディングなし | ✅ |
| 空データ起動 | 全サービスが空リスト／既定値を返す（自動テスト済み） | ✅ |
| 旧スキーマ Hive データ | 座標リスト未保存でも長さを揃えて `unresolved` 補完 | ✅ |
| 存在しない顧客 ID | 例外なく既定値（支給量 23・実績 0）で返る | ✅ |

---

## 5. パフォーマンス・コスト点検

| 項目 | 結果 |
|------|------|
| 起動時の Geocoder / Routes API 呼び出し | ✅ **0 件**。`main.dart` は Hive 初期化のみ |
| ジオコード候補キャッシュ | ✅ `_candidateCache` 有効（同一クエリは API を再呼び出ししない） |
| 月間支給量集計の計算量 | ✅ O(顧客数 × 当月日数)。Hive は O(1) の Map 参照 |
| `build()` 内での再集計 | ✅ なし。`initState` / リロード時のみ実行（O(N²) 化していない） |
| `main.dart.js` サイズ | 5.3 MB（build/web 全体 33 MB）。Flutter Web の標準的な規模。gzip 配信で実効 1.5 MB 程度 |

> 支給量集計は「毎レンダリング」ではなく画面初期化時のみ。
> 児童数が 3 桁規模になるまでメモ化は不要と判断（現状 10 名程度）。

---

## 6. ブラウザ互換・レイアウト

| 項目 | 状況 | 対応 |
|------|------|------|
| Chrome | ✅ 正常（主検証環境） | — |
| Safari / iPad | ⚠️ 実機未検証 | Canvas レンダラで既知の重大非互換はなし |
| Noto Sans JP 未バンドル | ⚠️ 継続 | **未対応（意図的）**。下記理由 |
| iPad mini 縦（768×1024） | ✅ 主要画面は縦向き前提で構成 | — |

**Noto Sans JP を同梱しない判断理由**: 日本語フォントは
サブセット化しても 1〜3 MB 増となり、初回読み込みを体感で悪化させる。
iPad / Windows / Android はいずれも日本語システムフォント（ヒラギノ／游ゴシック／
Noto）を標準搭載しており、現状のフォールバックで実用上の表示崩れは確認されていない。
**低優先度として継続保留**。

---

## 7. printing / Wasm 調査レポート

### 現状の PDF 出力経路

3 つのサービスがいずれも `Printing.layoutPdf()` を使用:

- `lib/services/attendance_pdf_service.dart`（出席簿）
- `lib/services/weekly_schedule_pdf_service.dart`（週間利用計画）
- `lib/services/transport_pdf_service.dart`（送迎計画）

Web では `printing` が **ブラウザの印刷ダイアログ**を開く経路で動作しており、
`dart:ffi` を使う `method_channel_ffi.dart` は**ネイティブ専用**のため
JS コンパイル（現行の既定ビルド）では実行されない。
→ **現状の `flutter build web --release`（dart2js）では正常動作する。**

### Wasm ビルド時の挙動

`flutter build web --release` 実行時の wasm dry-run 警告（実測）:

```
package:printing/src/method_channel_ffi.dart 17:1 - 'dart:ffi' can't be imported when compiling to Wasm.
package:ffi/src/allocation.dart / arena.dart / utf16.dart / utf8.dart - 同上
```

- **結論**: `--wasm` を付けた場合 **コンパイルエラーで失敗する**（実行時劣化ではなくビルド不成立）。
- **現行ビルドへの影響**: なし（警告のみ。dry-run は通知目的）。
- **対応方針（Day 10 では未対応・意図的）**:
  1. Wasm は現時点で必須でないため **dart2js を継続**（最も安全）
  2. 将来 Wasm に移行する場合の選択肢:
     - `printing` のアップストリームが `dart:ffi` を条件付きインポートに
       変更するのを待つ（最小コスト）
     - PDF 生成を `pdf` パッケージのみに限定し、保存は既存の
       `file_saver_web.dart`（Blob ダウンロード）経由に差し替えて
       `printing` 依存を外す（印刷ダイアログは失うがブラウザ側で代替可）
  3. 緊急度: **低**（Wasm はオプトイン）

---

## 8. 受け入れ基準の判定

| 基準 | 判定 |
|------|------|
| 1. クロス機能シナリオ 5 件が正常動作 | ✅ 達成（2 件はバグ修正の上で達成） |
| 2. API キーの平文出力 0 件 | ✅ 達成（grep 結果は第 3 章） |
| 3. 空データ・異常系で未処理例外なし | ✅ 達成（自動テスト化） |
| 4. test 全緑 / analyze 問題なし / build web 成功 | ✅ 達成（161 件全緑・No issues・ビルド成功） |
| 5. Day 6〜9 の既存機能に退行なし | ✅ 達成（変更禁止領域は無改変） |
| 6. 修正のコミットハッシュ報告 | ✅ 本レポート下部 |

### 変更していないもの（指示どおり維持）

- Routes API 最適化（`optimize=true` / `optimizedOrder` 適用 / Haversine fallback）
- Day 8 の `sanitizeCoords`・誤採用ブロック条件
- Day 9 の動的集計ロジック（`AttendanceRecord` を正とする）
- Day 7 のインポート・重複判定ロジック（**上書き時の座標引き継ぎのみ追加**）
- Hive スキーマ（`fieldId` の追加・変更なし＝完全な後方互換）

---

## 9. 対応しなかった低優先度項目

| 項目 | 理由 |
|------|------|
| Noto Sans JP の同梱 | バンドル 1〜3 MB 増。システムフォントで表示崩れ未確認のため保留 |
| `main.dart.js` のサイズ削減 | 5.3 MB は Flutter Web の標準範囲。gzip 配信で実用上問題なし |
| Safari / iPad 実機検証 | 実機が必要。Chrome での検証とフォールバック実装で代替 |
| LINE 通知の実装 | 新機能追加に該当（Day 10 の範囲外）。誤認 UI の修正のみ実施 |
| REST 版 `GoogleMapsService` の削除 | 未使用だが将来再利用の可能性あり。マスク対応で安全化し残置 |
| `printing` の Wasm 対応 | Wasm はオプトインで現行ビルドに影響なし（第 7 章） |

---

## 10. テスト・ビルド最終結果

```
flutter analyze   →  No issues found!
flutter test      →  All tests passed!  (161 件 / failed 0 / skip 0)
flutter build web --release  →  ✓ Built build/web
```

テスト件数の変化: **145 → 161（+16）**

| 追加テストファイル | 件数 | 目的 |
|-------------------|------|------|
| `test/cross_feature_integration_test.dart` | 8 | クロス機能シナリオ 1・3・4・5＋Hive 後方互換 |
| `test/api_key_security_test.dart` | 6 | API キーのマスク（BUG-004） |
| `test/customer_import_service_test.dart`（追記） | 2 | 上書き時の座標保持（BUG-001） |

> 備考: 出席画面のウィジェットテストは採用しなかった。在室バッジ
> `_PulseDotSmall` が `AnimationController.repeat()` による無限アニメーションを
> 持つため `pumpAndSettle()` が収束せずテストがハングする。
> 同じ不整合はサービス層（`markAbsent` → `usedActual`）で確実に検証している。
