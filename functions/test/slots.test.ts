/**
 * Day 13: 先着応募（slots）の単体テスト
 *
 * 最重要の検証は「**1 つの枠を 2 人が取れない**」こと。
 * 事業所にとって二重確定は実害（定員超過・送迎手配の破綻）に直結する。
 */
import {FakeFirestore} from './fakeFirestore';
import {FakeLineApi} from './fakeLineApi';
import {setLineApiForTest} from '../src/line/client';
import {
  buildPostbackData,
  parsePostbackData,
  formatDateJa,
  formatTimeJst,
  POSTBACK_DATA_MAX_LENGTH,
} from '../src/slotMessage';
import {
  claimSlot,
  createSlotIfAbsent,
  hashLineUserId,
  makeSlotId,
  releaseSlot,
  reserveWebhookEvent,
  resolveCustomerIdByLineUserId,
  type NotifiedEntry,
} from '../src/slots';
import {handleSlotPostback, MSG_CLAIM_WON, MSG_CLAIM_LOST} from '../src/slotPostback';

const SECRET = 'test-channel-secret';
const DATE = '2026-10-05';
const ABSENT = 'absent_child';
const SLOT_ID = makeSlotId(DATE, ABSENT);

const UID_A = 'U' + 'a'.repeat(32);
const UID_B = 'U' + 'b'.repeat(32);
const UID_C = 'U' + 'c'.repeat(32);

function notified(db: FakeFirestore, pairs: Array<[string, string]>): NotifiedEntry[] {
  // line_linkage も併せて seed する（敗者通知の逆引きに必要）
  for (const [customerId, uid] of pairs) {
    db.seed('line_linkage', customerId, {customerId, lineUserId: uid});
  }
  return pairs.map(([customerId, uid]) => ({
    customerId,
    lineUserIdHash: hashLineUserId(uid, SECRET),
    servedAt: new Date(),
  }));
}

async function seedOpenSlot(
  db: FakeFirestore,
  code: string,
  pairs: Array<[string, string]>
): Promise<void> {
  await createSlotIfAbsent(db.asFirestore(), {
    slotId: SLOT_ID,
    dateKey: DATE,
    sourceAbsent: ABSENT,
    linkCode: code,
    notifiedList: notified(db, pairs),
    createdBy: 'vacancy_notice',
  });
}

describe('postback data の組み立てとパース', () => {
  test('組み立てたものをパースすると元に戻る', () => {
    const raw = buildPostbackData('claim', SLOT_ID, 'AB12CD');
    const p = parsePostbackData(raw);
    expect(p).not.toBeNull();
    expect(p!.action).toBe('claim');
    expect(p!.slotId).toBe(SLOT_ID);
    expect(p!.linkCode).toBe('AB12CD');
  });

  test('LINE の上限 300 文字に収まる', () => {
    const raw = buildPostbackData('claim', SLOT_ID, 'AB12CD');
    expect(raw.length).toBeLessThanOrEqual(POSTBACK_DATA_MAX_LENGTH);
  });

  test('不正な JSON / 未知バージョン / 空は null', () => {
    expect(parsePostbackData('not json')).toBeNull();
    expect(parsePostbackData('')).toBeNull();
    expect(parsePostbackData(undefined)).toBeNull();
    expect(parsePostbackData(JSON.stringify({v: 99, a: 'claim', s: 'x', c: 'y'}))).toBeNull();
  });

  test('slotId にパス区切りが混ざるものは拒否する（パス注入の予防）', () => {
    expect(
      parsePostbackData(JSON.stringify({v: 1, a: 'claim', s: '../other', c: 'x'}))
    ).toBeNull();
    expect(
      parsePostbackData(JSON.stringify({v: 1, a: 'claim', s: 'a/b', c: 'x'}))
    ).toBeNull();
  });

  test('300 文字を超える data は拒否する', () => {
    const long = JSON.stringify({v: 1, a: 'claim', s: 'x'.repeat(400), c: 'y'});
    expect(parsePostbackData(long)).toBeNull();
  });

  test('日付・時刻の表示（JST 変換）', () => {
    expect(formatDateJa('2026-10-05')).toBe('10月5日(月)');
    // UTC 09:00 → JST 18:00
    expect(formatTimeJst(new Date(Date.UTC(2026, 9, 5, 9, 30)))).toBe('18時30分');
    // 日付をまたぐケース（UTC 17:00 → JST 翌 2:00）
    expect(formatTimeJst(new Date(Date.UTC(2026, 9, 5, 17, 5)))).toBe('2時05分');
  });
});

