/**
 * 空き枠の確定・取り消しを、その日の予定（週間利用計画・出席）に反映する
 *
 *  - 確定で予定に「追加」として入る（同じ transaction。ふだんの時間。LINE の応募の印）
 *  - 取り消しで外れる。入室済みは外れない（取り消された印を残す）
 *  - すでに予定に入っている児童は二重に入らない
 *  - 先着に負けた人・受付時間を過ぎた人は入らない
 *  - 枠の事業所に在籍していなければ確定しない（案内を送っていない家庭と同じ返信）
 *  - 事業所が書かれていない古い枠は、確定の印だけで予定に入らない
 *  - 通知を送るとき、事業所は送った職員の所属から決める（入力の値は使わない）
 */
import type {CallableRequest} from 'firebase-functions/v2/https';

import {FakeFirestore} from './fakeFirestore';
import {FakeLineApi} from './fakeLineApi';
import {setLineApiForTest} from '../src/line/client';
import {
  claimSlot,
  createSlotIfAbsent,
  hashLineUserId,
  makeSlotId,
  releaseSlot,
} from '../src/slots';
import {
  todayKeyJst,
  usualTimes,
  weekKeyOf,
  LINE_CLAIM_STAFF_NAME,
} from '../src/slotSchedule';
import {
  handleSlotPostback,
  MSG_CLAIM_NOT_NOTIFIED,
  MSG_CLAIM_WON,
  MSG_RELEASED,
} from '../src/slotPostback';
import {buildPostbackData} from '../src/slotMessage';
import {handleSendVacancyNotice} from '../src/sendVacancyNotice';

const SECRET = 'test-channel-secret';
const FAC = 'fac-1';
const OTHER_FAC = 'fac-2';
const CODE = 'AB12CD';
const UID_A = 'U' + 'a'.repeat(32);
const UID_B = 'U' + 'b'.repeat(32);

// 2026-12-01（火）の 10:00（日本時間）を「今」にする
const DATE = '2026-12-01';
const NOW = new Date('2026-12-01T01:00:00Z');
const WEEK = '2026-W49';
const ABSENT = 'c-absent';
const SLOT_ID = makeSlotId(DATE, ABSENT);

const col = (fid: string, name: string) => `facilities/${fid}/${name}`;
const entryOf = (db: FakeFirestore, cid: string, date = DATE, fid = FAC) =>
  db.get(col(fid, 'scheduleEntries'), `${date}_${cid}`);
const attOf = (db: FakeFirestore, cid: string, date = DATE, fid = FAC) =>
  db.get(col(fid, 'attendance'), `${date}_${cid}`);

function seedCustomer(
  db: FakeFirestore,
  id: string,
  opts: {isActive?: boolean; days?: number[]; fid?: string} = {}
): void {
  db.seed(col(opts.fid ?? FAC, 'customers'), id, {
    name: `架空 ${id}`,
    isActive: opts.isActive ?? true,
    regularDays: opts.days ?? [],
  });
}

function seedEntry(
  db: FakeFirestore,
  cid: string,
  date: string,
  status: string,
  times: [string | null, string | null] = [null, null]
): void {
  db.seed(col(FAC, 'scheduleEntries'), `${date}_${cid}`, {
    date,
    weekKey: weekKeyOf(date),
    customerId: cid,
    customerName: `架空 ${cid}`,
    status,
    plannedStartTime: times[0],
    plannedEndTime: times[1],
    transportLocationIndex: null,
    note: null,
  });
}

