/**
 * firebase-functions-test で実際にエクスポートされた関数定義を
 * ラップして呼び出す統合寄りテスト。
 *
 * ここでは「デプロイされる形（onCall / onRequest の定義）」が
 * 認証チェックを確実に通ることを検証する。
 * LINE API は FakeLineApi に差し替えるため外部送信は発生しない。
 */
import functionsTest from 'firebase-functions-test';

// secrets（defineSecret）は実行時に process.env から解決されるため、
// import 前にダミー値を入れる。実トークンは使わない。
process.env.LINE_CHANNEL_ACCESS_TOKEN = 'dummy-token-for-wrap-test';
process.env.LINE_CHANNEL_SECRET = 'dummy-secret-for-wrap-test';
process.env.GCLOUD_PROJECT = 'linkday-proud';
process.env.FIREBASE_CONFIG = JSON.stringify({projectId: 'linkday-proud'});

const tester = functionsTest({projectId: 'linkday-proud'});

import {setLineApiForTest} from '../src/line/client';
import {FakeLineApi} from './fakeLineApi';
// eslint-disable-next-line @typescript-eslint/no-var-requires
import * as api from '../src/index';
import {signBodyForTest} from '../src/line/signature';

const U1 = 'U' + 'a'.repeat(32);
let line: FakeLineApi;

beforeEach(() => {
  line = new FakeLineApi();
  setLineApiForTest(line);
});

afterAll(() => {
  setLineApiForTest(null);
  tester.cleanup();
});

describe('sendVacancyNotice（wrap 経由）', () => {
  it('認証なしで呼ぶと unauthenticated で拒否され LINE に送信されない', async () => {
    const wrapped = tester.wrap(api.sendVacancyNotice);
    await expect(
      wrapped({
        data: {
          date: '2026-10-02',
          message: 'テスト',
          recipients: [
            {customerId: 'c1', lineUserId: U1, childName: 'テスト児童'},
          ],
        },
        // auth を渡さない = 未認証
      } as never)
    ).rejects.toMatchObject({code: 'unauthenticated'});

    expect(line.pushCalls).toHaveLength(0);
  });

  it('認証ありでも入力が不正なら invalid-argument（送信前に弾く）', async () => {
    const wrapped = tester.wrap(api.sendVacancyNotice);
    await expect(
      wrapped({
        data: {date: 'bad-date', message: 'x', recipients: []},
        auth: {uid: 'staff-1', token: {}},
      } as never)
    ).rejects.toMatchObject({code: 'invalid-argument'});

    expect(line.pushCalls).toHaveLength(0);
  });
});

describe('lineWebhook（署名検証が定義に含まれている）', () => {
  it('不正署名のリクエストは 403 を返す', async () => {
    const body = {events: [{type: 'follow', replyToken: 'rt', source: {userId: U1}}]};
    const raw = Buffer.from(JSON.stringify(body), 'utf8');

    let statusCode = 0;
    const res = {
      status(code: number) {
        statusCode = code;
        return res;
      },
      send() {
        return res;
      },
    };
    const req = {
      method: 'POST',
      headers: {'x-line-signature': 'definitely-wrong'},
      body,
      rawBody: raw,
    };

    // onRequest の実体を直接呼ぶ（HTTP ハンドラは wrap 不要）
    await (api.lineWebhook as unknown as (
      r: unknown,
      s: unknown
    ) => Promise<void>)(req, res);

    expect(statusCode).toBe(403);
    expect(line.replyCalls).toHaveLength(0);
  });

  it('正しい署名なら 200 で受領する', async () => {
    const body = {events: [{type: 'unfollow', source: {userId: U1}}]};
    const raw = Buffer.from(JSON.stringify(body), 'utf8');
    const sig = signBodyForTest(
      JSON.stringify(body),
      process.env.LINE_CHANNEL_SECRET!
    );

    let statusCode = 0;
    const res = {
      status(code: number) {
        statusCode = code;
        return res;
      },
      send() {
        return res;
      },
    };
    const req = {
      method: 'POST',
      headers: {'x-line-signature': sig},
      body,
      rawBody: raw,
    };

    await (api.lineWebhook as unknown as (
      r: unknown,
      s: unknown
    ) => Promise<void>)(req, res);

    expect(statusCode).toBe(200);
  });
});
