/**
 * Day 15: 管理者 LINE userId への確定／キャンセル通知
 *
 * 検証の軸:
 *  - 管理者あり/なし × 確定/キャンセル の 4 パス
 *  - 送信は成立時の 1 通のみ（already_filled / 自分の再タップ / 重複 webhook では送らない）
 *  - 未設定でも確定は成功し、スキップがログに残る
 *  - 管理者への送信失敗が確定を壊さない
 *  - 生の userId がログに出ない（マスク済みのみ）
 *  - 保存先は slots ではなく slot_admin_targets（client から読める slots に生値を置かない）
 */
import * as logger from 'firebase-functions/logger';

import {FakeFirestore} from './fakeFirestore';
import {FakeLineApi} from './fakeLineApi';
import {setLineApiForTest} from '../src/line/client';
import {
  buildAdminClaimedText,
  buildAdminReleasedText,
  buildPostbackData,
  formatClockJst,
  formatDateShortJa,
} from '../src/slotMessage';
import {
  createSlotIfAbsent,
  hashLineUserId,
  loadAdminTarget,
  makeSlotId,
  saveAdminTarget,
  type ClaimResult,
  type NotifiedEntry,
} from '../src/slots';
import {
  ADMIN_NOTIFY_FALLBACK_NAME,
  handleSlotPostback,
  notifyAdmin,
} from '../src/slotPostback';
import {
  runSendVacancyNotice,
  validateInput,
} from '../src/sendVacancyNotice';

jest.mock('firebase-functions/logger', () => ({
  info: jest.fn(),
  warn: jest.fn(),
  error: jest.fn(),
  debug: jest.fn(),
  log: jest.fn(),
}));

const SECRET = 'test-channel-secret';
const DATE = '2026-10-05'; // 月曜
const ABSENT = 'absent_child';
const SLOT_ID = makeSlotId(DATE, ABSENT);
const CODE = 'CODE01';

const UID_A = 'U' + 'a'.repeat(32);
const UID_B = 'U' + 'b'.repeat(32);
const ADMIN = 'U' + '1234567890abcdef'.repeat(2);

function allLogText(): string {
  const fns = [logger.info, logger.warn, logger.error, logger.debug, logger.log];
  return fns
    .flatMap((f) => (f as jest.Mock).mock.calls)
    .map((c) => JSON.stringify(c))
    .join('\n');
}

function infoMessages(): string[] {
  return (logger.info as jest.Mock).mock.calls.map((c) => String(c[0]));
}

async function seed(
  db: FakeFirestore,
  opts: {admin?: string; withName?: boolean} = {}
): Promise<void> {
  const pairs: Array<[string, string]> = [
    ['child_a', UID_A],
    ['child_b', UID_B],
  ];
  const list: NotifiedEntry[] = pairs.map(([customerId, uid]) => {
    db.seed('line_linkage', customerId, {customerId, lineUserId: uid});
    return {
      customerId,
      lineUserIdHash: hashLineUserId(uid, SECRET),
      servedAt: new Date(),
    };
  });
  if (opts.withName !== false) {
    db.seed('notification_logs', `${DATE}_child_a`, {
      childName: '佐藤花子',
      customerId: 'child_a',
    });
  }
  await createSlotIfAbsent(db.asFirestore(), {
    slotId: SLOT_ID,
    dateKey: DATE,
    sourceAbsent: ABSENT,
    linkCode: CODE,
    notifiedList: list,
    createdBy: 'vacancy_notice',
  });
  if (opts.admin !== undefined) {
    await saveAdminTarget(db.asFirestore(), SLOT_ID, opts.admin);
  }
}

const ev = (
  action: 'claim' | 'release',
  uid: string,
  eventId: string
) => ({
  type: 'postback',
  replyToken: 'rt_' + eventId,
  webhookEventId: eventId,
  source: {userId: uid},
  postback: {data: buildPostbackData(action, SLOT_ID, CODE)},
  deliveryContext: {isRedelivery: false},
});

const adminPushes = (line: FakeLineApi) =>
  line.pushCalls.filter((c) => c.lineUserId === ADMIN);