/** 週の目印・欠席した児童の予定・応募する 2 人（a1・b1）を置く */
async function setUp(
  db: FakeFirestore,
  opts: {facilityId?: string | null; now?: Date} = {}
): Promise<void> {
  db.seed(col(FAC, 'scheduleWeeks'), WEEK, {
    weekKey: WEEK,
    weekStartDate: '2026-11-30',
    note: null,
  });
  seedCustomer(db, ABSENT, {days: [2]});
  seedEntry(db, ABSENT, DATE, 'planned', ['10:00', '16:00']);
  seedCustomer(db, 'a1', {days: [3]});
  seedCustomer(db, 'b1', {days: [4]});
  // a1 のふだんの時間（同じ週の水・木は 14:00〜17:00、金は 13:00〜17:00）
  seedEntry(db, 'a1', '2026-12-02', 'planned', ['14:00', '17:00']);
  seedEntry(db, 'a1', '2026-12-03', 'additional', ['14:00', '17:00']);
  seedEntry(db, 'a1', '2026-12-04', 'planned', ['13:00', '17:00']);
  for (const [cid, uid] of [
    ['a1', UID_A],
    ['b1', UID_B],
  ]) {
    db.seed('line_linkage', cid, {customerId: cid, lineUserId: uid});
  }
  await createSlotIfAbsent(db.asFirestore(), {
    slotId: SLOT_ID,
    dateKey: DATE,
    sourceAbsent: ABSENT,
    linkCode: CODE,
    notifiedList: [
      {customerId: 'a1', lineUserIdHash: hashLineUserId(UID_A, SECRET), servedAt: NOW},
      {customerId: 'b1', lineUserIdHash: hashLineUserId(UID_B, SECRET), servedAt: NOW},
    ],
    createdBy: 'vacancy_notice',
    now: opts.now ?? NOW,
    ...(opts.facilityId === null ? {} : {facilityId: opts.facilityId ?? FAC}),
  });
}

const claim = (db: FakeFirestore, cid: string, now = NOW) =>
  claimSlot(db.asFirestore(), {
    slotId: SLOT_ID,
    customerId: cid,
    lineUserIdHash: hashLineUserId(cid === 'a1' ? UID_A : UID_B, SECRET),
    linkCode: CODE,
    now,
  });

const release = (db: FakeFirestore, cid: string, now = NOW) =>
  releaseSlot(db.asFirestore(), {slotId: SLOT_ID, customerId: cid, now});

let db: FakeFirestore;
beforeEach(() => {
  db = new FakeFirestore();
});

describe('週のキー・ふだんの時間（アプリと同じ決め方）', () => {
  test('ISO 8601 の週（年末年始を含む）', () => {
    expect(weekKeyOf('2026-12-01')).toBe('2026-W49');
    expect(weekKeyOf('2026-01-01')).toBe('2026-W01');
    expect(weekKeyOf('2025-12-29')).toBe('2026-W01');
    expect(weekKeyOf('2026-12-31')).toBe('2026-W53');
    expect(weekKeyOf('2027-01-03')).toBe('2026-W53');
    expect(weekKeyOf('2027-01-04')).toBe('2027-W01');
    expect(weekKeyOf('2019-12-30')).toBe('2020-W01');
    expect(weekKeyOf('bad')).toBeNull();
  });

  test('日本時間の今日', () => {
    expect(todayKeyJst(new Date('2026-11-30T15:00:00Z'))).toBe('2026-12-01');
    expect(todayKeyJst(new Date('2026-11-30T14:59:00Z'))).toBe('2026-11-30');
  });

  test('同じ週のほかの日で一番多い時間。無ければ空', () => {
    const es = [
      {customerId: 'a1', date: '2026-12-02', plannedStartTime: '14:00', plannedEndTime: '17:00'},
      {customerId: 'a1', date: '2026-12-03', plannedStartTime: '14:00', plannedEndTime: '17:00'},
      {customerId: 'a1', date: '2026-12-04', plannedStartTime: '13:00', plannedEndTime: '17:00'},
      {customerId: 'x', date: '2026-12-02', plannedStartTime: '09:00', plannedEndTime: '12:00'},
    ];
    expect(usualTimes(es, 'a1', DATE)).toEqual({start: '14:00', end: '17:00'});
    expect(usualTimes(es, 'b1', DATE)).toEqual({start: null, end: null});
  });
});

