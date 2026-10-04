/**
 * slotPostback — postback イベント（応募／キャンセル）の処理（Day 13）
 *
 * lineWebhook から呼ばれる。既存の message / follow 分岐には手を入れない。
 *
 * 【処理順序（厳守）】
 *  a. 署名検証        … lineWebhook 側で実施済み
 *  b. 冪等予約        … webhook_processed/{webhookEventId} を create
 *  c. data パース     … 改ざん前提。slotId と linkCode のみ信用する
 *  d. 本人解決        … source.userId（署名で保護済み）から customerId を引く
 *  e. transaction     … 先着確定。Firestore の読み書きのみ
 *  f. LINE 送信       … transaction の外。勝者 reply / 敗者 push
 *
 * e と f を分けるのが要点。transaction は競合時に再実行されるため、
 * 中で送信すると同じ人に何通も届く。
 */
import * as logger from 'firebase-functions/logger';
import type {Firestore} from 'firebase-admin/firestore';

import {lineApi, maskUserId} from './line/client';
import {
  buildClaimedFlexMessage,
  formatDateJa,
  parsePostbackData,
} from './slotMessage';
import {
  claimSlot,
  hashLineUserId,
  releaseSlot,
  reserveWebhookEvent,
  resolveCustomerIdByLineUserId,
  writeAudit,
  type ClaimResult,
} from './slots';

export const MSG_CLAIM_WON =
  'お申し込みを受け付けました。ご利用が確定しました。';
export const MSG_CLAIM_LOST =
  '申し訳ありません。この枠は他の方のお申し込みで埋まりました。\n' +
  'またの機会にご利用ください。';
export const MSG_CLAIM_ALREADY_SELF =
  'このお申し込みは既に受け付け済みです。ご利用が確定しています。';
export const MSG_CLAIM_EXPIRED =
  '申し訳ありません。この空き枠は受付時間を過ぎました。\n' +
  'お急ぎの場合は施設へお電話ください。';
export const MSG_CLAIM_NOT_NOTIFIED =
  'この空き枠のご案内は、お客様宛てではないようです。\n' +
  'お心当たりがない場合は施設へご連絡ください。';
export const MSG_CLAIM_NO_LINKAGE =
  'LINE連携が確認できませんでした。\n' +
  '施設からお渡しした「連携コード（6桁）」をこのトークに送信してください。';
export const MSG_SLOT_NOT_FOUND =
  'この空き枠の情報が見つかりませんでした。施設へご連絡ください。';
export const MSG_RELEASED =
  'お申し込みを取り消しました。またのご利用をお待ちしております。';
export const MSG_RELEASE_DENIED =
  'この枠のお申し込みは確認できませんでした。施設へご連絡ください。';
export const MSG_INVALID = 'お申し込みを受け付けられませんでした。施設へご連絡ください。';

/** 敗者へ送る「埋まりました」通知（push） */
export function buildFilledNoticeText(dateKey: string): string {
  return (
    `【${formatDateJa(dateKey)}の空き枠】\n` +
    'この枠は他の方のお申し込みで埋まりました。\n' +
    'お知らせを重ねてしまい申し訳ありません。'
  );
}

/** postback 1 件の処理結果（テスト検証用） */
export interface PostbackResult {
  handled: boolean;
  outcome: string;
  reply: string | null;
  /** 敗者へ push した件数 */
  losersNotified: number;
}

interface PostbackEventLike {
  type?: string;
  replyToken?: string;
  webhookEventId?: string;
  source?: {userId?: string};
  postback?: {data?: string};
  deliveryContext?: {isRedelivery?: boolean};
}

/**
 * postback イベントを処理する。
 *
 * @param channelSecret LINE userId のハッシュ用ソルト（外部に出ない値）
 */
