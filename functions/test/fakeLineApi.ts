/**
 * テスト用 LINE API フェイク
 * 実際の api.line.me へは一切アクセスしない。
 */
import type {
  LineApi,
  PushResult,
  ReplyResult,
} from '../src/line/client';

export interface PushCall {
  lineUserId: string;
  text: string;
  /** アクセストークンが渡っているか（値はテストでも検証しない）*/
  hasToken: boolean;
}

export interface ReplyCall {
  replyToken: string;
  text: string;
}

/** Day 13: Flex 等の任意メッセージ push */
export interface PushMessageCall {
  lineUserId: string;
  message: unknown;
}

export class FakeLineApi implements LineApi {
  pushCalls: PushCall[] = [];
  replyCalls: ReplyCall[] = [];
  pushMessageCalls: PushMessageCall[] = [];

  /** 特定 userId を失敗させる（LINE API エラー再現） */
  failUserIds = new Set<string>();
  failHttpStatus = 400;
  failMessage = 'The user hasn\'t added the LINE Official Account as a friend.';

  async pushText(
    accessToken: string,
    lineUserId: string,
    text: string
  ): Promise<PushResult> {
    this.pushCalls.push({
      lineUserId,
      text,
      hasToken: accessToken.length > 0,
    });
    if (this.failUserIds.has(lineUserId)) {
      return {
        lineUserId,
        ok: false,
        httpStatus: this.failHttpStatus,
        error: this.failMessage,
      };
    }
    return {lineUserId, ok: true, httpStatus: 200};
  }

  async pushMessage(
    accessToken: string,
    lineUserId: string,
    message: unknown
  ): Promise<PushResult> {
    this.pushMessageCalls.push({lineUserId, message});
    // 検証を簡単にするため、送信先の記録は pushCalls にも残す。
    this.pushCalls.push({
      lineUserId,
      text: JSON.stringify(message),
      hasToken: accessToken.length > 0,
    });
    if (this.failUserIds.has(lineUserId)) {
      return {
        lineUserId,
        ok: false,
        httpStatus: this.failHttpStatus,
        error: this.failMessage,
      };
    }
    return {lineUserId, ok: true, httpStatus: 200};
  }

  async replyText(
    accessToken: string,
    replyToken: string,
    text: string
  ): Promise<ReplyResult> {
    this.replyCalls.push({replyToken, text});
    return {ok: true, httpStatus: 200};
  }

  reset(): void {
    this.pushCalls = [];
    this.replyCalls = [];
    this.pushMessageCalls = [];
    this.failUserIds.clear();
  }
}