describe('確定で予定に入る', () => {
  test('週間利用計画に「追加」で入り、今日なら出席の予定もできる（ふだんの時間・印・記録）', async () => {
    await setUp(db);
    const r = await claim(db, 'a1');
    expect(r.outcome).toBe('claimed');
    expect(r.schedule).toBe('added');
    expect(db.get('slots', SLOT_ID)!.status).toBe('filled');
    const e = entryOf(db, 'a1')!;
    expect(e.status).toBe('additional');
    expect(e.weekKey).toBe(WEEK);
    expect(e.customerName).toBe('架空 a1');
    expect([e.plannedStartTime, e.plannedEndTime]).toEqual(['14:00', '17:00']);
    expect(e.updatedByStaffName).toBe(LINE_CLAIM_STAFF_NAME);
    expect(e.updatedByStaffId).toBeNull();
    const mark = e.lineClaim as Record<string, unknown>;
    expect(mark.slotId).toBe(SLOT_ID);
    expect(mark.customerId).toBe('a1');
    expect(mark.claimedAt).toEqual(NOW);
    const a = attOf(db, 'a1')!;
    expect(a.status).toBe('scheduled');
    // 14:00 日本時間 = 05:00 UTC
    expect(a.plannedStartTime).toEqual(new Date('2026-12-01T05:00:00Z'));
    expect((a.lineClaim as Record<string, unknown>).slotId).toBe(SLOT_ID);
  });

  test('ふだんの時間が決まっていなければ空のまま', async () => {
    await setUp(db);
    const r = await claim(db, 'b1');
    expect(r.schedule).toBe('added');
    const e = entryOf(db, 'b1')!;
    expect([e.plannedStartTime, e.plannedEndTime]).toEqual([null, null]);
    expect(attOf(db, 'b1')!.plannedStartTime).toBeNull();
  });

  test('明日以降の日は週間利用計画だけに入る（出席の予定はその日にアプリが作る）', async () => {
    await setUp(db, {now: new Date('2026-11-30T01:00:00Z')});
    const r = await claim(db, 'a1', new Date('2026-11-30T01:00:00Z'));
    expect(r.schedule).toBe('added');
    expect(entryOf(db, 'a1')!.status).toBe('additional');
    expect(attOf(db, 'a1')).toBeUndefined();
  });

  test('週がまだ無ければ、アプリと同じく利用曜日から週を作ってから入れる', async () => {
    await setUp(db);
    db.store.delete(col(FAC, 'scheduleWeeks'));
    db.store.delete(col(FAC, 'scheduleEntries'));
    const r = await claim(db, 'a1');
    expect(r.schedule).toBe('added');
    expect(db.get(col(FAC, 'scheduleWeeks'), WEEK)!.weekStartDate).toBe('2026-11-30');
    // 欠席した児童（火）・a1（水）・b1（木）の通常の予定
    expect(entryOf(db, ABSENT)!.status).toBe('planned');
    expect(entryOf(db, 'a1', '2026-12-02')!.status).toBe('planned');
    expect(entryOf(db, 'b1', '2026-12-03')!.status).toBe('planned');
    expect(entryOf(db, 'a1')!.status).toBe('additional');
    expect(entryOf(db, 'a1')!.updatedByStaffName).toBe(LINE_CLAIM_STAFF_NAME);
    expect(entryOf(db, ABSENT)!.updatedByStaffName).toBe('自動');
  });

  test('予定で「お休み」だった児童は「追加」になり、取り消すと「お休み」に戻る', async () => {
    await setUp(db);
    seedEntry(db, 'a1', DATE, 'cancelled', ['09:00', '12:00']);
    const r = await claim(db, 'a1');
    expect(r.schedule).toBe('restored_from_cancelled');
    expect(entryOf(db, 'a1')!.status).toBe('additional');
    expect(entryOf(db, 'a1')!.plannedStartTime).toBe('09:00');
    const x = await release(db, 'a1');
    expect(x.schedule).toBe('removed');
    expect(entryOf(db, 'a1')!.status).toBe('cancelled');
    expect(entryOf(db, 'a1')!.lineClaim).toBeUndefined();
  });
});

