/**
 * lineWebhook のユニットテスト
 *
 * 検証対象:
 *  - x-line-signature の署名検証（正常 / 不正 / 欠落）
 *  - POST 以外のメソッド拒否
 *  - follow イベント → 連携コード案内を reply
 *  - message イベント: コード一致 → line_linkage 保存 + 完了 reply
 *                      コード不一致 → 「コードが違います」
 *                      期限切れ → 期限切れ案内（連携しない）
 *                      コード書式でない → 案内のみ（Firestore を汚さない）
 */
import {
  handleLineWebhook,
  processWebhookEvents,
  normalizeCode,
  MSG_FOLLOW,
  MSG_LINKED,
  MSG_WRONG_CODE,
  MSG_EXPIRED,
  MSG_NOT_A_CODE,
} from '../src/lineWebhook';
import {verifyLineSignature, signBodyForTest} from '../src/line/signature';
import {setLineApiForTest} from '../src/line/client';
import {FakeFirestore} from './fakeFirestore';
import {FakeLineApi} from './fakeLineApi';

const SECRET = 'test-channel-secret';
const TOKEN = 'test-access-token';
const U1 = 'U' + 'a'.repeat(32);

let db: FakeFirestore;
let line: FakeLineApi;

beforeEach(() => {
  db = new FakeFirestore();
  line = new FakeLineApi();
  setLineApiForTest(line);
});

afterEach(() => setLineApiForTest(null));

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

function fakeReq(body: unknown, signature?: string, method = 'POST') {
  const raw = Buffer.from(JSON.stringify(body), 'utf8');
  return {
    method,
    headers: signature === undefined ? {} : {'x-line-signature': signature},
    body,
    rawBody: raw,
  };
}

// ── 署名検証 ──────────────────────────────────────────────────

describe('署名検証', () => {
  it('正しい署名は検証を通る', () => {
    const body = JSON.stringify({events: []});
    const sig = signBodyForTest(body, SECRET);
    expect(verifyLineSignature(body, sig, SECRET)).toBe(true);
  });

  it('不正な署名は拒否される', () => {
    const body = JSON.stringify({events: []});
    expect(verifyLineSignature(body, 'bogus-signature', SECRET)).toBe(false);
  });

  it('別シークレットで作った署名は拒否される', () => {
    const body = JSON.stringify({events: []});
    const sig = signBodyForTest(body, 'another-secret');
    expect(verifyLineSignature(body, sig, SECRET)).toBe(false);
  });

  it('ボディ改変を検出する', () => {
    const sig = signBodyForTest(JSON.stringify({events: []}), SECRET);
    expect(
      verifyLineSignature(JSON.stringify({events: [{type: 'follow'}]}), sig, SECRET)
    ).toBe(false);
  });

  it('署名欠落・シークレット欠落は false', () => {
    const body = JSON.stringify({events: []});
    expect(verifyLineSignature(body, undefined, SECRET)).toBe(false);
    expect(verifyLineSignature(body, 'x', undefined)).toBe(false);
    expect(verifyLineSignature(undefined, 'x', SECRET)).toBe(false);
  });
});

describe('handleLineWebhook（HTTP 層）', () => {
  it('署名が不正なら 403 を返し一切処理しない', async () => {
    const body = {events: [{type: 'follow', replyToken: 'rt', source: {userId: U1}}]};
    const {res, state} = fakeRes();
    await handleLineWebhook(
      fakeReq(body, 'invalid') as never,
      res as never,
      db.asFirestore(),
      SECRET,
      TOKEN
    );
    expect(state.status).toBe(403);
    expect(line.replyCalls).toHaveLength(0);
  });

  it('署名ヘッダ欠落なら 403', async () => {
    const body = {events: []};
    const {res, state} = fakeRes();
    await handleLineWebhook(
      fakeReq(body, undefined) as never,
      res as never,
      db.asFirestore(),
      SECRET,
      TOKEN
    );
    expect(state.status).toBe(403);
  });

  it('POST 以外は 405', async () => {
    const {res, state} = fakeRes();
    await handleLineWebhook(
      fakeReq({events: []}, 'sig', 'GET') as never,
      res as never,
      db.asFirestore(),
      SECRET,
      TOKEN
    );
    expect(state.status).toBe(405);
  });

  it('正しい署名なら 200 を返し follow を処理する', async () => {
    const body = {
      events: [{type: 'follow', replyToken: 'rt1', source: {userId: U1}}],
    };
    const sig = signBodyForTest(JSON.stringify(body), SECRET);
    const {res, state} = fakeRes();
    await handleLineWebhook(
      fakeReq(body, sig) as never,
      res as never,
      db.asFirestore(),
      SECRET,
      TOKEN
    );
    expect(state.status).toBe(200);
    expect(line.replyCalls).toHaveLength(1);
    expect(line.replyCalls[0].text).toBe(MSG_FOLLOW);
  });
});

