/**
 * slots — 空き枠の先着確定ロジック（Day 13）
 *
 * 【このモジュールが守るべき不変条件】
 * 1. **1 つの枠を確定できるのは 1 名だけ**。同時タップでも二重確定しない。
 *    → Firestore transaction 内で status を読み、'open' のときだけ書き込む。
 *      transaction は競合時に自動リトライされ、後勝ちは起こらない。
 * 2. **同じ webhook イベントを二度処理しない**。
 *    → webhook_processed/{webhookEventId} を create（既存なら失敗）で予約する。
 *      LINE は再送することがあり（deliveryContext.isRedelivery）、
 *      これが無いと「自分で取った枠を自分でキャンセル扱い」になりうる。
 * 3. **通知を受け取っていない人は応募できない**。
 *    → notifiedList に自分の customerId が無ければ拒否する。
 *      postback data は改ざん可能なため、応募者の身元は
 *      webhook の source.userId（LINE 署名で保護済み）から引く。
 * 4. **期限切れの枠は確定しない**。→ expiresAt を transaction 内で判定する。
 *
 * 仕様参照:
 *  - Webhook 再送: https://developers.line.biz/en/docs/messaging-api/receiving-messages/
 */
import * as logger from 'firebase-functions/logger';
import type {Firestore, Transaction} from 'firebase-admin/firestore';

import {COLLECTIONS, SLOT_TTL_HOURS, WEBHOOK_PROCESSED_TTL_HOURS} from './config';
import {maskUserId} from './line/client';

/** 枠の状態 */
export type SlotStatus = 'open' | 'filled' | 'released' | 'expired';

/** 通知済みの 1 件 */
export interface NotifiedEntry {
  customerId: string;
  /** LINE userId はそのまま保存せずハッシュで持つ（漏洩時の被害軽減） */
  lineUserIdHash: string;
  servedAt: Date;
}

/** 確定者 */
export interface ClaimedBy {
  customerId: string;
  lineUserIdHash: string;
  claimedAt: Date;
}

/** 枠ドキュメント */
export interface SlotDoc {
  status: SlotStatus;
  scheduledAt: Date;
  opensAt: Date;
  expiresAt: Date;
  capacity: number;
  claimedBy: ClaimedBy | null;
  notifiedList: NotifiedEntry[];
  sourceAbsent: string;
  createdBy: 'vacancy_notice' | 'manual_phone';
  dateKey: string;
  /** 通知に同梱する確認コード（本人性の簡易裏付け） */
  linkCode: string;
}

/** claim / release の結果 */
export type ClaimOutcome =
  | 'claimed' // 確定した（勝者）
  | 'already_filled' // 他の人が先に確定済み（敗者）
  | 'already_claimed_by_self' // 自分が既に確定済み（再タップ）
  | 'not_notified' // 通知対象外
  | 'expired' // 期限切れ
  | 'slot_not_found' // 枠が無い
  | 'released' // キャンセル成立
  | 'release_denied' // 自分の確定ではないのでキャンセル不可
  | 'invalid_code'; // 確認コード不一致

export interface ClaimResult {
  outcome: ClaimOutcome;
  slotId: string;
  /** 確定者の customerId（確定時のみ） */
  claimedCustomerId: string | null;
  /** 枠を取り逃した他の通知先（敗者通知に使う。claim 成功時のみ） */
  losers: NotifiedEntry[];
}

/**
 * LINE userId をハッシュ化する。
 *
 * 生の userId を複数コレクションに散らさないための措置。
 * ソルトにはチャネルシークレットを使う（Secret Manager 管理・外部に出ない）。
 */
export function hashLineUserId(lineUserId: string, salt: string): string {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const crypto = require('crypto') as typeof import('crypto');
  return crypto
    .createHmac('sha256', salt)
    .update(lineUserId)
    .digest('hex')
    .slice(0, 32);
}

/** 枠 ID を組み立てる */
export function makeSlotId(dateKey: string, absentCustomerId: string): string {
  return `${dateKey}_${absentCustomerId}`;
}

/**
 * webhook イベントの冪等予約。
 *
 * @returns 初回なら true、既に処理済みなら false
 */
export async function reserveWebhookEvent(
  db: Firestore,
  webhookEventId: string,
  action: string
): Promise<boolean> {
  if (!webhookEventId) {
    // webhookEventId が無いイベントは重複検知できない。
    // 握り潰すと正当な応募を落とすため、処理は続行する。
    logger.warn('[slots] webhookEventId missing; duplicate check skipped');
    return true;
  }
  const ref = db.collection(COLLECTIONS.webhookProcessed).doc(webhookEventId);
  try {
    await ref.create({
      processedAt: new Date(),
      ttl: new Date(Date.now() + WEBHOOK_PROCESSED_TTL_HOURS * 3600 * 1000),
      action,
    });
    return true;
  } catch {
    logger.info('[slots] duplicate webhook ignored', {webhookEventId});
    return false;
  }
}