describe('claimSlot: 先着1名の確定', () => {
  let db: FakeFirestore;

  beforeEach(async () => {
    db = new FakeFirestore();
    await seedOpenSlot(db, 'CODE01', [
      ['child_a', UID_A],
      ['child_b', UID_B],
    ]);
  });

  test('通知を受けた保護者は確定できる', async () => {
    const r = await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });
    expect(r.outcome).toBe('claimed');
    expect(db.get('slots', SLOT_ID)!.status).toBe('filled');
  });

  test('確定後に別の保護者が押しても取れない（先着1名）', async () => {
    await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });
    const second = await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_b',
      lineUserIdHash: hashLineUserId(UID_B, SECRET),
      linkCode: 'CODE01',
    });
    expect(second.outcome).toBe('already_filled');
    // 確定者は最初の人のまま
    const claimed = db.get('slots', SLOT_ID)!.claimedBy as Record<string, unknown>;
    expect(claimed.customerId).toBe('child_a');
  });

  test('【最重要】同時タップでも二重確定しない', async () => {
    // A の transaction が「読み取り後・書き込み前」の瞬間に
    // B の確定を割り込ませる（実運用の同時タップを再現）
    db.onTransactionRead = async () => {
      await claimSlot(db.asFirestore(), {
        slotId: SLOT_ID,
        customerId: 'child_b',
        lineUserIdHash: hashLineUserId(UID_B, SECRET),
        linkCode: 'CODE01',
      });
    };

    await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });

    // どちらか 1 人だけが確定していること（capacity=1 を超えない）
    const slot = db.get('slots', SLOT_ID)!;
    expect(slot.status).toBe('filled');
    const claimed = slot.claimedBy as Record<string, unknown>;
    expect(['child_a', 'child_b']).toContain(claimed.customerId);

    // 確定者が 1 名であることを後続の claim で確認する
    const third = await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId:
        claimed.customerId === 'child_a' ? 'child_b' : 'child_a',
      lineUserIdHash: hashLineUserId(UID_C, SECRET),
      linkCode: 'CODE01',
    });
    expect(third.outcome).toBe('already_filled');
  });

  test('同じ人が再タップしても二重確定にならない', async () => {
    await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });
    const again = await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });
    expect(again.outcome).toBe('already_claimed_by_self');
  });

  test('通知を受けていない人は応募できない', async () => {
    const r = await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'stranger',
      lineUserIdHash: hashLineUserId(UID_C, SECRET),
      linkCode: 'CODE01',
    });
    expect(r.outcome).toBe('not_notified');
    expect(db.get('slots', SLOT_ID)!.status).toBe('open');
  });

  test('確認コードが違えば確定しない（古い通知の使い回し防止）', async () => {
    const r = await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'WRONG1',
    });
    expect(r.outcome).toBe('invalid_code');
    expect(db.get('slots', SLOT_ID)!.status).toBe('open');
  });

  test('期限切れの枠は確定しない', async () => {
    const slot = db.get('slots', SLOT_ID)!;
    slot.expiresAt = new Date(Date.now() - 1000);
    const r = await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });
    expect(r.outcome).toBe('expired');
    expect(db.get('slots', SLOT_ID)!.status).toBe('open');
  });

  test('存在しない枠は slot_not_found', async () => {
    const r = await claimSlot(db.asFirestore(), {
      slotId: '2026-01-01_nobody',
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });
    expect(r.outcome).toBe('slot_not_found');
  });

  test('確定時に敗者リストが返る（他の通知先）', async () => {
    const r = await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });
    expect(r.losers.map((l) => l.customerId)).toEqual(['child_b']);
  });
});