// ── イベント処理 ──────────────────────────────────────────────

describe('follow イベント', () => {
  it('連携コードの送信を案内する', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {type: 'follow', replyToken: 'rt', source: {userId: U1}},
    ]);
    expect(out[0].reply).toBe(MSG_FOLLOW);
    expect(line.replyCalls[0].text).toContain('連携コード');
  });
});

describe('message イベント（連携コード）', () => {
  beforeEach(() => {
    db.seed('linking_codes', 'A1B2C3', {
      code: 'A1B2C3',
      customerId: 'cust-001',
      createdAt: new Date(),
      expiresAt: new Date(Date.now() + 7 * 24 * 3600 * 1000),
    });
  });

  it('コードが一致したら line_linkage に保存し完了を返す', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {
        type: 'message',
        replyToken: 'rt',
        source: {userId: U1},
        message: {type: 'text', text: 'A1B2C3'},
      },
    ]);
    expect(out[0].reply).toBe(MSG_LINKED);
    expect(out[0].linkedCustomerId).toBe('cust-001');

    const link = db.get('line_linkage', 'cust-001');
    expect(link).toBeDefined();
    expect(link!.lineUserId).toBe(U1);
    expect(link!.customerId).toBe('cust-001');
    expect(link!.linkedBy).toBe('line_webhook');

    // 使用済みコードは削除されている（使い回し防止）
    expect(db.get('linking_codes', 'A1B2C3')).toBeUndefined();
  });

  it('小文字・空白混じりでも正規化して一致する', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {
        type: 'message',
        replyToken: 'rt',
        source: {userId: U1},
        message: {type: 'text', text: ' a1b2 c3 '},
      },
    ]);
    expect(out[0].linkedCustomerId).toBe('cust-001');
  });

  it('全角入力でも正規化して一致する', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {
        type: 'message',
        replyToken: 'rt',
        source: {userId: U1},
        message: {type: 'text', text: 'Ａ１Ｂ２Ｃ３'},
      },
    ]);
    expect(out[0].linkedCustomerId).toBe('cust-001');
  });

  it('存在しないコードは「コードが違います」で連携しない', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {
        type: 'message',
        replyToken: 'rt',
        source: {userId: U1},
        message: {type: 'text', text: 'ZZZZZZ'},
      },
    ]);
    expect(out[0].reply).toBe(MSG_WRONG_CODE);
    expect(out[0].linkedCustomerId).toBeNull();
    expect(Object.keys(db.docs('line_linkage'))).toHaveLength(0);
  });

  it('期限切れコードは連携せず期限切れ案内を返す', async () => {
    db.seed('linking_codes', 'OLD123', {
      code: 'OLD123',
      customerId: 'cust-002',
      createdAt: new Date(Date.now() - 30 * 24 * 3600 * 1000),
      expiresAt: new Date(Date.now() - 24 * 3600 * 1000),
    });
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {
        type: 'message',
        replyToken: 'rt',
        source: {userId: U1},
        message: {type: 'text', text: 'OLD123'},
      },
    ]);
    expect(out[0].reply).toBe(MSG_EXPIRED);
    expect(db.get('line_linkage', 'cust-002')).toBeUndefined();
    // 期限切れコードは残す（職員が状況を確認できるように）
    expect(db.get('linking_codes', 'OLD123')).toBeDefined();
  });

  it('コード書式でないテキストは Firestore を引かず案内のみ', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {
        type: 'message',
        replyToken: 'rt',
        source: {userId: U1},
        message: {type: 'text', text: 'こんにちは、明日は休みますか？'},
      },
    ]);
    expect(out[0].reply).toBe(MSG_NOT_A_CODE);
    expect(Object.keys(db.docs('line_linkage'))).toHaveLength(0);
  });

  it('画像・スタンプなどテキスト以外は無視する', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {
        type: 'message',
        replyToken: 'rt',
        source: {userId: U1},
        message: {type: 'sticker'},
      },
    ]);
    expect(out[0].handled).toBe(false);
    expect(line.replyCalls).toHaveLength(0);
  });

  it('unfollow は reply せずログのみ', async () => {
    const out = await processWebhookEvents(db.asFirestore(), TOKEN, [
      {type: 'unfollow', source: {userId: U1}},
    ]);
    expect(out[0].handled).toBe(true);
    expect(out[0].reply).toBeNull();
    expect(line.replyCalls).toHaveLength(0);
  });
});

describe('normalizeCode', () => {
  it('全角・小文字・空白・ハイフンを正規化する', () => {
    expect(normalizeCode(' ab-12 cd ')).toBe('AB12CD');
    expect(normalizeCode('Ａ１Ｂ２Ｃ３')).toBe('A1B2C3');
  });
});