/** 監査ログを 1 件書く（失敗してもメイン処理は止めない） */
export async function writeAudit(
  db: Firestore,
  slotId: string,
  entry: {
    actor: string;
    action: string;
    before: string | null;
    after: string | null;
    sourceIp?: string | null;
  }
): Promise<void> {
  try {
    const seq = Date.now();
    await db
      .collection(COLLECTIONS.slotAudit)
      .doc(`${slotId}_${seq}`)
      .set({
        slotId,
        actor: entry.actor,
        action: entry.action,
        before: entry.before,
        after: entry.after,
        at: new Date(),
        sourceIp: entry.sourceIp ?? null,
      });
  } catch (e) {
    logger.warn('[slots] audit write failed', {
      slotId,
      error: e instanceof Error ? e.message : String(e),
    });
  }
}

function toDate(v: unknown): Date | null {
  if (!v) return null;
  if (v instanceof Date) return v;
  if (typeof v === 'object' && v !== null && 'toDate' in v) {
    const f = (v as {toDate: () => Date}).toDate;
    if (typeof f === 'function') return f.call(v);
  }
  if (typeof v === 'string') {
    const d = new Date(v);
    return isNaN(d.getTime()) ? null : d;
  }
  return null;
}

function readNotifiedList(v: unknown): NotifiedEntry[] {
  if (!Array.isArray(v)) return [];
  const out: NotifiedEntry[] = [];
  for (const x of v) {
    if (x === null || typeof x !== 'object') continue;
    const o = x as Record<string, unknown>;
    const customerId = typeof o.customerId === 'string' ? o.customerId : '';
    const lineUserIdHash =
      typeof o.lineUserIdHash === 'string' ? o.lineUserIdHash : '';
    if (customerId.length === 0) continue;
    out.push({
      customerId,
      lineUserIdHash,
      servedAt: toDate(o.servedAt) ?? new Date(0),
    });
  }
  return out;
}

/**
 * 空き枠を作成する（通知送信時に呼ぶ）。
 *
 * 既に同じ枠があれば作り直さない（通知の再送で確定済みの枠を壊さないため）。
 *
 * @returns 作成したら true、既存なら false
 */
export async function createSlotIfAbsent(
  db: Firestore,
  params: {
    slotId: string;
    dateKey: string;
    sourceAbsent: string;
    linkCode: string;
    notifiedList: NotifiedEntry[];
    createdBy: 'vacancy_notice' | 'manual_phone';
    now?: Date;
  }
): Promise<boolean> {
  const now = params.now ?? new Date();
  const ref = db.collection(COLLECTIONS.slots).doc(params.slotId);
  const doc: Record<string, unknown> = {
    status: 'open',
    scheduledAt: now,
    opensAt: now,
    expiresAt: new Date(now.getTime() + SLOT_TTL_HOURS * 3600 * 1000),
    capacity: 1,
    claimedBy: null,
    notifiedList: params.notifiedList.map((n) => ({
      customerId: n.customerId,
      lineUserIdHash: n.lineUserIdHash,
      servedAt: n.servedAt,
    })),
    sourceAbsent: params.sourceAbsent,
    createdBy: params.createdBy,
    dateKey: params.dateKey,
    linkCode: params.linkCode,
  };
  try {
    await ref.create(doc);
    return true;
  } catch {
    // 既存（同じ日の再通知）。確定済みかもしれないので上書きしない。
    return false;
  }
}

/**
 * 通知先を既存の枠に追加する（追加送信した場合）。
 * transaction で notifiedList に追記する。確定済みでも追記はしてよい。
 */
export async function appendNotified(
  db: Firestore,
  slotId: string,
  entry: NotifiedEntry
): Promise<void> {
  const ref = db.collection(COLLECTIONS.slots).doc(slotId);
  await db.runTransaction(async (tx: Transaction) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return;
    const data = snap.data() as Record<string, unknown>;
    const list = readNotifiedList(data.notifiedList);
    if (list.some((n) => n.customerId === entry.customerId)) return;
    list.push(entry);
    tx.update(ref, {notifiedList: list});
  });
}

/**
 * 先着で枠を確定する（本体）。
 *
 * **transaction 内では Firestore の読み書きのみを行う**。
 * LINE への送信（reply / push）は呼び出し側が transaction の外で行う。
 * transaction は競合時に再実行されるため、中で送信すると二重送信になる。
 */
