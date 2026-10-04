/**
 * LINE Messaging API クライアント
 *
 * 【モック可能な構造】
 * ユニットテストで実際に LINE へ送信しないよう、
 * HTTP 呼び出しを [LineApi] インターフェースに切り出し、
 * テスト側は [setLineApiForTest] でフェイク実装を差し込む。
 */
import * as logger from 'firebase-functions/logger';

/** push / multicast 1 件分の送信結果 */
export interface PushResult {
  lineUserId: string;
  ok: boolean;
  /** LINE API の HTTP ステータス（ネットワーク失敗時は 0） */
  httpStatus: number;
  /** LINE API のエラーメッセージ（成功時は undefined） */
  error?: string;
}

/** reply の結果 */
export interface ReplyResult {
  ok: boolean;
  httpStatus: number;
  error?: string;
}

/** LINE Messaging API の抽象（テストで差し替える） */
export interface LineApi {
  pushText(
    accessToken: string,
    lineUserId: string,
    text: string
  ): Promise<PushResult>;

  replyText(
    accessToken: string,
    replyToken: string,
    text: string
  ): Promise<ReplyResult>;

  /**
   * 任意の message オブジェクト（Flex 等）を push する（Day 13）
   *
   * 応募ボタン付きの Flex Message を送るために使う。
   * テキスト専用の [pushText] は既存フローが使っているため変更しない。
   */
  pushMessage(
    accessToken: string,
    lineUserId: string,
    message: unknown
  ): Promise<PushResult>;
}

const PUSH_ENDPOINT = 'https://api.line.me/v2/bot/message/push';
const REPLY_ENDPOINT = 'https://api.line.me/v2/bot/message/reply';

/** LINE テキストメッセージの最大長（API 仕様） */
export const LINE_TEXT_MAX_LENGTH = 5000;

/** 実際に LINE へ HTTP 送信する実装 */
export const realLineApi: LineApi = {
  async pushText(accessToken, lineUserId, text) {
    try {
      const res = await fetch(PUSH_ENDPOINT, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          // トークンはヘッダにのみ使用。ログには一切出さない。
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({
          to: lineUserId,
          messages: [{type: 'text', text: text.slice(0, LINE_TEXT_MAX_LENGTH)}],
        }),
      });

      if (res.ok) {
        return {lineUserId, ok: true, httpStatus: res.status};
      }
      const bodyText = await safeText(res);
      logger.warn('[line.push] failed', {
        lineUserId: maskUserId(lineUserId),
        httpStatus: res.status,
        error: bodyText,
      });
      return {
        lineUserId,
        ok: false,
        httpStatus: res.status,
        error: bodyText,
      };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.error('[line.push] network error', {
        lineUserId: maskUserId(lineUserId),
        error: msg,
      });
      return {lineUserId, ok: false, httpStatus: 0, error: msg};
    }
  },

  async pushMessage(accessToken, lineUserId, message) {
    try {
      const res = await fetch(PUSH_ENDPOINT, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({to: lineUserId, messages: [message]}),
      });

      if (res.ok) {
        return {lineUserId, ok: true, httpStatus: res.status};
      }
      const bodyText = await safeText(res);
      logger.warn('[line.pushMessage] failed', {
        lineUserId: maskUserId(lineUserId),
        httpStatus: res.status,
        error: bodyText,
      });
      return {lineUserId, ok: false, httpStatus: res.status, error: bodyText};
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.error('[line.pushMessage] network error', {
        lineUserId: maskUserId(lineUserId),
        error: msg,
      });
      return {lineUserId, ok: false, httpStatus: 0, error: msg};
    }
  },

  async replyText(accessToken, replyToken, text) {
    try {
      const res = await fetch(REPLY_ENDPOINT, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({
          replyToken,
          messages: [{type: 'text', text: text.slice(0, LINE_TEXT_MAX_LENGTH)}],
        }),
      });
      if (res.ok) return {ok: true, httpStatus: res.status};
      const bodyText = await safeText(res);
      logger.warn('[line.reply] failed', {
        httpStatus: res.status,
        error: bodyText,
      });
      return {ok: false, httpStatus: res.status, error: bodyText};
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.error('[line.reply] network error', {error: msg});
      return {ok: false, httpStatus: 0, error: msg};
    }
  },
};

let currentApi: LineApi = realLineApi;

/** 現在有効な LINE API 実装を返す */
export function lineApi(): LineApi {
  return currentApi;
}

/** テスト用: LINE API 実装を差し替える */
export function setLineApiForTest(api: LineApi | null): void {
  currentApi = api ?? realLineApi;
}

async function safeText(res: Response): Promise<string> {
  try {
    const t = await res.text();
    return t.slice(0, 500);
  } catch {
    return `HTTP ${res.status}`;
  }
}

/** ログ用に LINE userId をマスクする（末尾4桁のみ） */
export function maskUserId(id: string): string {
  if (id.length <= 6) return 'U****';
  return `U****${id.slice(-4)}`;
}