describe('管理者通知の文面', () => {
  test('日付は「10/6（火）」形式（全角括弧）', () => {
    expect(formatDateShortJa('2026-10-06')).toBe('10/6（火）');
    expect(formatDateShortJa('2026-01-04')).toBe('1/4（日）');
  });

  test('時刻は JST の HH:mm（UTC+9）', () => {
    expect(formatClockJst(new Date('2026-10-06T01:23:00Z'))).toBe('10:23');
    // 日付またぎ: UTC 17:05 → JST 翌 2:05
    expect(formatClockJst(new Date('2026-10-05T17:05:00Z'))).toBe('2:05');
  });

  test('確定文面が指定どおり', () => {
    const t = buildAdminClaimedText(
      '2026-10-06',
      '佐藤花子',
      new Date('2026-10-06T01:23:00Z')
    );
    expect(t).toBe('【確定】10/6（火）佐藤花子さんが空き枠に応募しました（10:23）');
  });

  test('キャンセル文面は確定と区別できる', () => {
    const t = buildAdminReleasedText(
      '2026-10-06',
      '佐藤花子',
      new Date('2026-10-06T01:23:00Z')
    );
    expect(t.startsWith('【キャンセル】10/6（火）佐藤花子さん')).toBe(true);
    expect(t).toContain('（10:23）');
    expect(t).not.toContain('【確定】');
  });
});