export async function claimSlot(
  db: Firestore,
  params: {
    slotId: string;
    customerId: string;
    lineUserIdHash: string;
    linkCode: string;
    now?: Date;
  }
): Promise<ClaimResult> {
  const now = params.now ?? new Date();
  const ref = db.collection(COLLECTIONS.slots).doc(params.slotId);

  return db.runTransaction(async (tx: Transaction): Promise<ClaimResult> => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      return {
        outcome: 'slot_not_found',
        slotId: params.slotId,
        claimedCustomerId: null,
        losers: [],
      };
    }
    const data = snap.data() as Record<string, unknown>;

    // 確認コードの一致（通知を受け取った本人かの簡易裏付け）
    const expectedCode =
      typeof data.linkCode === 'string' ? data.linkCode : '';
    if (expectedCode.length > 0 && expectedCode !== params.linkCode) {
      return {
        outcome: 'invalid_code',
        slotId: params.slotId,
        claimedCustomerId: null,
        losers: [],
      };
    }

    const notified = readNotifiedList(data.notifiedList);
    const isNotified = notified.some(
      (n) => n.customerId === params.customerId
    );
    if (!isNotified) {
      return {
        outcome: 'not_notified',
        slotId: params.slotId,
        claimedCustomerId: null,
        losers: [],
      };
    }

    const status = typeof data.status === 'string' ? data.status : 'open';
    const claimed = data.claimedBy as Record<string, unknown> | null;

    // 自分が既に確定済み（再タップ・webhook 再送）
    if (
      status === 'filled' &&
      claimed !== null &&
      claimed.customerId === params.customerId
    ) {
      return {
        outcome: 'already_claimed_by_self',
        slotId: params.slotId,
        claimedCustomerId: params.customerId,
        losers: [],
      };
    }

    if (status === 'filled') {
      return {
        outcome: 'already_filled',
        slotId: params.slotId,
        claimedCustomerId:
          claimed && typeof claimed.customerId === 'string'
            ? claimed.customerId
            : null,
        losers: [],
      };
    }

    // 期限切れ（status を書き換えず、読み出し時に判定する）
    const expiresAt = toDate(data.expiresAt);
    if (expiresAt !== null && expiresAt.getTime() <= now.getTime()) {
      return {
        outcome: 'expired',
        slotId: params.slotId,
        claimedCustomerId: null,
        losers: [],
      };
    }

    if (status === 'released') {
      // 一度キャンセルされた枠は再度 open として扱い、確定を許す。
      // （キャンセル後に別の保護者が取れないと枠が死ぬ）
      logger.info('[slots] claiming a released slot', {slotId: params.slotId});
    }

    // ── ここまで来たら確定できる
    const claimedBy: ClaimedBy = {
      customerId: params.customerId,
      lineUserIdHash: params.lineUserIdHash,
      claimedAt: now,
    };
    tx.update(ref, {status: 'filled', claimedBy});

    const losers = notified.filter((n) => n.customerId !== params.customerId);

    return {
      outcome: 'claimed',
      slotId: params.slotId,
      claimedCustomerId: params.customerId,
      losers,
    };
  });
}

/**
 * 確定した枠を取り消す。
 *
 * 取り消せるのは**自分が確定した枠だけ**。
 * 他人の確定を奪えないよう、customerId の一致を transaction 内で確認する。
 */
export async function releaseSlot(
  db: Firestore,
  params: {
    slotId: string;
    customerId: string;
    now?: Date;
  }
): Promise<ClaimResult> {
  const now = params.now ?? new Date();
  const ref = db.collection(COLLECTIONS.slots).doc(params.slotId);

  return db.runTransaction(async (tx: Transaction): Promise<ClaimResult> => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      return {
        outcome: 'slot_not_found',
        slotId: params.slotId,
        claimedCustomerId: null,
        losers: [],
      };
    }
    const data = snap.data() as Record<string, unknown>;
    const claimed = data.claimedBy as Record<string, unknown> | null;

    if (
      data.status !== 'filled' ||
      claimed === null ||
      claimed.customerId !== params.customerId
    ) {
      return {
        outcome: 'release_denied',
        slotId: params.slotId,
        claimedCustomerId:
          claimed && typeof claimed.customerId === 'string'
            ? claimed.customerId
            : null,
        losers: [],
      };
    }

    tx.update(ref, {
      status: 'released',
      claimedBy: null,
      releasedAt: now,
      releasedBy: params.customerId,
    });

    return {
      outcome: 'released',
      slotId: params.slotId,
      claimedCustomerId: params.customerId,
      losers: [],
    };
  });
}

/** LINE userId から連携済み customerId を引く */
export async function resolveCustomerIdByLineUserId(
  db: Firestore,
  lineUserId: string
): Promise<string | null> {
  if (!lineUserId) return null;
  const snap = await db
    .collection(COLLECTIONS.lineLinkage)
    .where('lineUserId', '==', lineUserId)
    .limit(1)
    .get();
  if (snap.empty) {
    logger.info('[slots] no linkage for user', {
      lineUserId: maskUserId(lineUserId),
    });
    return null;
  }
  const d = snap.docs[0].data() as Record<string, unknown>;
  return typeof d.customerId === 'string' ? d.customerId : snap.docs[0].id;
}
