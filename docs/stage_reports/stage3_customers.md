# 段階3（顧客）の報告

作業用ブランチ `feature/firestore-shared-data`。main（`bc3ca0c`）には触れておらず、push もしていない。deploy はしていない。

## 変更したファイル

**保存先の切り替え**
- `lib/services/customer_service.dart`：Hive をやめ、`facilities/{facilityId}/customers` を購読する形にした。
  - 同期の読み取り（`getAllCustomers` など）はそのまま残した。
  - 更新は「前回の内容と違う項目だけ」を書き、違いが無ければ書かない。
  - 記録を変える操作には担当者が要る。自動処理は「自動」と記録する。
  - 在籍終了（`deleteCustomer`）は `isActive` と在籍終了日時だけを書く。
  - 新しく `restoreCustomer`（在籍に戻す）と `getInactiveCustomers` を追加した。
- `lib/models/customer.dart`：`toFirestoreData` と `Customer.fromFirestore` を追加。
  - 送迎場所は、6本の並列リストを1つの配列 `transportLocations: [{address, lat, lng, status, formattedAddress, types[]}]` にまとめた。
  - 日付だけの項目は `"YYYY-MM-DD"` の文字列で持つ。`deactivatedAt` を追加。
- `lib/data/fs_values.dart`（新規）：日付の文字列変換、値の比較、変わった項目の取り出し。
- `lib/data/data_session.dart`：ログイン後に顧客の購読を始め、ログアウトで止める。ログアウトすると、端末に保存した担当者の選択も消す（承認の項目2）。
- `lib/data/staff_session.dart`、`lib/widgets/staff_bar.dart`：担当者を「選んだ日」と一緒に保存し、日付が変わったら未選択に戻す（承認の項目3）。
  - 画面を開いたまま0時をまたいだときは、担当者の帯のタイマーで未選択に戻す。
  - 記録できるかどうかは、日付を見て判定する。
- `lib/main.dart`：顧客の Hive ボックスを開く処理を削除。
- `lib/services/monthly_usage_service.dart`：利用日数の自動補正を「自動」の記録で書くようにした。
  - 補正するかどうかを切り替える引数を `getOverProjected` に追加した。

**画面**
- `lib/screens/inactive_customers_screen.dart`（新規）：在籍終了の顧客の一覧と、「在籍に戻す」（確認画面つき）。
- `lib/screens/customer_management_screen.dart`：
  - アプリバーに「在籍終了の顧客」を追加した。
  - 他の端末の変更が、開き直さずに一覧へ届く。そのときの利用状況の再集計では、補正の書き込みをしない。
- `lib/screens/customer_edit_screen.dart`：
  - 確認画面の「この操作は取り消せません」を、「顧客管理の『在籍終了の顧客』から、いつでも在籍に戻せます」に直した。
  - 在籍終了の顧客には「在籍終了にする」ボタンを出さない。
  - 担当者の選択を閉じた場合は、保存も在籍終了もしない（エラーも出さない）。
- `lib/screens/home_screen.dart`：顧客が変わったら、受給者証の期限警告と超過見込みの件数を、開き直さずに更新する。

**検証環境**
- `tool/verify/seed.mjs`、`tool/verify/dummy_customers.mjs`（新規）：顧客61名（在籍中60名、在籍終了1名）をエミュレータに投入する。無いときだけ作る。`--data empty` を指定すると顧客を投入しない。
  - 中身は `VerifySeed.buildCustomer` と同じ規則・同じ ID で作る。61名すべての中身が一致することを確かめた（違うのは61番の在籍状態だけで、Dart 側でも後から在籍終了にしているため）。
- `lib/verify/verify_seed.dart`：Hive への顧客の投入をやめた。出席などを作るための一覧の組み立てだけを残した。
- `docs/VERIFY_ENV.md`：外部通信の合格条件（承認の項目1）、認められている外部取得の宛先、顧客の投入方法、エミュレータのルールの既知の問題を書いた。
- `tool/import_harness_main.dart`、`tool/resolve_harness_main.dart`、`tool/harness_backend.dart`（新規）：画面確認用のハーネスを、偽の保存先と担当者「ハーネス」で動く形にした。

