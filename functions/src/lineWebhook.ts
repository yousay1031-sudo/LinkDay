/**
 * lineWebhook — LINE プラットフォームからの webhook 受信（HTTPS Function）
 *
 * 対応イベント:
 *  - follow  : 友だち追加 → 「連携コードを送信してください」と reply
 *  - message : テキストが 6 桁英数の連携コードと一致すれば line_linkage へ保存
 *              → 「連携が完了しました」と reply。不一致は「コードが違います」
 *  - unfollow: ブロック（reply 不可）→ ログのみ
 *
 * 【セキュリティ】
 * x-line-signature の HMAC-SHA256 検証を必須にする。
 * 検証に失敗したリクエストは 403 を返し、一切処理しない。
 */
import * as logger from 'firebase-functions/logger';
import type {Request} from 'firebase-functions/v2/https';
import type {Firestore} from 'firebase-admin/firestore';

import {COLLECTIONS} from './config';
import {lineApi, maskUserId} from './line/client';
import {verifyLineSignature} from './line/signature';

/**
 * HTTP レスポンスの最小インターフェース
 *
 * express.Response を直接使わずこの形に絞ることで、
 * テスト側がフェイクを渡せる（実サーバを立てずに検証できる）。
 */
export interface HttpResponseLike {
  status(code: number): HttpResponseLike;
  send(body: unknown): unknown;
}

/** 連携コード: 6 桁英数（大文字・数字） */
export const LINKING_CODE_RE = /^[0-9A-Z]{6}$/;

export const MSG_FOLLOW =
  'LinkDay の連携へようこそ。\n' +
  '施設からお渡しした「連携コード（6桁）」をこのトークに送信してください。\n' +
  '連携が完了すると、空き枠のお知らせをこちらにお送りします。';

export const MSG_LINKED = '連携が完了しました。空き枠のお知らせをこのトークにお送りします。';
export const MSG_WRONG_CODE =
  'コードが違います。\n施設からお渡しした6桁の連携コード（数字と大文字英字）をご確認のうえ、もう一度送信してください。';
export const MSG_EXPIRED =
  'この連携コードは有効期限が切れています。お手数ですが施設に新しいコードの発行をご依頼ください。';
export const MSG_NOT_A_CODE =
  '連携コード（6桁）を送信してください。\nご用件のある方は施設へお電話ください。';

/** 正規化: 全角→半角・小文字→大文字・空白除去 */
export function normalizeCode(text: string): string {
  return text
    .trim()
    .replace(/[\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A]/g, (c) =>
      String.fromCharCode(c.charCodeAt(0) - 0xfee0)
    )
    .replace(/[\s\u3000-]/g, '')
    .toUpperCase();
}

/** webhook 1 イベント分の処理結果（テスト検証用） */
export interface WebhookEventResult {
  type: string;
  handled: boolean;
  /** reply したメッセージ（reply していなければ null） */
  reply: string | null;
  /** 連携成功した customerId（それ以外は null） */
  linkedCustomerId: string | null;
}

interface LineEvent {
  type?: string;
  replyToken?: string;
  source?: {userId?: string; type?: string};
  message?: {type?: string; text?: string};
}

/**
 * webhook 本体ロジック（署名検証後に呼ばれる）
 */
