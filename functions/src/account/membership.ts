/**
 * 所属（memberships/{uid}）の確認・作成・削除（ステップ2: 個人アカウント）
 *
 * memberships/{uid} = {
 *   facilityId: string,
 *   kind: 'shared' | 'personal',   // 無ければ shared（ステップ1の共用端末アカウント）
 *   staffId?: string,              // personal のとき
 *   email?: string,                // personal のとき。照合に使った確認済みアドレス（小文字）
 *   createdAt: Timestamp,
 * }
 *
 * 所属を作る・消すのはここ（Admin SDK）だけ。クライアントは firestore.rules で書けない。
 * 判定は firestore.rules の membershipOk と同じ（個人アカウントは、ひも付く職員が
 * 在籍中かつログイン許可のときだけ有効）。
 */
import {logger} from 'firebase-functions/v2';

/** このモジュールが使う Firestore の操作（テストでは FakeFirestore を渡す） */
/* eslint-disable @typescript-eslint/no-explicit-any */
export type Db = any;

export const MEMBERSHIPS = 'memberships';
export const STAFF_ACCOUNTS = 'staffAccounts';

export type MembershipKind = 'shared' | 'personal';

export interface ValidMembership {
  facilityId: string;
  kind: MembershipKind;
  staffId?: string;
}

const staffCol = (facilityId: string) => `facilities/${facilityId}/staff`;

/** 職員の文書が「在籍中かつログイン許可」か */
function staffCanLogin(d: Record<string, unknown> | undefined): boolean {
  return d !== undefined && d.isActive === true && d.loginEnabled === true;
}

/**
 * uid に有効な所属があれば返す（無い・無効なら null）。
 * sendVacancyNotice などの呼び出し型の関数の入口で使う。
 */
export async function getValidMembership(
  db: Db,
  uid: string
): Promise<ValidMembership | null> {
  const snap = await db.collection(MEMBERSHIPS).doc(uid).get();
  if (!snap.exists) return null;
  const m = snap.data() ?? {};
  if (typeof m.facilityId !== 'string' || m.facilityId.length === 0) return null;
  const kind: MembershipKind = m.kind === 'personal' ? 'personal' : 'shared';
  if (kind === 'shared') return {facilityId: m.facilityId, kind};
  if (typeof m.staffId !== 'string' || m.staffId.length === 0) return null;
  const staff = await db.collection(staffCol(m.facilityId)).doc(m.staffId).get();
  if (!staffCanLogin(staff.exists ? staff.data() : undefined)) return null;
  return {facilityId: m.facilityId, kind, staffId: m.staffId};
}

/** 照合に使う形（前後の空白を除き小文字） */
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

/** ログに出すためにメールアドレスを伏せる（先頭 1 文字とドメインだけ） */
export function maskEmail(email: string): string {
  const at = email.indexOf('@');
  if (at <= 0) return '***';
  return `${email[0]}***${email.slice(at)}`;
}

/** 認証トークンのうち、ここで使う項目 */
export interface TokenClaims {
  email?: unknown;
  email_verified?: unknown;
  firebase?: {sign_in_provider?: unknown};
}

export type ClaimResult =
  | {ok: true; facilityId: string; staffId: string}
  | {ok: false; reason: ClaimFailure};

export type ClaimFailure =
  | 'not-google'
  | 'email-not-verified'
  | 'shared-account'
  | 'not-registered'
  | 'duplicate'
  | 'not-allowed';

/**
 * Google でログインした直後に呼ぶ: 確認済みのメールアドレスが、在籍中でログインを
 * 許可された職員のものとして（全事業所でちょうど 1 人）登録されていれば、所属を作る。
 *
 * - 認証トークンの値だけを使う（クライアントから送られた値は使わない）。
 * - 一致しなければ何も作らない。個人アカウントの古い所属があれば消す。
 * - 共用端末アカウント（kind が personal でない所属）は書き換えない。
 */
export async function claimMembership(
  db: Db,
  uid: string,
  token: TokenClaims
): Promise<ClaimResult> {
  if (token.firebase?.sign_in_provider !== 'google.com') {
    return {ok: false, reason: 'not-google'};
  }
  if (token.email_verified !== true || typeof token.email !== 'string') {
    return {ok: false, reason: 'email-not-verified'};
  }
  const ref = db.collection(MEMBERSHIPS).doc(uid);
  const existing = await ref.get();
  const prev = existing.exists ? existing.data() ?? {} : undefined;
  if (prev !== undefined && prev.kind !== 'personal') {
    return {ok: false, reason: 'shared-account'};
  }
  const email = normalizeEmail(token.email);

  const fail = async (reason: ClaimFailure): Promise<ClaimResult> => {
    if (prev !== undefined) await ref.delete();
    logger.info('[claimStaffMembership] 所属を作りませんでした', {
      uid,
      email: maskEmail(email),
      reason,
    });
    return {ok: false, reason};
  };

  const found = await db
    .collectionGroup(STAFF_ACCOUNTS)
    .where('googleEmailLower', '==', email)
    .get();
  if (found.size === 0) return fail('not-registered');
  if (found.size > 1) return fail('duplicate');
  const acc = found.docs[0];
  const staffId: string = acc.id;
  const facilityId: string | undefined = acc.ref?.parent?.parent?.id;
  if (!facilityId) return fail('not-registered');

  const staff = await db.collection(staffCol(facilityId)).doc(staffId).get();
  if (!staffCanLogin(staff.exists ? staff.data() : undefined)) {
    return fail('not-allowed');
  }
  await ref.set({
    facilityId,
    kind: 'personal',
    staffId,
    email,
    createdAt: new Date(),
  });
  logger.info('[claimStaffMembership] 所属を作りました', {
    uid,
    facilityId,
    staffId,
  });
  return {ok: true, facilityId, staffId};
}

/**
 * 職員 staffId の個人アカウントの所属をすべて消す（在籍終了・ログイン停止・
 * メールアドレスの変更のとき）。消した件数を返す。
 */
export async function revokePersonalMemberships(
  db: Db,
  facilityId: string,
  staffId: string
): Promise<number> {
  const snap = await db
    .collection(MEMBERSHIPS)
    .where('facilityId', '==', facilityId)
    .where('staffId', '==', staffId)
    .get();
  let n = 0;
  for (const d of snap.docs) {
    if (d.data().kind !== 'personal') continue;
    await db.collection(MEMBERSHIPS).doc(d.id).delete();
    n++;
  }
  if (n > 0) {
    logger.info('[revokeMemberships] 個人アカウントの所属を消しました', {
      facilityId,
      staffId,
      count: n,
    });
  }
  return n;
}

/** 職員の文書の変化で、個人アカウントの所属を消すべきか */
export function staffChangeRevokes(
  after: Record<string, unknown> | undefined
): boolean {
  return !staffCanLogin(after);
}

/** メールアドレスの文書の変化で、個人アカウントの所属を消すべきか */
export function accountChangeRevokes(
  before: Record<string, unknown> | undefined,
  after: Record<string, unknown> | undefined
): boolean {
  const b = typeof before?.googleEmailLower === 'string' ? before.googleEmailLower : '';
  const a = typeof after?.googleEmailLower === 'string' ? after.googleEmailLower : '';
  return b !== a;
}