describe('二重に入らない・入らない人', () => {
  test('すでにその日の予定に入っている児童は二重に入れない（予定は変えない）', async () => {
    await setUp(db);
    seedEntry(db, 'a1', DATE, 'planned', ['15:00', '18:00']);
    const before = {...entryOf(db, 'a1')!};
    const r = await claim(db, 'a1');
    expect(r.outcome).toBe('claimed');
    expect(r.schedule).toBe('already_in_plan');
    expect(entryOf(db, 'a1')).toEqual(before);
    expect(attOf(db, 'a1')).toBeUndefined();
    // 取り消しても、この枠で入れた予定ではないので消さない
    const x = await release(db, 'a1');
    expect(x.schedule).toBe('not_ours');
    expect(entryOf(db, 'a1')).toEqual(before);
  });

  test('出席の予定がすでにある児童も二重に入れない', async () => {
    await setUp(db);
    db.seed(col(FAC, 'attendance'), `${DATE}_a1`, {
      date: DATE, customerId: 'a1', customerName: '架空 a1', status: 'scheduled',
    });
    const r = await claim(db, 'a1');
    expect(r.schedule).toBe('already_in_plan');
    expect(entryOf(db, 'a1')).toBeUndefined();
  });

  test('同じ人が 2 回押しても 1 件だけ', async () => {
    await setUp(db);
    await claim(db, 'a1');
    const again = await claim(db, 'a1');
    expect(again.outcome).toBe('already_claimed_by_self');
    expect(again.schedule).toBeUndefined();
    const all = Object.keys(db.docs(col(FAC, 'scheduleEntries'))).filter((k) =>
      k.endsWith('_a1') && k.startsWith(DATE)
    );
    expect(all).toHaveLength(1);
  });

  // 同時に押した場合（実際の transaction の再試行）は、エミュレータでの再現で確かめる
  // （tool/verify/line_claim_emulator.mjs。このフェイクは楽観ロックの再試行を再現しない）
  test('先着に負けた人（後から押した）は予定に入らない', async () => {
    await setUp(db);
    expect((await claim(db, 'b1')).outcome).toBe('claimed');
    const r = await claim(db, 'a1');
    expect(r.outcome).toBe('already_filled');
    expect(entryOf(db, 'a1')).toBeUndefined();
    expect(attOf(db, 'a1')).toBeUndefined();
  });

  test('受付時間を過ぎたら入らない', async () => {
    await setUp(db);
    const late = new Date(NOW.getTime() + 25 * 3600 * 1000);
    const r = await claim(db, 'a1', late);
    expect(r.outcome).toBe('expired');
    expect(entryOf(db, 'a1')).toBeUndefined();
    expect(db.get('slots', SLOT_ID)!.status).toBe('open');
  });

  test('枠の事業所に在籍していない児童は確定しない。在籍している児童はそのあと確定できる', async () => {
    await setUp(db);
    seedCustomer(db, 'a1', {isActive: false});
    const r = await claim(db, 'a1');
    expect(r.outcome).toBe('not_enrolled');
    expect(db.get('slots', SLOT_ID)!.status).toBe('open');
    expect(entryOf(db, 'a1')).toBeUndefined();
    expect((await claim(db, 'b1')).outcome).toBe('claimed');
    expect(entryOf(db, 'b1')!.status).toBe('additional');
  });

  test('ほかの事業所にだけいる児童も確定しない（ほかの事業所の予定にも入れない）', async () => {
    await setUp(db);
    db.store.get(col(FAC, 'customers'))!.delete('a1');
    seedCustomer(db, 'a1', {fid: OTHER_FAC, days: [2]});
    const r = await claim(db, 'a1');
    expect(r.outcome).toBe('not_enrolled');
    expect(db.docs(col(OTHER_FAC, 'scheduleEntries'))).toEqual({});
  });

  test('事業所が書かれていない古い枠は、確定の印だけで予定に入らない', async () => {
    await setUp(db, {facilityId: null});
    expect(db.get('slots', SLOT_ID)!.facilityId).toBeUndefined();
    const r = await claim(db, 'a1');
    expect(r.outcome).toBe('claimed');
    expect(r.schedule).toBe('no_facility');
    expect(entryOf(db, 'a1')).toBeUndefined();
    const x = await release(db, 'a1');
    expect(x.outcome).toBe('released');
    expect(x.schedule).toBe('no_facility');
  });
});

