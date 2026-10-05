/**
 * Day 15: 管理者用「ID確認」コマンド
 *
 * 管理者が連携コードを送ると児童の保護者として line_linkage に誤登録される。
 * 児童に紐付けず userId だけを知るための専用経路を検証する。
 */
import * as logger from 'firebase-functions/logger';

import {
  buildIdCheckReply,
  handleLineWebhook,
  isIdCheckCommand,
  MSG_ID_CHECK_UNAVAILABLE,
  MSG_LINKED,
  MSG_NOT_A_CODE,
  MSG_WRONG_CODE,
  processWebhookEvents,
} from '../src/lineWebhook';
import {signBodyForTest} from '../src/line/signature';
import {setLineApiForTest} from '../src/line/client';
import {FakeFirestore} from './fakeFirestore';
import {FakeLineApi} from './fakeLineApi';

jest.mock('firebase-functions/logger', () => ({
  info: jest.fn(),
  warn: jest.fn(),
  error: jest.fn(),
  debug: jest.fn(),
  log: jest.fn(),
}));

const SECRET = 'test-channel-secret';
const TOKEN = 'test-access-token';
const ADMIN = 'U' + '1234567890abcdef'.repeat(2);

let db: FakeFirestore;
let line: FakeLineApi;

beforeEach(() => {
  jest.clearAllMocks();
  db = new FakeFirestore();
  line = new FakeLineApi();
  setLineApiForTest(line);
  db.seed('linking_codes', 'A1B2C3', {
    code: 'A1B2C3',
    customerId: 'cust-001',
    createdAt: new Date(),
    expiresAt: new Date(Date.now() + 7 * 24 * 3600 * 1000),
  });
});
afterEach(() => setLineApiForTest(null));

const msg = (text: string, userId: string | null = ADMIN) => ({
  type: 'message',
  replyToken: 'rt',
  source: userId === null ? {} : {userId},
  message: {type: 'text', text},
});

function logText(): string {
  const fns = [logger.info, logger.warn, logger.error, logger.debug, logger.log];
  return fns
    .flatMap((f) => (f as jest.Mock).mock.calls)
    .map((c) => JSON.stringify(c))
    .join('\n');
}

describe('isIdCheckCommand: 完全一致のみ', () => {
  test.each([
    ['ID確認', true],
    ['  ID確認  ', true],
    ['\nID確認\n', true],
    ['\u3000ID確認\u3000', true], // 全角スペース
    ['ID確認です', false],
    ['私のID確認', false],
    ['ID確認 お願いします', false],
    ['ID 確認', false],
    ['id確認', false],
    ['ＩＤ確認', false],
    ['ID確認!', false],
    ['', false],
    ['A1B2C3', false],
  ])('%j → %s', (text, expected) => {
    expect(isIdCheckCommand(text)).toBe(expected);
  });
});

describe('「ID確認」への応答', () => {
  test('送信者本人の userId を reply で返す', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      msg('ID確認'),
    ]);
    expect(out[0].handled).toBe(true);
    expect(out[0].reply).toBe(buildIdCheckReply(ADMIN));
    expect(line.replyCalls).toHaveLength(1);
    expect(line.replyCalls[0].text).toContain(`あなたのユーザーID: ${ADMIN}`);
    expect(line.replyCalls[0].text).toContain('管理者LINE通知欄に貼ってください');
    expect(line.replyCalls[0].replyToken).toBe('rt');
  });

  test('前後の空白は許容する', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      msg('  ID確認 \n'),
    ]);
    expect(out[0].reply).toBe(buildIdCheckReply(ADMIN));
  });

  test('何も保存しない（line_linkage・linking_codes は変化なし）', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      msg('ID確認'),
    ]);
    expect(out[0].linkedCustomerId).toBeNull();
    expect(Object.keys(db.docs('line_linkage'))).toHaveLength(0);
    // 未使用のコードも消費されない
    expect(db.get('linking_codes', 'A1B2C3')).toBeDefined();
  });

  test('push は使わない（reply のみ。月間送信枠を消費しない）', async () => {
    await processWebhookEvents(db.asFirestore(), TOKEN, [msg('ID確認')]);
    expect(line.pushCalls).toHaveLength(0);
    expect(line.pushMessageCalls).toHaveLength(0);
  });

  test('ログには生の userId を出さずマスクのみ', async () => {
    await processWebhookEvents(db.asFirestore(), TOKEN, [msg('ID確認')]);
    const logs = logText();
    expect(logs).not.toContain(ADMIN);
    expect(logs).toContain('U****' + ADMIN.slice(-4));
    expect(logs).toContain('id check');
  });

  test('userId が取れないイベントでは案内文を返し、「undefined」を出さない', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      msg('ID確認', null),
    ]);
    expect(out[0].reply).toBe(MSG_ID_CHECK_UNAVAILABLE);
    expect(line.replyCalls[0].text).not.toContain('undefined');
  });

  test('replyToken が無ければ reply せず落ちない', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {
        type: 'message',
        source: {userId: ADMIN},
        message: {type: 'text', text: 'ID確認'},
      },
    ]);
    expect(out[0].handled).toBe(true);
    expect(line.replyCalls).toHaveLength(0);
  });

  test('同一リクエスト内の他イベントに影響しない', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      msg('ID確認'),
      msg('A1B2C3', 'U' + 'b'.repeat(32)),
    ]);
    expect(out[0].reply).toBe(buildIdCheckReply(ADMIN));
    expect(out[1].reply).toBe(MSG_LINKED);
    expect(db.get('line_linkage', 'cust-001')!.lineUserId).toBe(
      'U' + 'b'.repeat(32)
    );
  });
});