describe('releaseSlot: キャンセル', () => {
  let db: FakeFirestore;

  beforeEach(async () => {
    db = new FakeFirestore();
    await seedOpenSlot(db, 'CODE01', [
      ['child_a', UID_A],
      ['child_b', UID_B],
    ]);
    await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });
  });

  test('確定した本人はキャンセルできる', async () => {
    const r = await releaseSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
    });
    expect(r.outcome).toBe('released');
    expect(db.get('slots', SLOT_ID)!.status).toBe('released');
    expect(db.get('slots', SLOT_ID)!.claimedBy).toBeNull();
  });

  test('【重要】他人の確定はキャンセルできない', async () => {
    const r = await releaseSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_b',
    });
    expect(r.outcome).toBe('release_denied');
    // 確定は維持される
    expect(db.get('slots', SLOT_ID)!.status).toBe('filled');
  });

  test('キャンセル後は別の保護者が確定できる（枠を死なせない）', async () => {
    await releaseSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
    });
    const r = await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_b',
      lineUserIdHash: hashLineUserId(UID_B, SECRET),
      linkCode: 'CODE01',
    });
    expect(r.outcome).toBe('claimed');
  });
});

describe('webhook の冪等（LINE の再送対策）', () => {
  test('同じ webhookEventId は 2 回目以降 false', async () => {
    const db = new FakeFirestore();
    const first = await reserveWebhookEvent(db.asFirestore(), 'evt_1', 'postback');
    const second = await reserveWebhookEvent(db.asFirestore(), 'evt_1', 'postback');
    expect(first).toBe(true);
    expect(second).toBe(false);
  });

  test('webhookEventId が無い場合は処理を落とさない（正当な応募を失わない）', async () => {
    const db = new FakeFirestore();
    expect(await reserveWebhookEvent(db.asFirestore(), '', 'postback')).toBe(true);
  });
});