describe('取り消しで外れる', () => {
  test('入室前なら予定と出席の予定から外れる', async () => {
    await setUp(db);
    await claim(db, 'a1');
    const r = await release(db, 'a1');
    expect(r.outcome).toBe('released');
    expect(r.schedule).toBe('removed');
    expect(entryOf(db, 'a1')).toBeUndefined();
    expect(attOf(db, 'a1')).toBeUndefined();
    expect(db.get('slots', SLOT_ID)!.status).toBe('released');
    // 取り消された枠は、ほかの人がもう一度確定できる（今までどおり）
    expect((await claim(db, 'b1')).schedule).toBe('added');
  });

  test('明日以降の分は、アプリが作った出席の予定（印なし・入室前）も外れる', async () => {
    await setUp(db);
    await claim(db, 'a1');
    db.seed(col(FAC, 'attendance'), `${DATE}_a1`, {
      date: DATE, customerId: 'a1', customerName: '架空 a1', status: 'scheduled',
    });
    const r = await release(db, 'a1');
    expect(r.schedule).toBe('removed');
    expect(attOf(db, 'a1')).toBeUndefined();
  });

  test('入室の記録がある場合は外さず、取り消された印を残す', async () => {
    await setUp(db);
    await claim(db, 'a1');
    db.seed(col(FAC, 'attendance'), `${DATE}_a1`, {
      ...attOf(db, 'a1')!,
      status: 'present',
      checkInTime: new Date('2026-12-01T05:05:00Z'),
    });
    const later = new Date(NOW.getTime() + 3600 * 1000);
    const r = await release(db, 'a1', later);
    expect(r.outcome).toBe('released');
    expect(r.schedule).toBe('kept_checked_in');
    const e = entryOf(db, 'a1')!;
    expect(e.status).toBe('additional');
    expect((e.lineClaim as Record<string, unknown>).releasedAt).toEqual(later);
    expect((e.lineClaim as Record<string, unknown>).keptReason).toBe('checked_in');
    const a = attOf(db, 'a1')!;
    expect(a.status).toBe('present');
    expect((a.lineClaim as Record<string, unknown>).releasedAt).toEqual(later);
  });

  test('ほかの人の確定は取り消せない（今までどおり）。予定も変わらない', async () => {
    await setUp(db);
    await claim(db, 'a1');
    const r = await release(db, 'b1');
    expect(r.outcome).toBe('release_denied');
    expect(entryOf(db, 'a1')!.status).toBe('additional');
  });
});

describe('定員の数え方（予定＋在室中＋退室済）: 欠席 1 人に 1 人が入る', () => {
  test('欠席の前後・確定の前後・取り消しの前後で、利用する人数は定員どおり', async () => {
    await setUp(db);
    const used = () =>
      Object.values(db.docs(col(FAC, 'attendance'))).filter(
        (a) => a.date === DATE && a.status !== 'absent'
      ).length;
    db.seed(col(FAC, 'attendance'), `${DATE}_${ABSENT}`, {
      date: DATE, customerId: ABSENT, status: 'absent',
    });
    expect(used()).toBe(0);
    await claim(db, 'a1');
    expect(used()).toBe(1);
    await release(db, 'a1');
    expect(used()).toBe(0);
  });
});

describe('LINE の応募（postback）の返信', () => {
  let line: FakeLineApi;
  beforeEach(() => {
    line = new FakeLineApi();
    setLineApiForTest(line);
  });
  afterEach(() => setLineApiForTest(null));

  const ev = (action: 'claim' | 'release', uid: string, id: string) => ({
    type: 'postback',
    replyToken: `rt-${id}`,
    webhookEventId: id,
    source: {userId: uid},
    postback: {data: buildPostbackData(action, SLOT_ID, CODE)},
  });

  test('確定・取り消しの返信は今までどおり。予定に入って外れる', async () => {
    const today = todayKeyJst(new Date());
    // postback は今の時刻で動くため、枠の日付を今日にして作り直す
    db = new FakeFirestore();
    const sid = makeSlotId(today, ABSENT);
    seedCustomer(db, 'a1');
    db.seed('line_linkage', 'a1', {customerId: 'a1', lineUserId: UID_A});
    await createSlotIfAbsent(db.asFirestore(), {
      slotId: sid, dateKey: today, sourceAbsent: ABSENT, linkCode: CODE,
      notifiedList: [{customerId: 'a1', lineUserIdHash: hashLineUserId(UID_A, SECRET), servedAt: new Date()}],
      createdBy: 'vacancy_notice', facilityId: FAC,
    });
    const e = (action: 'claim' | 'release', id: string) => ({
      ...ev(action, UID_A, id),
      postback: {data: buildPostbackData(action, sid, CODE)},
    });
    const r = await handleSlotPostback(db.asFirestore(), 'token', e('claim', 'e1'), SECRET);
    expect(r.outcome).toBe('claimed');
    expect(r.reply).toBe(MSG_CLAIM_WON);
    expect(entryOf(db, 'a1', today)!.status).toBe('additional');
    expect(attOf(db, 'a1', today)!.status).toBe('scheduled');
    const x = await handleSlotPostback(db.asFirestore(), 'token', e('release', 'e2'), SECRET);
    expect(x.reply).toBe(MSG_RELEASED);
    expect(entryOf(db, 'a1', today)).toBeUndefined();
    expect(attOf(db, 'a1', today)).toBeUndefined();
  });

  test('在籍していない児童は、案内を送っていない家庭と同じ返信（確定しない）', async () => {
    const today = todayKeyJst(new Date());
    db = new FakeFirestore();
    const sid = makeSlotId(today, ABSENT);
    db.seed('line_linkage', 'a1', {customerId: 'a1', lineUserId: UID_A});
    await createSlotIfAbsent(db.asFirestore(), {
      slotId: sid, dateKey: today, sourceAbsent: ABSENT, linkCode: CODE,
      notifiedList: [{customerId: 'a1', lineUserIdHash: hashLineUserId(UID_A, SECRET), servedAt: new Date()}],
      createdBy: 'vacancy_notice', facilityId: FAC,
    });
    const r = await handleSlotPostback(
      db.asFirestore(), 'token',
      {...ev('claim', UID_A, 'e9'), postback: {data: buildPostbackData('claim', sid, CODE)}},
      SECRET
    );
    expect(r.outcome).toBe('not_enrolled');
    expect(r.reply).toBe(MSG_CLAIM_NOT_NOTIFIED);
    expect(db.get('slots', sid)!.status).toBe('open');
    expect(line.pushCalls).toHaveLength(0);
  });
});