describe('handleSlotPostback × 管理者通知', () => {
  let db: FakeFirestore;
  let line: FakeLineApi;

  beforeEach(() => {
    jest.clearAllMocks();
    db = new FakeFirestore();
    line = new FakeLineApi();
    setLineApiForTest(line);
  });
  afterEach(() => setLineApiForTest(null));

  test('【管理者あり×確定】管理者へ指定文面が 1 通届く', async () => {
    await seed(db, {admin: ADMIN});
    const r = await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    expect(r.outcome).toBe('claimed');
    const pushes = adminPushes(line);
    expect(pushes).toHaveLength(1);
    expect(pushes[0].text).toMatch(
      /^【確定】10\/5（月）佐藤花子さんが空き枠に応募しました（\d{1,2}:\d{2}）$/
    );
    // 管理者以外に管理者向け文面が漏れない
    expect(
      line.pushCalls.filter(
        (c) => c.lineUserId !== ADMIN && c.text.includes('空き枠に応募しました')
      )
    ).toHaveLength(0);
  });

  test('【管理者なし×確定】スキップされ、確定は成功しログが残る', async () => {
    await seed(db); // 管理者未設定
    const r = await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    expect(r.outcome).toBe('claimed');
    expect(db.get('slots', SLOT_ID)!.status).toBe('filled');
    expect(adminPushes(line)).toHaveLength(0);
    expect(
      infoMessages().some((m) =>
        m.includes('admin notify skipped: no adminLineUserId')
      )
    ).toBe(true);
    // 敗者通知・確定者への Flex は従来どおり
    expect(r.losersNotified).toBe(1);
    expect(line.pushMessageCalls).toHaveLength(1);
  });

  test('【管理者あり×キャンセル】取り消しが管理者へ 1 通届く', async () => {
    await seed(db, {admin: ADMIN});
    await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    line.pushCalls.length = 0;
    const r = await handleSlotPostback(
      db.asFirestore(), 'token', ev('release', UID_A, 'e2'), SECRET
    );
    expect(r.outcome).toBe('released');
    const pushes = adminPushes(line);
    expect(pushes).toHaveLength(1);
    expect(pushes[0].text).toMatch(
      /^【キャンセル】10\/5（月）佐藤花子さんが/
    );
    expect(line.pushCalls).toHaveLength(1); // 他へは送っていない
  });

  test('【管理者なし×キャンセル】スキップされ、取り消しは成功する', async () => {
    await seed(db);
    await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    jest.clearAllMocks();
    const r = await handleSlotPostback(
      db.asFirestore(), 'token', ev('release', UID_A, 'e2'), SECRET
    );
    expect(r.outcome).toBe('released');
    expect(db.get('slots', SLOT_ID)!.status).toBe('released');
    expect(adminPushes(line)).toHaveLength(0);
    expect(
      infoMessages().some((m) =>
        m.includes('admin notify skipped: no adminLineUserId')
      )
    ).toBe(true);
  });

  test('負け（already_filled）・自分の再タップ・重複 webhook では管理者へ送らない', async () => {
    await seed(db, {admin: ADMIN});
    await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    expect(adminPushes(line)).toHaveLength(1);

    // 敗者の応募
    const lost = await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_B, 'e2'), SECRET
    );
    expect(lost.outcome).toBe('already_filled');
    // 自分の再タップ（別 webhookEventId）
    const again = await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e3'), SECRET
    );
    expect(again.outcome).toBe('already_claimed_by_self');
    // LINE の再送（同じ webhookEventId）
    const dup = await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    expect(dup.outcome).toBe('duplicate_webhook');

    expect(adminPushes(line)).toHaveLength(1); // 増えていない
  });

  test('他人の確定は取り消せず、管理者へも送られない（release_denied）', async () => {
    await seed(db, {admin: ADMIN});
    await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    const r = await handleSlotPostback(
      db.asFirestore(), 'token', ev('release', UID_B, 'e2'), SECRET
    );
    expect(r.outcome).toBe('release_denied');
    expect(adminPushes(line)).toHaveLength(1);
  });

  test('管理者への push が失敗しても確定は成功する', async () => {
    await seed(db, {admin: ADMIN});
    line.failUserIds.add(ADMIN);
    const r = await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    expect(r.outcome).toBe('claimed');
    expect(db.get('slots', SLOT_ID)!.status).toBe('filled');
    expect(r.losersNotified).toBe(1);
  });

  test('管理者への push が例外を投げても確定は成功する', async () => {
    await seed(db, {admin: ADMIN});
    const origPush = line.pushText.bind(line);
    line.pushText = async (t, uid, text) => {
      if (uid === ADMIN) throw new Error('network down');
      return origPush(t, uid, text);
    };
    const r = await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    expect(r.outcome).toBe('claimed');
    expect(db.get('slots', SLOT_ID)!.status).toBe('filled');
  });

  test('氏名が引けないときは既定名で送る（通知自体は落とさない）', async () => {
    await seed(db, {admin: ADMIN, withName: false});
    await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    const pushes = adminPushes(line);
    expect(pushes).toHaveLength(1);
    expect(pushes[0].text).toContain(`${ADMIN_NOTIFY_FALLBACK_NAME}さんが`);
  });

  test('ログに管理者・応募者の生 userId が出ない（マスクのみ）', async () => {
    await seed(db, {admin: ADMIN});
    await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    await handleSlotPostback(
      db.asFirestore(), 'token', ev('release', UID_A, 'e2'), SECRET
    );
    const logs = allLogText();
    expect(logs).not.toContain(ADMIN);
    expect(logs).not.toContain(UID_A);
    expect(logs).not.toContain(UID_B);
    // マスク形（U****末尾4桁）は出ている
    expect(logs).toContain('U****' + ADMIN.slice(-4));
  });

  test('失敗ログにも管理者の生 userId が出ない', async () => {
    await seed(db, {admin: ADMIN});
    const origPush = line.pushText.bind(line);
    line.pushText = async (t, uid, text) => {
      if (uid === ADMIN) throw new Error('boom');
      return origPush(t, uid, text);
    };
    await handleSlotPostback(
      db.asFirestore(), 'token', ev('claim', UID_A, 'e1'), SECRET
    );
    expect(allLogText()).not.toContain(ADMIN);
  });
});

describe('notifyAdmin 単体（時刻の確定値）', () => {
  let db: FakeFirestore;
  let line: FakeLineApi;
  beforeEach(() => {
    jest.clearAllMocks();
    db = new FakeFirestore();
    line = new FakeLineApi();
    setLineApiForTest(line);
  });
  afterEach(() => setLineApiForTest(null));

  test('result.at（JST 10:23）が文面に使われる', async () => {
    await seed(db, {admin: ADMIN});
    const result: ClaimResult = {
      outcome: 'claimed',
      slotId: SLOT_ID,
      claimedCustomerId: 'child_a',
      losers: [],
      at: new Date('2026-10-05T01:23:00Z'),
    };
    const ok = await notifyAdmin(
      db.asFirestore(), 'token', 'claimed', result, DATE, 'child_a'
    );
    expect(ok).toBe(true);
    expect(adminPushes(line)[0].text).toBe(
      '【確定】10/5（月）佐藤花子さんが空き枠に応募しました（10:23）'
    );
  });
});