export async function processWebhookEvents(
  db: Firestore,
  accessToken: string,
  events: LineEvent[]
): Promise<WebhookEventResult[]> {
  const api = lineApi();
  const out: WebhookEventResult[] = [];

  for (const ev of events) {
    const lineUserId = ev.source?.userId ?? '';
    const replyToken = ev.replyToken ?? '';

    if (ev.type === 'follow') {
      if (replyToken) await api.replyText(accessToken, replyToken, MSG_FOLLOW);
      logger.info('[lineWebhook] follow', {
        lineUserId: maskUserId(lineUserId),
      });
      out.push({
        type: 'follow',
        handled: true,
        reply: MSG_FOLLOW,
        linkedCustomerId: null,
      });
      continue;
    }

    if (ev.type === 'unfollow') {
      logger.info('[lineWebhook] unfollow', {
        lineUserId: maskUserId(lineUserId),
      });
      out.push({
        type: 'unfollow',
        handled: true,
        reply: null,
        linkedCustomerId: null,
      });
      continue;
    }

    if (ev.type === 'message' && ev.message?.type === 'text') {
      const raw = ev.message.text ?? '';
      const code = normalizeCode(raw);

      // コード書式でない → 案内のみ（Firestore は引かない）
      if (!LINKING_CODE_RE.test(code)) {
        if (replyToken) {
          await api.replyText(accessToken, replyToken, MSG_NOT_A_CODE);
        }
        out.push({
          type: 'message',
          handled: true,
          reply: MSG_NOT_A_CODE,
          linkedCustomerId: null,
        });
        continue;
      }

      const snap = await db
        .collection(COLLECTIONS.linkingCodes)
        .doc(code)
        .get();

      if (!snap.exists) {
        if (replyToken) {
          await api.replyText(accessToken, replyToken, MSG_WRONG_CODE);
        }
        logger.info('[lineWebhook] code not found', {
          lineUserId: maskUserId(lineUserId),
        });
        out.push({
          type: 'message',
          handled: true,
          reply: MSG_WRONG_CODE,
          linkedCustomerId: null,
        });
        continue;
      }

      const data = snap.data() as Record<string, unknown>;
      const expiresAt = toDate(data.expiresAt);
      if (expiresAt && expiresAt.getTime() < Date.now()) {
        if (replyToken) {
          await api.replyText(accessToken, replyToken, MSG_EXPIRED);
        }
        logger.info('[lineWebhook] code expired', {code});
        out.push({
          type: 'message',
          handled: true,
          reply: MSG_EXPIRED,
          linkedCustomerId: null,
        });
        continue;
      }

      const customerId =
        typeof data.customerId === 'string' ? data.customerId : '';
      if (customerId.length === 0 || lineUserId.length === 0) {
        if (replyToken) {
          await api.replyText(accessToken, replyToken, MSG_WRONG_CODE);
        }
        out.push({
          type: 'message',
          handled: true,
          reply: MSG_WRONG_CODE,
          linkedCustomerId: null,
        });
        continue;
      }

      // 連携保存（customerId を doc id にし、1児童1連携を保証）
      await db.collection(COLLECTIONS.lineLinkage).doc(customerId).set({
        customerId,
        lineUserId,
        linkedAt: new Date(),
        linkedBy: 'line_webhook',
      });
      // 使用済みコードは削除（使い回し防止）
      await db.collection(COLLECTIONS.linkingCodes).doc(code).delete();

      if (replyToken) {
        await api.replyText(accessToken, replyToken, MSG_LINKED);
      }
      logger.info('[lineWebhook] linked', {
        customerId,
        lineUserId: maskUserId(lineUserId),
      });
      out.push({
        type: 'message',
        handled: true,
        reply: MSG_LINKED,
        linkedCustomerId: customerId,
      });
      continue;
    }

    // その他（sticker / image / postback 等）は無視
    out.push({
      type: ev.type ?? 'unknown',
      handled: false,
      reply: null,
      linkedCustomerId: null,
    });
  }

  return out;
}

/**
 * HTTPS ハンドラ本体（署名検証込み）
 */
export async function handleLineWebhook(
  req: Request,
  res: HttpResponseLike,
  db: Firestore,
  channelSecret: string | undefined,
  accessToken: string | undefined
): Promise<void> {
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }

  const signature = headerValue(req, 'x-line-signature');
  // firebase-functions の HTTPS onRequest は rawBody を提供する
  const rawBody = (req as unknown as {rawBody?: Buffer}).rawBody;

  if (!verifyLineSignature(rawBody, signature, channelSecret)) {
    logger.warn('[lineWebhook] invalid signature rejected');
    res.status(403).send('Invalid signature');
    return;
  }

  if (!accessToken) {
    logger.error('[lineWebhook] LINE_CHANNEL_ACCESS_TOKEN is not set');
    // LINE 側のリトライ嵐を避けるため 200 で受領だけする
    res.status(200).send('OK (token unset)');
    return;
  }

  let events: LineEvent[] = [];
  try {
    const body =
      typeof req.body === 'object' && req.body !== null
        ? (req.body as {events?: LineEvent[]})
        : (JSON.parse(String(rawBody ?? '{}')) as {events?: LineEvent[]});
    events = Array.isArray(body.events) ? body.events : [];
  } catch (e) {
    logger.warn('[lineWebhook] body parse failed', {
      error: e instanceof Error ? e.message : String(e),
    });
    res.status(200).send('OK');
    return;
  }

  try {
    await processWebhookEvents(db, accessToken, events);
  } catch (e) {
    logger.error('[lineWebhook] processing error', {
      error: e instanceof Error ? e.message : String(e),
    });
  }
  // LINE には常に 200 を返す（処理失敗でもリトライさせない）
  res.status(200).send('OK');
}

function headerValue(req: Request, name: string): string | undefined {
  const v = (req.headers as Record<string, string | string[] | undefined>)[
    name
  ];
  if (Array.isArray(v)) return v[0];
  return v;
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
