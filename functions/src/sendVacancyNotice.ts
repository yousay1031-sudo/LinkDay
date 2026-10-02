/**
 * sendVacancyNotice — 空き枠 LINE 通知（Callable Function）
 *
 * 【設計の最重要方針】
 * 1. 認証必須: Firebase Auth の ID トークンが無いリクエストは
 *    HttpsError('unauthenticated') で拒否する。
 * 2. 冪等: 同一 date + customerId には二度送らない。
 *    notification_logs/{date}_{customerId} を Firestore の
 *    `create`（存在したら失敗）で先に予約してから送信するため、
 *    同時実行（ダブルクリック・2端末同時）でも二重送信にならない。
 * 3. 誤送信防止: lineUserId の形式検証（U + 32桁 hex）を通らない宛先は
 *    送信せず invalid として返す。
 * 4. 秘匿: チャネルアクセストークンは Secret Manager から読み、
 *    レスポンス・ログ・Firestore には一切含めない。
 */
import {HttpsError, type CallableRequest} from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import type {Firestore} from 'firebase-admin/firestore';

import {COLLECTIONS} from './config';
import {LINE_TEXT_MAX_LENGTH, lineApi, maskUserId} from './line/client';

/** 通知の宛先 1 件 */
export interface Recipient {
  customerId: string;
  lineUserId: string;
  childName: string;
}

/** Callable の入力 */
export interface SendVacancyNoticeInput {
  /** 対象日（YYYY-MM-DD） */
  date: string;
  recipients: Recipient[];
  message: string;
}

/** 1 件ごとの結果ステータス */
export type SendStatus =
  | 'sent'
  | 'failed'
  | 'duplicate'
  | 'invalid_line_user_id';

/** 1 件ごとの結果 */
export interface SendResultItem {
  customerId: string;
  childName: string;
  status: SendStatus;
  /** LINE API の HTTP ステータス（未送信は null） */
  httpStatus: number | null;
  /** エラー要約（成功時は null） */
  error: string | null;
}

/** Callable の返り値 */
export interface SendVacancyNoticeOutput {
  date: string;
  sentCount: number;
  failedCount: number;
  duplicateCount: number;
  invalidCount: number;
  results: SendResultItem[];
}

/** YYYY-MM-DD 形式か */
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** LINE userId: 'U' + 32 桁の 16 進英数字（計 33 文字） */
const LINE_USER_ID_RE = /^U[0-9a-f]{32}$/i;

/** 一度に送れる宛先数の上限（誤爆・無料枠超過の予防） */
export const MAX_RECIPIENTS = 50;

export function isValidLineUserId(id: unknown): boolean {
  return typeof id === 'string' && LINE_USER_ID_RE.test(id.trim());
}

/** 入力バリデーション（不正なら HttpsError を投げる） */
export function validateInput(data: unknown): SendVacancyNoticeInput {
  if (data === null || typeof data !== 'object') {
    throw new HttpsError('invalid-argument', 'リクエスト本文が不正です。');
  }
  const d = data as Record<string, unknown>;

  const date = typeof d.date === 'string' ? d.date.trim() : '';
  if (!DATE_RE.test(date)) {
    throw new HttpsError(
      'invalid-argument',
      'date は YYYY-MM-DD 形式で指定してください。'
    );
  }
  // 日付として実在するか（2026-02-31 等を弾く）
  const [y, m, dd] = date.split('-').map((s) => parseInt(s, 10));
  const probe = new Date(Date.UTC(y, m - 1, dd));
  if (
    probe.getUTCFullYear() !== y ||
    probe.getUTCMonth() !== m - 1 ||
    probe.getUTCDate() !== dd
  ) {
    throw new HttpsError('invalid-argument', 'date が実在しない日付です。');
  }

  const message = typeof d.message === 'string' ? d.message.trim() : '';
  if (message.length === 0) {
    throw new HttpsError('invalid-argument', 'message が空です。');
  }
  if (message.length > LINE_TEXT_MAX_LENGTH) {
    throw new HttpsError(
      'invalid-argument',
      `message が長すぎます（最大 ${LINE_TEXT_MAX_LENGTH} 文字）。`
    );
  }

  if (!Array.isArray(d.recipients) || d.recipients.length === 0) {
    throw new HttpsError('invalid-argument', 'recipients が空です。');
  }
  if (d.recipients.length > MAX_RECIPIENTS) {
    throw new HttpsError(
      'invalid-argument',
      `recipients が多すぎます（最大 ${MAX_RECIPIENTS} 件）。`
    );
  }

  const recipients: Recipient[] = d.recipients.map((r, i) => {
    if (r === null || typeof r !== 'object') {
      throw new HttpsError(
        'invalid-argument',
        `recipients[${i}] が不正です。`
      );
    }
    const rr = r as Record<string, unknown>;
    const customerId =
      typeof rr.customerId === 'string' ? rr.customerId.trim() : '';
    if (customerId.length === 0) {
      throw new HttpsError(
        'invalid-argument',
        `recipients[${i}].customerId が空です。`
      );
    }
    return {
      customerId,
      lineUserId:
        typeof rr.lineUserId === 'string' ? rr.lineUserId.trim() : '',
      childName: typeof rr.childName === 'string' ? rr.childName.trim() : '',
    };
  });

  // 同一リクエスト内の customerId 重複を排除（UI 事故の保険）
  const seen = new Set<string>();
  const deduped = recipients.filter((r) => {
    if (seen.has(r.customerId)) return false;
    seen.add(r.customerId);
    return true;
  });

  return {date, recipients: deduped, message};
}

