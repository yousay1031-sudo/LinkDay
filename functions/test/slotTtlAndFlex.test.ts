/**
 * Day 14: これまでテストが無かった部分の補完
 *  - 応募ボタン付き Flex（push メッセージ）の構築
 *  - 枠の確認コード generateSlotCode
 *  - 応募ボタンを付けない場合のテキスト送信フォールバック
 *  - 受付時間（slotTtlHours）の可変化とサーバー側クランプ
 */
import {
  clampSlotTtlHours,
  SLOT_TTL_HOURS,
  SLOT_TTL_MAX_HOURS,
  SLOT_TTL_MIN_HOURS,
} from '../src/config';
import {setLineApiForTest} from '../src/line/client';
import {
  buildClaimedFlexMessage,
  buildPostbackData,
  buildVacancyFlexMessage,
  parsePostbackData,
} from '../src/slotMessage';
import {
  generateSlotCode,
  runSendVacancyNotice,
  validateInput,
  type SendVacancyNoticeInput,
} from '../src/sendVacancyNotice';
import {createSlotIfAbsent, makeSlotId} from '../src/slots';
import {FakeFirestore} from './fakeFirestore';
import {FakeLineApi} from './fakeLineApi';

const TOKEN = 'dummy-access-token-for-test';
const SECRET = 'test-channel-secret';
const UID = 'staff-uid-001';
const U1 = 'U' + 'a'.repeat(32);
const U2 = 'U' + 'b'.repeat(32);

let db: FakeFirestore;
let line: FakeLineApi;

beforeEach(() => {
  db = new FakeFirestore();
  line = new FakeLineApi();
  setLineApiForTest(line);
});
afterEach(() => setLineApiForTest(null));

function input(
  o: Partial<SendVacancyNoticeInput> = {}
): SendVacancyNoticeInput {
  return {
    date: '2026-10-05',
    message: '【ココスタディ】本日空きが出ました。',
    recipients: [{customerId: 'c1', lineUserId: U1, childName: '山田 太郎'}],
    ...o,
  };
}

// ── generateSlotCode ───────────────────────────────────────────

describe('generateSlotCode: 枠の確認コード', () => {
  it('6桁で、紛らわしい文字(0/O/1/I/L)を含まない', () => {
    for (let i = 0; i < 300; i++) {
      const c = generateSlotCode();
      expect(c).toMatch(/^[2-9A-HJ-NP-Z]{6}$/);
    }
  });

  it('毎回異なる値になる（固定値ではない）', () => {
    const set = new Set<string>();
    for (let i = 0; i < 200; i++) set.add(generateSlotCode());
    expect(set.size).toBeGreaterThan(190);
  });
});

// ── Flex（push メッセージ）構築 ──────────────────────────────

describe('buildVacancyFlexMessage: 応募ボタン付き Flex', () => {
  const slotId = makeSlotId('2026-10-05', 'absent1');
  const msg = buildVacancyFlexMessage({
    dateKey: '2026-10-05',
    message: '本文テスト',
    slotId,
    linkCode: 'ABC234',
    expiresAt: new Date('2026-10-05T03:00:00Z'), // JST 12:00
  }) as {
    type: string;
    altText: string;
    contents: {
      body: {contents: Array<{text?: string}>};
      footer: {contents: Array<{action: {type: string; data: string}}>};
    };
  };

  it('flex 型で altText に日付が入る', () => {
    expect(msg.type).toBe('flex');
    expect(msg.altText).toContain('10月5日');
  });

  it('本文に通知文面と受付期限(JST)が載る', () => {
    const texts = msg.contents.body.contents.map((c) => c.text ?? '');
    expect(texts).toContain('本文テスト');
    expect(texts.join('\n')).toContain('12時00分までにお申し込みください');
  });

  it('ボタンは postback 1つで、data は slotId と linkCode を持つ', () => {
    const buttons = msg.contents.footer.contents;
    expect(buttons).toHaveLength(1);
    expect(buttons[0].action.type).toBe('postback');
    const parsed = parsePostbackData(buttons[0].action.data);
    expect(parsed).toEqual({
      version: 1,
      action: 'claim',
      slotId,
      linkCode: 'ABC234',
    });
  });

  it('data に customerId を含めない（改ざん前提の設計）', () => {
    const data = msg.contents.footer.contents[0].action.data;
    expect(data).not.toContain('absent1_');
    expect(JSON.parse(data)).not.toHaveProperty('customerId');
  });

  it('確定後のキャンセル用 Flex は release の postback を持つ', () => {
    const c = buildClaimedFlexMessage({
      dateKey: '2026-10-05',
      slotId,
      linkCode: 'ABC234',
    }) as {contents: {footer: {contents: Array<{action: {data: string}}>}}};
    const parsed = parsePostbackData(
      c.contents.footer.contents[0].action.data
    );
    expect(parsed?.action).toBe('release');
    expect(parsed?.slotId).toBe(slotId);
  });

  it('postback data は LINE の上限(300文字)に収まる', () => {
    const d = buildPostbackData('claim', slotId, 'ABC234');
    expect(d.length).toBeLessThanOrEqual(300);
  });
});