describe('handleSlotPostback: webhook からの一連の流れ', () => {
  let db: FakeFirestore;
  let line: FakeLineApi;

  beforeEach(async () => {
    db = new FakeFirestore();
    line = new FakeLineApi();
    setLineApiForTest(line);
    await seedOpenSlot(db, 'CODE01', [
      ['child_a', UID_A],
      ['child_b', UID_B],
    ]);
  });

  afterEach(() => setLineApiForTest(null));

  const postbackEvent = (uid: string, code = 'CODE01', eventId = 'e1') => ({
    type: 'postback',
    replyToken: 'rt_' + uid.slice(-3),
    webhookEventId: eventId,
    source: {userId: uid},
    postback: {data: buildPostbackData('claim', SLOT_ID, code)},
    deliveryContext: {isRedelivery: false},
  });

  test('勝者には確定、敗者には「埋まりました」が届く', async () => {
    const r = await handleSlotPostback(
      db.asFirestore(),
      'token',
      postbackEvent(UID_A),
      SECRET
    );
    expect(r.outcome).toBe('claimed');
    expect(r.reply).toBe(MSG_CLAIM_WON);
    // 敗者 child_b に push が飛ぶ
    expect(r.losersNotified).toBe(1);
    expect(line.pushCalls.some((c) => c.lineUserId === UID_B)).toBe(true);
  });

  test('2 人目には「埋まりました」と返す', async () => {
    await handleSlotPostback(db.asFirestore(), 'token', postbackEvent(UID_A, 'CODE01', 'e1'), SECRET);
    const r = await handleSlotPostback(
      db.asFirestore(),
      'token',
      postbackEvent(UID_B, 'CODE01', 'e2'),
      SECRET
    );
    expect(r.outcome).toBe('already_filled');
    expect(r.reply).toBe(MSG_CLAIM_LOST);
  });

  test('【重要】同じイベントが再送されても二重処理しない', async () => {
    await handleSlotPostback(db.asFirestore(), 'token', postbackEvent(UID_A, 'CODE01', 'same'), SECRET);
    const before = line.pushCalls.length;

    const again = await handleSlotPostback(
      db.asFirestore(),
      'token',
      postbackEvent(UID_A, 'CODE01', 'same'),
      SECRET
    );
    expect(again.outcome).toBe('duplicate_webhook');
    // 追加の送信が発生しない
    expect(line.pushCalls.length).toBe(before);
  });

  test('LINE 未連携のユーザーには連携を案内する', async () => {
    const r = await handleSlotPostback(
      db.asFirestore(),
      'token',
      postbackEvent(UID_C),
      SECRET
    );
    expect(r.outcome).toBe('no_linkage');
  });

  test('改ざんされた data（不正 JSON）は確定しない', async () => {
    const r = await handleSlotPostback(
      db.asFirestore(),
      'token',
      {
        type: 'postback',
        replyToken: 'rt',
        webhookEventId: 'e9',
        source: {userId: UID_A},
        postback: {data: 'tampered'},
      },
      SECRET
    );
    expect(r.outcome).toBe('invalid_data');
    expect(db.get('slots', SLOT_ID)!.status).toBe('open');
  });

  test('【重要】data の slotId を他人の枠に差し替えても取れない', async () => {
    // 別の枠を用意（child_c だけに通知済み）
    const otherSlot = makeSlotId(DATE, 'other_absent');
    db.seed('line_linkage', 'child_c', {customerId: 'child_c', lineUserId: UID_C});
    await createSlotIfAbsent(db.asFirestore(), {
      slotId: otherSlot,
      dateKey: DATE,
      sourceAbsent: 'other_absent',
      linkCode: 'CODE02',
      notifiedList: [
        {
          customerId: 'child_c',
          lineUserIdHash: hashLineUserId(UID_C, SECRET),
          servedAt: new Date(),
        },
      ],
      createdBy: 'vacancy_notice',
    });

    // child_a（通知対象外）が他人の枠を狙う
    const r = await handleSlotPostback(
      db.asFirestore(),
      'token',
      {
        type: 'postback',
        replyToken: 'rt',
        webhookEventId: 'e10',
        source: {userId: UID_A},
        postback: {data: buildPostbackData('claim', otherSlot, 'CODE02')},
      },
      SECRET
    );
    expect(r.outcome).toBe('not_notified');
    expect(db.get('slots', otherSlot)!.status).toBe('open');
  });

  test('監査ログが残る', async () => {
    await handleSlotPostback(db.asFirestore(), 'token', postbackEvent(UID_A), SECRET);
    const audits = db.docs('slot_audit');
    expect(Object.keys(audits).length).toBeGreaterThan(0);
    const entry = Object.values(audits)[0];
    expect(entry.action).toBe('claim');
    expect(entry.after).toBe('claimed');
  });
});

describe('line_linkage の逆引き', () => {
  test('lineUserId から customerId を引ける', async () => {
    const db = new FakeFirestore();
    db.seed('line_linkage', 'child_a', {customerId: 'child_a', lineUserId: UID_A});
    const id = await resolveCustomerIdByLineUserId(db.asFirestore(), UID_A);
    expect(id).toBe('child_a');
  });

  test('未連携なら null', async () => {
    const db = new FakeFirestore();
    expect(await resolveCustomerIdByLineUserId(db.asFirestore(), UID_A)).toBeNull();
  });
});

describe('createSlotIfAbsent: 再通知で確定済みの枠を壊さない', () => {
  test('既存の枠は作り直さない', async () => {
    const db = new FakeFirestore();
    await seedOpenSlot(db, 'CODE01', [['child_a', UID_A]]);
    await claimSlot(db.asFirestore(), {
      slotId: SLOT_ID,
      customerId: 'child_a',
      lineUserIdHash: hashLineUserId(UID_A, SECRET),
      linkCode: 'CODE01',
    });

    const created = await createSlotIfAbsent(db.asFirestore(), {
      slotId: SLOT_ID,
      dateKey: DATE,
      sourceAbsent: ABSENT,
      linkCode: 'CODE99',
      notifiedList: [],
      createdBy: 'vacancy_notice',
    });

    expect(created).toBe(false);
    // 確定が維持されている
    expect(db.get('slots', SLOT_ID)!.status).toBe('filled');
  });
});