describe('部分一致では反応しない（従来どおりの案内）', () => {
  test('「ID確認です」は ID を返さず通常の案内になる', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      msg('ID確認です'),
    ]);
    expect(out[0].reply).toBe(MSG_NOT_A_CODE);
    expect(line.replyCalls[0].text).not.toContain(ADMIN);
  });

  test('「私のID確認」「ID 確認」「id確認」も反応しない', async () => {
    for (const t of ['私のID確認', 'ID 確認', 'id確認']) {
      line.replyCalls.length = 0;
      const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
        msg(t),
      ]);
      expect(out[0].reply).toBe(MSG_NOT_A_CODE);
      expect(line.replyCalls[0].text).not.toContain(ADMIN);
    }
  });
});

describe('既存の挙動は変わらない', () => {
  test('連携コードの照合は従来どおり line_linkage へ保存する', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      msg('A1B2C3'),
    ]);
    expect(out[0].reply).toBe(MSG_LINKED);
    expect(out[0].linkedCustomerId).toBe('cust-001');
    expect(db.get('line_linkage', 'cust-001')!.lineUserId).toBe(ADMIN);
    expect(db.get('linking_codes', 'A1B2C3')).toBeUndefined();
  });

  test('「ID確認」の後に同じ人がコードを送れば通常どおり連携できる', async () => {
    await processWebhookEvents(db.asFirestore(), TOKEN, [msg('ID確認')]);
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      msg('A1B2C3'),
    ]);
    expect(out[0].linkedCustomerId).toBe('cust-001');
  });

  test('誤ったコードは従来どおり「コードが違います」', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      msg('ZZZZZZ'),
    ]);
    expect(out[0].reply).toBe(MSG_WRONG_CODE);
  });

  test('follow は従来どおり連携コードの案内', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {type: 'follow', replyToken: 'rt', source: {userId: ADMIN}},
    ]);
    expect(out[0].reply).toContain('連携コード');
    expect(out[0].reply).not.toContain(ADMIN);
  });
});

describe('署名検証の後ろでのみ動く（HTTP 層）', () => {
  function fakeRes() {
    const state = {status: 0, body: '' as unknown};
    const res = {
      status(code: number) {
        state.status = code;
        return res;
      },
      send(body: unknown) {
        state.body = body;
        return res;
      },
    };
    return {res, state};
  }

  const body = {events: [msg('ID確認')]};
  const raw = Buffer.from(JSON.stringify(body), 'utf8');

  test('正しい署名なら 200 で userId を返信する', async () => {
    const sig = signBodyForTest(raw.toString('utf8'), SECRET);
    const {res, state} = fakeRes();
    await handleLineWebhook(
      {method: 'POST', headers: {'x-line-signature': sig}, body, rawBody: raw} as never,
      res as never,
      db.asFirestore(),
      SECRET,
      TOKEN
    );
    expect(state.status).toBe(200);
    expect(line.replyCalls[0].text).toContain(ADMIN);
  });

  test('不正な署名なら 403 で、userId を返信しない', async () => {
    const {res, state} = fakeRes();
    await handleLineWebhook(
      {
        method: 'POST',
        headers: {'x-line-signature': 'invalid'},
        body,
        rawBody: raw,
      } as never,
      res as never,
      db.asFirestore(),
      SECRET,
      TOKEN
    );
    expect(state.status).toBe(403);
    expect(line.replyCalls).toHaveLength(0);
  });
});
