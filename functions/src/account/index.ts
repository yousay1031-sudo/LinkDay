/**
 * 個人アカウント（職員の Google アカウント）の所属を付ける・外す関数（ステップ2）
 *
 * LINE 関連の関数（sendVacancyNotice / lineWebhook）とは別のファイルに置く。
 * 秘密情報（LINE のトークンなど）は使わない。
 *
 *  - claimStaffMembership（呼び出し型）: Google でログインした直後にアプリが呼ぶ。
 *  - onStaffAccessChanged（Firestore のトリガー）: 職員が在籍終了・ログイン停止に
 *    なったら、その職員の個人アカウントの所属を消す。
 *  - onStaffAccountChanged（Firestore のトリガー）: メールアドレスが変わった・
 *    消えたら、その職員の個人アカウントの所属を消す。
 *
 * ルール（firestore.rules）は所属を毎回確かめ、さらに個人アカウントは職員が
 * 在籍中かつログイン許可のときだけ有効とするので、在籍終了・停止はトリガーを
 * 待たずにその時点から読み書きが止まる。トリガーは所属の文書の後片付けと、
 * メールアドレスの変更（ルールでは見ない）を受け持つ。
 */
import {initializeApp, getApps} from 'firebase-admin/app';
import {getFirestore} from 'firebase-admin/firestore';
import {HttpsError, onCall} from 'firebase-functions/v2/https';
import {onDocumentWritten} from 'firebase-functions/v2/firestore';

import {
  accountChangeRevokes,
  claimMembership,
  revokePersonalMemberships,
  staffChangeRevokes,
  type TokenClaims,
} from './membership';

/**
 * 東京（config.ts の REGION と同じ値）。config.ts は LINE の秘密情報を宣言するため
 * 読み込まない（検証環境でこのファイルだけを動かすとき、秘密情報を求められないように）。
 */
const REGION = 'asia-northeast1';

if (getApps().length === 0) {
  initializeApp();
}

/** Google でログインした直後に呼ぶ（所属を作る。作れなければ ok:false だけを返す） */
export const claimStaffMembership = onCall(
  {region: REGION, cors: true, timeoutSeconds: 30, memory: '256MiB'},
  async (req): Promise<{ok: boolean}> => {
    if (!req.auth || !req.auth.uid) {
      throw new HttpsError('unauthenticated', 'ログインが必要です。');
    }
    const r = await claimMembership(
      getFirestore(),
      req.auth.uid,
      req.auth.token as TokenClaims
    );
    // 理由は返さない（登録の有無を外から探れないように。理由はログにだけ残す）
    return {ok: r.ok};
  }
);

/** 職員が在籍終了・ログイン停止になったら、個人アカウントの所属を消す */
export const onStaffAccessChanged = onDocumentWritten(
  {document: 'facilities/{facilityId}/staff/{staffId}', region: REGION},
  async (event) => {
    const after = event.data?.after?.exists ? event.data.after.data() : undefined;
    if (!staffChangeRevokes(after)) return;
    await revokePersonalMemberships(
      getFirestore(),
      event.params.facilityId,
      event.params.staffId
    );
  }
);

/** メールアドレスが変わった・消えたら、個人アカウントの所属を消す */
export const onStaffAccountChanged = onDocumentWritten(
  {document: 'facilities/{facilityId}/staffAccounts/{staffId}', region: REGION},
  async (event) => {
    const before = event.data?.before?.exists ? event.data.before.data() : undefined;
    const after = event.data?.after?.exists ? event.data.after.data() : undefined;
    if (!accountChangeRevokes(before, after)) return;
    await revokePersonalMemberships(
      getFirestore(),
      event.params.facilityId,
      event.params.staffId
    );
  }
);