/**
 * 本体ロジック（Firestore / LINE API を注入してテスト可能にする）
 *
 * @param db Firestore（Admin SDK）
 * @param uid 送信操作を行った職員の Firebase Auth uid
 */
export async function runSendVacancyNotice(
  db: Firestore,
  uid: string,
  input: SendVacancyNoticeInput,
  accessToken: string
): Promise<SendVacancyNoticeOutput> {
  const api = lineApi();
  const results: SendResultItem[] = [];

  for (const r of input.recipients) {
    // ── 1. 宛先形式の検証（誤送信防止）
    if (!isValidLineUserId(r.lineUserId)) {
      results.push({
        customerId: r.customerId,
        childName: r.childName,
        status: 'invalid_line_user_id',
        httpStatus: null,
        error: 'lineUserId の形式が不正です（U + 32桁英数字）。',
      });
      continue;
    }

    // ── 2. 冪等予約: ログ doc を create（既存なら二重送信として拒否）
    const logId = `${input.date}_${r.customerId}`;
    const logRef = db.collection(COLLECTIONS.notificationLogs).doc(logId);

    try {
      await logRef.create({
        date: input.date,
        customerId: r.customerId,
        childName: r.childName,
        lineUserId: r.lineUserId,
        status: 'pending',
        sentBy: uid,
        sentAt: new Date(),
      });
    } catch (e) {
      // ALREADY_EXISTS → 既に送信済み（または送信中）
      logger.info('[sendVacancyNotice] duplicate blocked', {
        date: input.date,
        customerId: r.customerId,
      });
      results.push({
        customerId: r.customerId,
        childName: r.childName,
        status: 'duplicate',
        httpStatus: null,
        error: 'この日付・児童には既に通知済みです。',
      });
      continue;
    }

    // ── 3. LINE push 送信
    const push = await api.pushText(accessToken, r.lineUserId, input.message);

    const status: SendStatus = push.ok ? 'sent' : 'failed';
    await logRef.set(
      {
        status,
        httpStatus: push.httpStatus,
        error: push.error ?? null,
        sentAt: new Date(),
      },
      {merge: true}
    );

    logger.info('[sendVacancyNotice] push result', {
      date: input.date,
      customerId: r.customerId,
      lineUserId: maskUserId(r.lineUserId),
      status,
      httpStatus: push.httpStatus,
    });

    results.push({
      customerId: r.customerId,
      childName: r.childName,
      status,
      httpStatus: push.httpStatus,
      error: push.error ?? null,
    });
  }

  const out: SendVacancyNoticeOutput = {
    date: input.date,
    sentCount: results.filter((x) => x.status === 'sent').length,
    failedCount: results.filter((x) => x.status === 'failed').length,
    duplicateCount: results.filter((x) => x.status === 'duplicate').length,
    invalidCount: results.filter((x) => x.status === 'invalid_line_user_id')
      .length,
    results,
  };

  logger.info('[sendVacancyNotice] done', {
    date: out.date,
    sent: out.sentCount,
    failed: out.failedCount,
    duplicate: out.duplicateCount,
    invalid: out.invalidCount,
  });
  return out;
}

/**
 * Callable ハンドラ本体（認証チェック込み）
 * index.ts から onCall に渡す。
 */
export async function handleSendVacancyNotice(
  req: CallableRequest<unknown>,
  db: Firestore,
  accessToken: string | undefined
): Promise<SendVacancyNoticeOutput> {
  // ── 認証必須（ID トークン検証は onCall が実施。auth が無い = 未認証）
  if (!req.auth || !req.auth.uid) {
    logger.warn('[sendVacancyNotice] unauthenticated request rejected');
    throw new HttpsError(
      'unauthenticated',
      'ログインが必要です。再度サインインしてください。'
    );
  }

  if (!accessToken) {
    logger.error('[sendVacancyNotice] LINE_CHANNEL_ACCESS_TOKEN is not set');
    throw new HttpsError(
      'failed-precondition',
      'LINE チャネルアクセストークンが未設定です。管理者に連絡してください。'
    );
  }

  const input = validateInput(req.data);
  return runSendVacancyNotice(db, req.auth.uid, input, accessToken);
}