**テスト**
- 新規：`test/data/customer_service_test.dart`（10件）、`test/data/staff_session_day_test.dart`（5件）、`test/screens/inactive_customers_screen_test.dart`（3件）
- `test/support/fake_backend.dart`：顧客の購読、`resetCustomers`、`reloadCustomers`、保存先の中身を読む補助を追加した。
- 既存テスト11ファイル：Hive の顧客ボックスを使う準備処理だけを差し替えた（下記）。

## テストで確認

- **flutter test**：362件 → **380件**、すべて通過。追加は18件。
- **flutter analyze**：**56件**のまま（info のみ、増えていない）。新しい画面とテストの `material.dart` の読み込みには、これまでと同じ注記を付けた。
- 確かめた内容：
  - Firestore への保存と読み直しで内容が変わらない。送迎場所は1つの配列に、日付は文字列で保存される。
  - 担当者が未選択なら、追加しても何も保存せず、画面にも出さない。選択画面で選べば、そのまま保存して担当者を記録する。
  - 更新は、変えた項目と記録欄だけを書く。他の端末が別の項目を書き換えていても、上書きしない。値が同じなら書かない。
  - 利用日数の自動補正は、担当者なしで「自動」と記録し、その項目だけを書く。
  - 在籍終了しても、送迎場所の座標が残る（範囲外の問題①は、結果として起きなくなった）。在籍に戻すと、在籍終了日時を消す。
  - 他の端末の追加や在籍終了が、開き直さずに届いて変更通知が出る。自分の書き込みの折り返しでは通知しない。
  - 日付が変わると担当者は未選択に戻る。前日の保存も、日付の無い段階2の形式の保存も引き継がない。
  - ログアウトすると担当者の保存が消える。未送信が残ってログアウトを止めたときは消さない。
  - 在籍終了の一覧：本番と同じテーマで描ける。「在籍に戻す」で戻り、キャンセルすると何も変えない。
  - 月間支給量の集計：`monthly_usage_service_test` は、準備処理以外を書き換えずに全件通過した。

## 書き換えたテストとその理由（削除したテストはなし）

| テスト | 変更 | 理由 |
|---|---|---|
| 11ファイルの setUp / setUpAll（cross_feature_integration、customer_import_screen、customer_import_service、monthly_usage_service、attendance_in_room_dot、customer_import_double_run、customer_import_layout、representative_screens、slot_display、transport_location_resolver、vacancy_notification_service） | `CustomerService.init()` を `FakeBackend.attachWithStaff()` に、顧客ボックスの `clear()` を `FakeBackend.resetCustomers()` に、ボックスの件数・中身を `FakeBackend.customerCount` / `allCustomers` に置き換えた | 顧客の保存先が Hive から Firestore（テストでは偽の Firestore）に変わったため。テスト本体と期待値は変えていない |
| `transport_location_resolver_test`「Hive 往復: coords / status」「Hive 往復で formatted / types」 | 「保存先（Firestore）往復」に名前を変え、ボックスの開き直しを購読のやり直し（`reloadCustomers`）に置き換えた | 往復の対象が Hive から Firestore に変わったため。確かめる値は同じ |
| `transport_location_resolver_test` の `seedMixed` | ボックスへ直接書く代わりに、端末内の一覧に直接入れる（`debugSetCache`） | 「保存時のガードを通らない既存の誤データ」を再現する目的は同じ |
| `data_session_test`「この端末で前回選んだ担当者を事業所ごとに復元する」 | 担当者と一緒に「選んだ日」（今日）も保存するようにした | 承認の項目3（日付が変わったら未選択に戻す）。日付の無い保存は引き継がない仕様になったため |

## 検証環境で操作して確認

**方法**
- puppeteer から Windows版の Chrome を操作し、保存領域が分かれた2つのブラウザ環境（A・B）で確かめた。人の手での操作ではない。
- エミュレータのデータは、`seed.mjs --reset` で入れ直した状態から始めた。