// ── フォールバック ─────────────────────────────────────────────

describe('応募ボタンを付けられない場合は従来のテキスト送信にフォールバック', () => {
  it('sourceAbsentCustomerId 未指定 → テキスト push・枠は作られない', async () => {
    const out = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input(),
      TOKEN,
      SECRET
    );
    expect(out.sentCount).toBe(1);
    expect(line.pushMessageCalls).toHaveLength(0);
    expect(line.pushCalls).toHaveLength(1);
    expect(line.pushCalls[0].text).toBe('【ココスタディ】本日空きが出ました。');
    expect(db.store.get('slots')?.size ?? 0).toBe(0);
  });

  it('channelSecret 未設定 → sourceAbsentCustomerId があってもテキスト push', async () => {
    const out = await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({sourceAbsentCustomerId: 'absent1'}),
      TOKEN
      // channelSecret なし
    );
    expect(out.sentCount).toBe(1);
    expect(line.pushMessageCalls).toHaveLength(0);
    expect(db.store.get('slots')?.size ?? 0).toBe(0);
  });

  it('channelSecret が空文字でもテキスト push（枠を作らない）', async () => {
    await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({sourceAbsentCustomerId: 'absent1'}),
      TOKEN,
      ''
    );
    expect(line.pushMessageCalls).toHaveLength(0);
    expect(db.store.get('slots')?.size ?? 0).toBe(0);
  });

  it('両方そろうと Flex を push し枠を作る', async () => {
    await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({sourceAbsentCustomerId: 'absent1'}),
      TOKEN,
      SECRET
    );
    expect(line.pushMessageCalls).toHaveLength(1);
    expect(db.store.get('slots')?.has('2026-10-05_absent1')).toBe(true);
  });
});

// ── 受付時間（TTL）─────────────────────────────────────────────

describe('clampSlotTtlHours', () => {
  it('未指定・数値以外・NaN・Infinity は既定値', () => {
    expect(clampSlotTtlHours(undefined)).toBe(SLOT_TTL_HOURS);
    expect(clampSlotTtlHours(null)).toBe(SLOT_TTL_HOURS);
    expect(clampSlotTtlHours('12')).toBe(SLOT_TTL_HOURS);
    expect(clampSlotTtlHours(NaN)).toBe(SLOT_TTL_HOURS);
    expect(clampSlotTtlHours(Infinity)).toBe(SLOT_TTL_HOURS);
  });
  it('範囲内はそのまま・小数は切り捨て', () => {
    expect(clampSlotTtlHours(3)).toBe(3);
    expect(clampSlotTtlHours(2.9)).toBe(2);
  });
  it('範囲外は 1〜24 に丸める', () => {
    expect(clampSlotTtlHours(0)).toBe(SLOT_TTL_MIN_HOURS);
    expect(clampSlotTtlHours(-5)).toBe(SLOT_TTL_MIN_HOURS);
    expect(clampSlotTtlHours(999)).toBe(SLOT_TTL_MAX_HOURS);
  });
});