describe('通知を送るとき: 事業所は送った職員の所属から決める', () => {
  let line: FakeLineApi;
  beforeEach(() => {
    line = new FakeLineApi();
    setLineApiForTest(line);
  });
  afterEach(() => setLineApiForTest(null));

  const req = (data: unknown, uid: string) =>
    ({
      data,
      auth: {uid, token: {}},
      rawRequest: {},
      acceptsStreaming: false,
    }) as unknown as CallableRequest<unknown>;

  test('空き枠と通知の記録に、所属の事業所が書かれる（入力の値は使わない）', async () => {
    db.seed('memberships', 'staff-uid', {facilityId: FAC});
    await handleSendVacancyNotice(
      req(
        {
          date: DATE,
          message: '空きが出ました。',
          recipients: [{customerId: 'a1', lineUserId: UID_A, childName: '架空 a1'}],
          sourceAbsentCustomerId: ABSENT,
          facilityId: OTHER_FAC, // アプリから渡されても使わない
        },
        'staff-uid'
      ),
      db.asFirestore(),
      'token',
      SECRET
    );
    expect(db.get('slots', SLOT_ID)!.facilityId).toBe(FAC);
    expect(db.get('notification_logs', `${DATE}_a1`)!.facilityId).toBe(FAC);
    // 既存の項目の名前と意味は変えていない
    const slot = db.get('slots', SLOT_ID)!;
    for (const k of ['status', 'scheduledAt', 'opensAt', 'expiresAt', 'capacity',
      'claimedBy', 'notifiedList', 'sourceAbsent', 'createdBy', 'dateKey', 'linkCode']) {
      expect(slot).toHaveProperty(k);
    }
    expect(Object.keys(slot).sort()).toEqual(
      ['capacity', 'claimedBy', 'createdBy', 'dateKey', 'expiresAt', 'facilityId',
        'linkCode', 'notifiedList', 'opensAt', 'scheduledAt', 'sourceAbsent', 'status']
    );
  });

  test('すでにある枠（追加送信）の事業所は書き換えない', async () => {
    await setUp(db, {facilityId: null});
    db.seed('memberships', 'staff-uid', {facilityId: FAC});
    await handleSendVacancyNotice(
      req(
        {
          date: DATE,
          message: '空きが出ました。',
          recipients: [{customerId: 'c9', lineUserId: UID_B, childName: '架空 c9'}],
          sourceAbsentCustomerId: ABSENT,
        },
        'staff-uid'
      ),
      db.asFirestore(),
      'token',
      SECRET
    );
    expect(db.get('slots', SLOT_ID)!.facilityId).toBeUndefined();
  });
});