**確認した29項目（すべてOK）**
- A・Bとも、顧客一覧が Firestore から表示される。保存先の在籍中は60名。
- A（担当者：職員 春子）が氏名を編集して保存した。
  - 保存先の氏名が変わった。
  - 記録に `職員 春子 / dummy-s001` が残った。
  - 変わった項目は、氏名と記録欄（updatedAt / updatedBy*）だけだった。
- Bの一覧に、開き直さずにAの編集が届いた。
- B（担当者は未選択）が「仮名 梅子」を在籍終了にした。
  - 確認画面に「取り消せません」は無く、在籍に戻せることが書かれている。
  - 在籍終了を押すと、担当者の選択を求められた。選ぶまでは保存されなかった。
  - 「職員 夏男」を選ぶと保存された（isActive=false、在籍終了日時あり、記録者は職員 夏男）。送迎場所と座標は変わらなかった。
  - Bの一覧からも、Aの一覧からも、開き直さずに消えた。
- Aの「在籍終了の顧客」に、「仮名 梅子」と、投入済みの在籍終了者「テスト 一郎」が出た。
  - 「在籍に戻す」を押すと、保存先で isActive=true になり（記録者は職員 春子）、在籍終了の一覧から消えた。
  - Bの一覧に、開き直さずに戻ってきた。
- Aを再読み込みした：担当者、編集した氏名、在籍に戻した顧客がすべて残っていた。
- 自動補正：最初にホーム画面と顧客画面を開いたとき、投入データの利用日数（0）が実績と違う54名について、「自動」の記録で1回書かれた。再読み込みのあとは、どれも書き直さなかった。
- Aをログアウトすると、端末に保存した担当者が消えた。再ログインすると未選択だった。

**通信記録**（CDP。ページ・Service Worker・WebSocket）
- 合計263件。ループバックが123件、認められた静的ファイルの取得が140件（gstatic の描画部品・Firebase SDK・フォント）。
- **資格情報やデータを含む外部通信は0件**（`*.googleapis.com` も0件）。

## 未確認

- 日付が変わったときに、画面を開いたまま未選択に戻ること（ブラウザでは確かめていない。テストでは確認済み）。
- 同じブラウザで複数のタブを開いたとき。スマホ幅での表示。
- Excel一括インポートと送迎場所の位置確認（Maps）を、ブラウザで Firestore 保存に対して操作すること。Maps は検証環境では使えない。サービスのテストは全件通過している。
- 通信が切れた状態での顧客の編集（ブラウザ）。仕組みは段階2の職員と同じ。
- LINE 連携の「連携状況を同期」「連携解除」（検証構成では外部を遮断しているため）。

## 途中で見つけた範囲外の問題・気づいた点

1. **エミュレータのルールが古いまま残っていた**（検証環境。原因は確定していない）。
   - 段階2のコミットの作者を書き直した（rebase）あと、エミュレータは「Rules updated」と表示しながら、main の旧ルール（業務データを全面拒否）のまま判定していた。
   - `touch` しても直らず、エミュレータを起動し直したら直った。
   - `docs/VERIFY_ENV.md` の既知の問題に、見分け方と対処を書いた。アプリ側の問題ではない。
2. **段階3〜5の間の一時的な状態**：利用日数の自動補正は、まだ端末ごとにある Hive の出席から計算している。
   - 出席の記録が違う端末どうしでは、画面を開くたびに相手の補正を「自動」で書き直すことになる。
   - 他の端末の変更が届いたときの再集計では書かないので、書き合いが続くことはない。
   - 段階5で出席を共有すれば解消する。
3. **書き込みの直後に、中間の状態が一瞬表示されることがある**（推測）。続けて書き込むと、途中の状態の通知が先に届く。
   - 偽の保存先ではこれを確認した。本物の Firestore でも起こりうると考えている。
   - 最後の通知で正しい内容に戻る。テストは最後の通知まで待つ形にした。
4. 範囲外の問題①（在籍終了で座標が消える）は、在籍終了を項目だけの更新にしたことで、結果として起きなくなった。`resetMonthlyUsedDays` も項目だけの更新にした（どこからも呼ばれていないのは変わらない）。

## 判断が必要な点

- なし（承認済みの設計と、承認の項目1〜3の範囲で進めた）。
