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
import {buildVacancyFlexMessage} from './slotMessage';
import {
  appendNotified,
  createSlotIfAbsent,
  hashLineUserId,
  makeSlotId,
  type NotifiedEntry,
} from './slots';
import {SLOT_TTL_HOURS} from './config';

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
  /**
   * Day 13: 欠席した児童の customerId（空き枠の出所）
   *
   * 指定された場合のみ「応募する」ボタン付きの Flex を送る。
   * 未指定なら従来どおりテキストのみ（後方互換）。
   */
  sourceAbsentCustomerId?: string;
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

  const sourceAbsentCustomerId =
    typeof d.sourceAbsentCustomerId === 'string'
      ? d.sourceAbsentCustomerId.trim()
      : '';

  return {
    date,
    recipients: deduped,
    message,
    sourceAbsentCustomerId:
      sourceAbsentCustomerId.length > 0 ? sourceAbsentCustomerId : undefined,
  };
}

/**
 * 枠の確認コードを生成する（6桁英数・紛らわしい文字を除く）。
 *
 * postback data に載せ、通知を受け取った本人かの簡易裏付けに使う。
 * 本人性の主たる担保は LINE の署名検証（source.userId）であり、
 * これは「古い通知のボタンを使い回せない」ための補助。
 */
export function generateSlotCode(): string {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const crypto = require('crypto') as typeof import('crypto');
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  const buf = crypto.randomBytes(6);
  let out = '';
  for (let i = 0; i < 6; i++) out += alphabet[buf[i] % alphabet.length];
  return out;
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
  accessToken: string,
  /** Day 13: lineUserId のハッシュ用ソルト。未指定なら枠を作らずテキスト送信 */
  channelSecret?: string
): Promise<SendVacancyNoticeOutput> {
  const api = lineApi();
  const results: SendResultItem[] = [];

  // ── Day 13: 応募ボタンを付けるかの判定
  // sourceAbsentCustomerId と channelSecret が揃ったときだけ枠を作る。
  // 揃わない場合は従来どおりテキストのみ（後方互換・既存テストも通る）。
  const useSlot =
    typeof input.sourceAbsentCustomerId === 'string' &&
    input.sourceAbsentCustomerId.length > 0 &&
    typeof channelSecret === 'string' &&
    channelSecret.length > 0;

  const slotId = useSlot
    ? makeSlotId(input.date, input.sourceAbsentCustomerId as string)
    : '';
  let slotCode = '';
  let slotExpiresAt = new Date();

  if (useSlot) {
    const now = new Date();
    slotExpiresAt = new Date(now.getTime() + SLOT_TTL_HOURS * 3600 * 1000);
    slotCode = generateSlotCode();
    // 通知対象を先に notifiedList として登録しておく
    // （応募時に「通知を受け取った人か」を判定するため）
    const notified: NotifiedEntry[] = input.recipients
      .filter((r) => isValidLineUserId(r.lineUserId))
      .map((r) => ({
        customerId: r.customerId,
        lineUserIdHash: hashLineUserId(
          r.lineUserId,
          channelSecret as string
        ),
        servedAt: now,
      }));

    const created = await createSlotIfAbsent(db, {
      slotId,
      dateKey: input.date,
      sourceAbsent: input.sourceAbsentCustomerId as string,
      linkCode: slotCode,
      notifiedList: notified,
      createdBy: 'vacancy_notice',
      now,
    });

    if (!created) {
      // 既存の枠（同じ日の追加送信）。確定済みかもしれないので作り直さず、
      // 既存の linkCode / expiresAt を読み直して使う。
      const snap = await db.collection(COLLECTIONS.slots).doc(slotId).get();
      const data = (snap.data() ?? {}) as Record<string, unknown>;
      if (typeof data.linkCode === 'string') slotCode = data.linkCode;
      const ex = data.expiresAt;
      if (ex instanceof Date) slotExpiresAt = ex;
      else if (
        ex !== null &&
        typeof ex === 'object' &&
        ex !== undefined &&
        'toDate' in (ex as object)
      ) {
        slotExpiresAt = (ex as {toDate: () => Date}).toDate();
      }
      // 新しく追加された宛先を notifiedList に足す
      for (const r of input.recipients) {
        if (!isValidLineUserId(r.lineUserId)) continue;
        await appendNotified(db, slotId, {
          customerId: r.customerId,
          lineUserIdHash: hashLineUserId(
            r.lineUserId,
            channelSecret as string
          ),
          servedAt: new Date(),
        });
      }
    }
    logger.info('[sendVacancyNotice] slot ready', {
      slotId,
      created,
      recipients: input.recipients.length,
    });
  }

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
    // 枠がある場合は応募ボタン付き Flex、無い場合は従来どおりテキスト。
    const push = useSlot
      ? await api.pushMessage(
          accessToken,
          r.lineUserId,
          buildVacancyFlexMessage({
            dateKey: input.date,
            message: input.message,
            slotId,
            linkCode: slotCode,
            expiresAt: slotExpiresAt,
          })
        )
      : await api.pushText(accessToken, r.lineUserId, input.message);

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
  accessToken: string | undefined,
  /** Day 13: 応募ボタン用。未設定ならテキスト送信にフォールバック */
  channelSecret?: string
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
  return runSendVacancyNotice(
    db,
    req.auth.uid,
    input,
    accessToken,
    channelSecret
  );
}