describe('受付時間(slotTtlHours)の反映', () => {
  const T0 = new Date('2026-10-05T00:00:00Z');

  function expiresOf(): Date {
    const d = db.store.get('slots')!.get('2026-10-05_absent1')!;
    return d.expiresAt as Date;
  }

  it('createSlotIfAbsent: 未指定は既定6時間', async () => {
    await createSlotIfAbsent(db.asFirestore(), {
      slotId: '2026-10-05_absent1',
      dateKey: '2026-10-05',
      sourceAbsent: 'absent1',
      linkCode: 'ABC234',
      notifiedList: [],
      createdBy: 'vacancy_notice',
      now: T0,
    });
    expect(expiresOf().getTime() - T0.getTime()).toBe(6 * 3600 * 1000);
  });

  it('createSlotIfAbsent: 2時間指定 → 2時間後', async () => {
    await createSlotIfAbsent(db.asFirestore(), {
      slotId: '2026-10-05_absent1',
      dateKey: '2026-10-05',
      sourceAbsent: 'absent1',
      linkCode: 'ABC234',
      notifiedList: [],
      createdBy: 'vacancy_notice',
      now: T0,
      ttlHours: 2,
    });
    expect(expiresOf().getTime() - T0.getTime()).toBe(2 * 3600 * 1000);
  });

  it('createSlotIfAbsent: 範囲外(100)でも24時間に丸める', async () => {
    await createSlotIfAbsent(db.asFirestore(), {
      slotId: '2026-10-05_absent1',
      dateKey: '2026-10-05',
      sourceAbsent: 'absent1',
      linkCode: 'ABC234',
      notifiedList: [],
      createdBy: 'vacancy_notice',
      now: T0,
      ttlHours: 100,
    });
    expect(expiresOf().getTime() - T0.getTime()).toBe(24 * 3600 * 1000);
  });

  it('validateInput: slotTtlHours が通り、範囲外は丸められる', () => {
    const base = {
      date: '2026-10-05',
      message: 'm',
      recipients: [{customerId: 'c1', lineUserId: U1, childName: 'x'}],
    };
    expect(validateInput({...base, slotTtlHours: 3}).slotTtlHours).toBe(3);
    expect(validateInput({...base, slotTtlHours: 500}).slotTtlHours).toBe(24);
    expect(validateInput({...base, slotTtlHours: 0}).slotTtlHours).toBe(1);
    expect(validateInput(base).slotTtlHours).toBeUndefined();
    // 文字列などの不正型は無視（既定値に任せる）
    expect(
      validateInput({...base, slotTtlHours: '99'}).slotTtlHours
    ).toBeUndefined();
  });

  it('runSendVacancyNotice: slotTtlHours=3 で枠の期限が約3時間後', async () => {
    const before = Date.now();
    await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({sourceAbsentCustomerId: 'absent1', slotTtlHours: 3}),
      TOKEN,
      SECRET
    );
    const ex = db.store.get('slots')!.get('2026-10-05_absent1')!
      .expiresAt as Date;
    const diffH = (ex.getTime() - before) / 3600000;
    expect(diffH).toBeGreaterThan(2.99);
    expect(diffH).toBeLessThan(3.01);
  });

  it('追加送信(2回目)では最初の期限を延長しない', async () => {
    await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({sourceAbsentCustomerId: 'absent1', slotTtlHours: 2}),
      TOKEN,
      SECRET
    );
    const first = (db.store.get('slots')!.get('2026-10-05_absent1')!
      .expiresAt as Date).getTime();
    await runSendVacancyNotice(
      db.asFirestore(),
      UID,
      input({
        sourceAbsentCustomerId: 'absent1',
        slotTtlHours: 24,
        recipients: [
          {customerId: 'c2', lineUserId: U2, childName: '佐藤 花子'},
        ],
      }),
      TOKEN,
      SECRET
    );
    const second = (db.store.get('slots')!.get('2026-10-05_absent1')!
      .expiresAt as Date).getTime();
    expect(second).toBe(first);
  });
});