export async function handleSlotPostback(
  db: Firestore,
  accessToken: string,
  ev: PostbackEventLike,
  channelSecret: string
): Promise<PostbackResult> {
  const api = lineApi();
  const replyToken = ev.replyToken ?? '';
  const lineUserId = ev.source?.userId ?? '';
  const webhookEventId = ev.webhookEventId ?? '';

  const reply = async (text: string): Promise<void> => {
    if (replyToken) await api.replyText(accessToken, replyToken, text);
  };

  // ── b. 冪等予約（LINE の再送で二重処理しない）
  const first = await reserveWebhookEvent(db, webhookEventId, 'postback');
  if (!first) {
    logger.info('[slotPostback] duplicate event skipped', {webhookEventId});
    return {
      handled: true,
      outcome: 'duplicate_webhook',
      reply: null,
      losersNotified: 0,
    };
  }

  // ── c. data パース（改ざん前提で最小限のみ信用）
  const parsed = parsePostbackData(ev.postback?.data);
  if (parsed === null) {
    logger.warn('[slotPostback] invalid postback data');
    await reply(MSG_INVALID);
    return {
      handled: true,
      outcome: 'invalid_data',
      reply: MSG_INVALID,
      losersNotified: 0,
    };
  }

  // ── d. 本人解決（postback data ではなく署名済みの source.userId を使う）
  const customerId = await resolveCustomerIdByLineUserId(db, lineUserId);
  if (customerId === null) {
    await reply(MSG_CLAIM_NO_LINKAGE);
    return {
      handled: true,
      outcome: 'no_linkage',
      reply: MSG_CLAIM_NO_LINKAGE,
      losersNotified: 0,
    };
  }

  const lineUserIdHash = hashLineUserId(lineUserId, channelSecret);
  const dateKey = parsed.slotId.split('_')[0] ?? '';

  // ── e. transaction（Firestore のみ）
  let result: ClaimResult;
  if (parsed.action === 'release') {
    result = await releaseSlot(db, {
      slotId: parsed.slotId,
      customerId,
    });
  } else {
    result = await claimSlot(db, {
      slotId: parsed.slotId,
      customerId,
      lineUserIdHash,
      linkCode: parsed.linkCode,
    });
  }

  await writeAudit(db, parsed.slotId, {
    actor: `line:${lineUserIdHash.slice(0, 8)}`,
    action: parsed.action,
    before: null,
    after: result.outcome,
  });

  logger.info('[slotPostback] result', {
    slotId: parsed.slotId,
    action: parsed.action,
    outcome: result.outcome,
    customerId,
    lineUserId: maskUserId(lineUserId),
  });

  // ── f. LINE 送信（transaction の外）
  let replyText: string;
  let losersNotified = 0;

  switch (result.outcome) {
    case 'claimed': {
      replyText = MSG_CLAIM_WON;
      await reply(replyText);
      // 確定者にはキャンセル用ボタンを別途 push する
      try {
        await api.pushMessage(
          accessToken,
          lineUserId,
          buildClaimedFlexMessage({
            dateKey,
            slotId: parsed.slotId,
            linkCode: parsed.linkCode,
          })
        );
      } catch (e) {
        logger.warn('[slotPostback] claimed flex push failed', {
          error: e instanceof Error ? e.message : String(e),
        });
      }
      // 敗者へ「埋まりました」を push（reply は勝者に使ってしまうため push）
      losersNotified = await notifyLosers(
        db,
        accessToken,
        result,
        dateKey,
        channelSecret
      );
      break;
    }
    case 'already_claimed_by_self':
      replyText = MSG_CLAIM_ALREADY_SELF;
      await reply(replyText);
      break;
    case 'already_filled':
      replyText = MSG_CLAIM_LOST;
      await reply(replyText);
      break;
    case 'expired':
      replyText = MSG_CLAIM_EXPIRED;
      await reply(replyText);
      break;
    case 'not_notified':
      replyText = MSG_CLAIM_NOT_NOTIFIED;
      await reply(replyText);
      break;
    case 'slot_not_found':
      replyText = MSG_SLOT_NOT_FOUND;
      await reply(replyText);
      break;
    case 'released':
      replyText = MSG_RELEASED;
      await reply(replyText);
      break;
    case 'release_denied':
      replyText = MSG_RELEASE_DENIED;
      await reply(replyText);
      break;
    case 'invalid_code':
    default:
      replyText = MSG_INVALID;
      await reply(replyText);
      break;
  }

  return {
    handled: true,
    outcome: result.outcome,
    reply: replyText,
    losersNotified,
  };
}

/**
 * 敗者（枠を取り逃した通知先）へ「埋まりました」を push する。
 *
 * line_linkage から lineUserId を引き直す（slots には生の userId を持たない）。
 * 1 件でも失敗したら残りは続行する（全滅させない）。
 */
async function notifyLosers(
  db: Firestore,
  accessToken: string,
  result: ClaimResult,
  dateKey: string,
  channelSecret: string
): Promise<number> {
  if (result.losers.length === 0) return 0;
  const api = lineApi();
  const text = buildFilledNoticeText(dateKey);
  let count = 0;

  for (const loser of result.losers) {
    try {
      const snap = await db
        .collection('line_linkage')
        .doc(loser.customerId)
        .get();
      if (!snap.exists) continue;
      const d = snap.data() as Record<string, unknown>;
      const uid = typeof d.lineUserId === 'string' ? d.lineUserId : '';
      if (uid.length === 0) continue;

      // 念のためハッシュ一致を確認（別人へ送らない）
      if (
        loser.lineUserIdHash.length > 0 &&
        hashLineUserId(uid, channelSecret) !== loser.lineUserIdHash
      ) {
        logger.warn('[slotPostback] loser hash mismatch; skip', {
          customerId: loser.customerId,
        });
        continue;
      }

      const r = await api.pushText(accessToken, uid, text);
      if (r.ok) count++;
    } catch (e) {
      logger.warn('[slotPostback] loser notify failed', {
        customerId: loser.customerId,
        error: e instanceof Error ? e.message : String(e),
      });
    }
  }
  logger.info('[slotPostback] losers notified', {
    total: result.losers.length,
    sent: count,
  });
  return count;
}
