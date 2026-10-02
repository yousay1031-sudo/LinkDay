/**
 * sendVacancyNotice のユニットテスト
 *
 * 検証対象:
 *  - 未認証リクエストの拒否（unauthenticated）
 *  - トークン未設定時の拒否（failed-precondition）
 *  - 入力バリデーション（日付形式・空 message・空 recipients・件数上限）
 *  - push 成功 / 失敗の記録
 *  - 二重送信拒否（同一 date + customerId）
 *  - lineUserId 形式不正の送信ブロック
 *  - トークンがレスポンスに含まれないこと
 */
import {HttpsError, type CallableRequest} from 'firebase-functions/v2/https';

import {setLineApiForTest} from '../src/line/client';
import {
  handleSendVacancyNotice,
  runSendVacancyNotice,
  validateInput,
  isValidLineUserId,
  MAX_RECIPIENTS,
  type SendVacancyNoticeInput,
} from '../src/sendVacancyNotice';
import {FakeFirestore} from './fakeFirestore';
import {FakeLineApi} from './fakeLineApi';

const TOKEN = 'dummy-access-token-for-test';
const UID = 'staff-uid-001';

/** 有効な LINE userId（U + 32桁 hex） */
const U1 = 'U' + 'a'.repeat(32);
const U2 = 'U' + 'b'.repeat(32);
const U3 = 'U' + 'c'.repeat(32);

let db: FakeFirestore;
let line: FakeLineApi;

beforeEach(() => {
  db = new FakeFirestore();
  line = new FakeLineApi();
  setLineApiForTest(line);
});

afterEach(() => {
  setLineApiForTest(null);
});

function callableReq(
  data: unknown,
  auth: {uid: string} | null
): CallableRequest<unknown> {
  return {
    data,
    auth: auth ? ({uid: auth.uid, token: {}} as never) : undefined,
    rawRequest: {} as never,
    acceptsStreaming: false,
  } as unknown as CallableRequest<unknown>;
}

function input(
  overrides: Partial<SendVacancyNoticeInput> = {}
): SendVacancyNoticeInput {
  return {
    date: '2026-10-02',
    message: '【ココスタディ】本日（10/2）空きが出ました。',
    recipients: [
      {customerId: 'c1', lineUserId: U1, childName: '山田 太郎'},
    ],
    ...overrides,
  };
}

// ── 認証 ──────────────────────────────────────────────────────

describe('認証', () => {
  it('未認証リクエストは unauthenticated で拒否される', async () => {
    await expect(
      handleSendVacancyNotice(
        callableReq(input(), null),
        db.asFirestore(),
        TOKEN
      )
    ).rejects.toThrow(HttpsError);

    await expect(
      handleSendVacancyNotice(
        callableReq(input(), null),
        db.asFirestore(),
        TOKEN
      )
    ).rejects.toMatchObject({code: 'unauthenticated'});

    // 1件も送信されていない
    expect(line.pushCalls).toHaveLength(0);
  });

  it('認証済みなら送信される', async () => {
    const out = await handleSendVacancyNotice(
      callableReq(input(), {uid: UID}),
      db.asFirestore(),
      TOKEN
    );
    expect(out.sentCount).toBe(1);
    expect(line.pushCalls).toHaveLength(1);
  });

  it('チャネルアクセストークン未設定は failed-precondition で拒否', async () => {
    await expect(
      handleSendVacancyNotice(
        callableReq(input(), {uid: UID}),
        db.asFirestore(),
        undefined
      )
    ).rejects.toMatchObject({code: 'failed-precondition'});
    expect(line.pushCalls).toHaveLength(0);
  });
});

// ── 入力バリデーション ────────────────────────────────────────

describe('入力バリデーション', () => {
  it('date が YYYY-MM-DD でないと invalid-argument', () => {
    expect(() => validateInput(input({date: '2026/10/02'}))).toThrow(
      HttpsError
    );
    expect(() => validateInput(input({date: ''}))).toThrow(HttpsError);
  });

  it('実在しない日付は invalid-argument', () => {
    expect(() => validateInput(input({date: '2026-02-31'}))).toThrow(
      HttpsError
    );
  });

  it('message が空だと invalid-argument', () => {
    expect(() => validateInput(input({message: '   '}))).toThrow(HttpsError);
  });

  it('recipients が空だと invalid-argument', () => {
    expect(() => validateInput(input({recipients: []}))).toThrow(HttpsError);
  });

  it('recipients が上限超過だと invalid-argument', () => {
    const many = Array.from({length: MAX_RECIPIENTS + 1}, (_, i) => ({
      customerId: `c${i}`,
      lineUserId: U1,
      childName: `児童${i}`,
    }));
    expect(() => validateInput(input({recipients: many}))).toThrow(HttpsError);
  });

  it('同一 customerId の重複は 1 件に正規化される', () => {
    const v = validateInput(
      input({
        recipients: [
          {customerId: 'c1', lineUserId: U1, childName: 'A'},
          {customerId: 'c1', lineUserId: U1, childName: 'A'},
        ],
      })
    );
    expect(v.recipients).toHaveLength(1);
  });

  it('lineUserId 形式判定', () => {
    expect(isValidLineUserId(U1)).toBe(true);
    expect(isValidLineUserId('U123')).toBe(false);
    expect(isValidLineUserId('X' + 'a'.repeat(32))).toBe(false);
    expect(isValidLineUserId(null)).toBe(false);
  });
});