describe('管理者通知先の保存（sendVacancyNotice 経由）', () => {
  let db: FakeFirestore;
  let line: FakeLineApi;
  const recipients = [
    {customerId: 'child_a', lineUserId: UID_A, childName: '佐藤花子'},
  ];

  beforeEach(() => {
    jest.clearAllMocks();
    db = new FakeFirestore();
    line = new FakeLineApi();
    setLineApiForTest(line);
  });
  afterEach(() => setLineApiForTest(null));

  const run = (extra: Record<string, unknown> = {}) =>
    runSendVacancyNotice(
      db.asFirestore(),
      'staff_uid',
      validateInput({
        date: DATE,
        recipients,
        message: '空きが出ました',
        sourceAbsentCustomerId: ABSENT,
        ...extra,
      }),
      'token',
      SECRET
    );

  test('管理者 userId は slot_admin_targets に保存され、slots には入らない', async () => {
    await run({adminLineUserId: ADMIN});
    expect(await loadAdminTarget(db.asFirestore(), SLOT_ID)).toBe(ADMIN);
    // client から読める slots に生値を置かない
    expect(JSON.stringify(db.get('slots', SLOT_ID))).not.toContain(ADMIN);
    // 通知先の送信自体は従来どおり（管理者へは送らない）
    expect(adminPushes(line)).toHaveLength(0);
  });

  test('管理者を外して再送すると古い宛先が削除される', async () => {
    await run({adminLineUserId: ADMIN});
    // 追加送信（別の宛先）で管理者未設定
    await runSendVacancyNotice(
      db.asFirestore(),
      'staff_uid',
      validateInput({
        date: DATE,
        recipients: [
          {customerId: 'child_b', lineUserId: UID_B, childName: '鈴木一郎'},
        ],
        message: '空きが出ました',
        sourceAbsentCustomerId: ABSENT,
      }),
      'token',
      SECRET
    );
    expect(await loadAdminTarget(db.asFirestore(), SLOT_ID)).toBeNull();
  });

  test('保存後のログに管理者の生 userId が出ない', async () => {
    await run({adminLineUserId: ADMIN});
    expect(allLogText()).not.toContain(ADMIN);
  });

  test('エンドツーエンド: 送信→応募→管理者へ到達', async () => {
    db.seed('line_linkage', 'child_a', {customerId: 'child_a', lineUserId: UID_A});
    await run({adminLineUserId: ADMIN});
    const code = db.get('slots', SLOT_ID)!.linkCode as string;
    const r = await handleSlotPostback(
      db.asFirestore(),
      'token',
      {
        type: 'postback',
        replyToken: 'rt',
        webhookEventId: 'e1',
        source: {userId: UID_A},
        postback: {data: buildPostbackData('claim', SLOT_ID, code)},
      },
      SECRET
    );
    expect(r.outcome).toBe('claimed');
    expect(adminPushes(line)).toHaveLength(1);
    expect(adminPushes(line)[0].text).toContain('佐藤花子さん');
  });
});

describe('validateInput: adminLineUserId', () => {
  const base = {
    date: DATE,
    recipients: [{customerId: 'c', lineUserId: UID_A, childName: 'x'}],
    message: 'm',
  };

  test('正しい形式は通り、前後の空白は除かれる', () => {
    expect(
      validateInput({...base, adminLineUserId: `  ${ADMIN} `}).adminLineUserId
    ).toBe(ADMIN);
  });

  test.each([
    ['空文字', ''],
    ['短い', 'Uabc'],
    ['U が無い', '1234567890abcdef1234567890abcdef12'],
    ['非 hex', 'U' + 'z'.repeat(32)],
    ['数値', 12345],
    ['null', null],
    ['オブジェクト', {a: 1}],
  ])('不正値（%s）は捨てられ、送信は失敗しない', (_n, v) => {
    const input = validateInput({...base, adminLineUserId: v});
    expect(input.adminLineUserId).toBeUndefined();
  });

  test('未指定は undefined（後方互換）', () => {
    expect(validateInput(base).adminLineUserId).toBeUndefined();
  });
});