// ── 送信結果 ──────────────────────────────────────────────────

describe('送信結果', () => {
  it('複数宛先の成功/失敗が集計され notification_logs に記録される', async () => {
    line.failUserIds.add(U2);

    const out = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({
        recipients: [
          {customerId: 'c1', lineUserId: U1, childName: 'A'},
          {customerId: 'c2', lineUserId: U2, childName: 'B'},
          {customerId: 'c3', lineUserId: U3, childName: 'C'},
        ],
      }),
      TOKEN
    );

    expect(out.sentCount).toBe(2);
    expect(out.failedCount).toBe(1);
    expect(line.pushCalls).toHaveLength(3);

    const logs = db.docs('notification_logs');
    expect(Object.keys(logs).sort()).toEqual([
      '2026-10-02_c1',
      '2026-10-02_c2',
      '2026-10-02_c3',
    ]);
    expect(logs['2026-10-02_c1'].status).toBe('sent');
    expect(logs['2026-10-02_c2'].status).toBe('failed');
    expect(logs['2026-10-02_c2'].httpStatus).toBe(400);
    expect(logs['2026-10-02_c1'].sentBy).toBe(UID);
  });

  it('lineUserId 形式不正は送信せず invalid_line_user_id を返す', async () => {
    const out = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({
        recipients: [
          {customerId: 'c1', lineUserId: 'not-a-line-id', childName: 'A'},
        ],
      }),
      TOKEN
    );
    expect(out.invalidCount).toBe(1);
    expect(out.sentCount).toBe(0);
    expect(line.pushCalls).toHaveLength(0);
    // ログも作らない（後で正しい ID で再送できるようにする）
    expect(Object.keys(db.docs('notification_logs'))).toHaveLength(0);
  });

  it('message がそのまま LINE に渡る', async () => {
    const msg = '【ココスタディ】本日（10/2）空きが出ました。15:00までにご連絡ください。';
    await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({message: msg}),
      TOKEN
    );
    expect(line.pushCalls[0].text).toBe(msg);
    expect(line.pushCalls[0].hasToken).toBe(true);
  });
});

// ── 冪等（二重送信拒否）──────────────────────────────────────

describe('二重送信拒否（サーバー側冪等）', () => {
  it('同一 date + customerId の 2 回目は duplicate で送信されない', async () => {
    const first = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input(),
      TOKEN
    );
    expect(first.sentCount).toBe(1);

    const second = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input(),
      TOKEN
    );
    expect(second.duplicateCount).toBe(1);
    expect(second.sentCount).toBe(0);

    // LINE への push は通算 1 回だけ
    expect(line.pushCalls).toHaveLength(1);
  });

  it('送信失敗した宛先も再送はブロックされる（ログが残るため）', async () => {
    line.failUserIds.add(U1);
    const first = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input(),
      TOKEN
    );
    expect(first.failedCount).toBe(1);

    const second = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input(),
      TOKEN
    );
    expect(second.duplicateCount).toBe(1);
    expect(line.pushCalls).toHaveLength(1);
  });

  it('日付が違えば送信できる', async () => {
    await runSendVacancyNotice(db.asFirestore(), UID, input(), TOKEN);
    const other = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({date: '2026-10-03'}),
      TOKEN
    );
    expect(other.sentCount).toBe(1);
    expect(line.pushCalls).toHaveLength(2);
  });

  it('同一リクエスト内に同じ児童が2件あっても1回しか送らない', async () => {
    const v = validateInput(
      input({
        recipients: [
          {customerId: 'c1', lineUserId: U1, childName: 'A'},
          {customerId: 'c1', lineUserId: U1, childName: 'A'},
        ],
      })
    );
    const out = await runSendVacancyNotice(db.asFirestore(), UID, v, TOKEN);
    expect(out.sentCount).toBe(1);
    expect(line.pushCalls).toHaveLength(1);
  });
});

// ── 秘匿 ──────────────────────────────────────────────────────

describe('トークン非漏洩', () => {
  it('レスポンス・Firestore ログにトークン文字列が含まれない', async () => {
    const out = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input(),
      TOKEN
    );
    expect(JSON.stringify(out)).not.toContain(TOKEN);
    expect(JSON.stringify(db.docs('notification_logs'))).not.toContain(TOKEN);
  });
});
