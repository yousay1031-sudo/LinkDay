#!/usr/bin/env node
// 【検証環境のみ】LINE の空き枠の応募を、ローカルの Firestore エミュレータで再現する。
//
//   - Functions の本体（functions/lib。npm --prefix functions run build の結果）を、
//     エミュレータの Firestore につないで直接呼ぶ（本物の transaction で確かめる）。
//   - LINE への送信は、テストと同じ差し替え（setLineApiForTest）で記録するだけ。外へは送らない。
//   - プロジェクトは demo- で始まるものだけ。接続先はループバックだけ。本番には接続しない。
//   - 外への接続は block_external.cjs で止める（NODE_OPTIONS で読み込む）。
//
// 実行（WSL）:
//   NODE_OPTIONS="--require $(pwd)/tool/verify/block_external.cjs" \
//     node tool/verify/line_claim_emulator.cjs
//   既定のプロジェクトは demo-linkday-line（検証データ demo-linkday には触れない）。
//   LINKDAY_LINE_PROJECT=demo-linkday で、検証データの事業所に応募を 1 件入れる
//   （画面で確かめる用。--app。児童はダミーデータの架空の児童）。
'use strict';
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..');
const PROJECT = process.env.LINKDAY_LINE_PROJECT || 'demo-linkday-line';
const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
if (!PROJECT.startsWith('demo-')) throw new Error('demo- プロジェクト以外では実行しません');
if (!/^(127\.0\.0\.1|localhost|\[::1\]):\d+$/.test(HOST)) {
  throw new Error(`ループバック以外の Firestore には接続しません: ${HOST}`);
}
process.env.FIRESTORE_EMULATOR_HOST = HOST;
process.env.GCLOUD_PROJECT = PROJECT;
delete process.env.GOOGLE_APPLICATION_CREDENTIALS;
// Google のサーバー上で動いているかの問い合わせ（メタデータサーバー）をしない。
// しないと firebase-admin が 169.254.169.254 / metadata.google.internal へ接続しようとする
// （block_external.cjs で止まるが、そもそも試みないようにする）
process.env.METADATA_SERVER_DETECTION = 'none';

const req = require('node:module').createRequire(path.join(ROOT, 'functions', 'package.json'));
const lib = (m) => require(path.join(ROOT, 'functions', 'lib', m));
const {initializeApp} = req('firebase-admin/app');
const {getFirestore} = req('firebase-admin/firestore');
const {setLineApiForTest} = lib('line/client.js');
const {handleSlotPostback} = lib('slotPostback.js');
const {handleSendVacancyNotice} = lib('sendVacancyNotice.js');
const {buildPostbackData} = lib('slotMessage.js');
const {makeSlotId, createSlotIfAbsent, hashLineUserId} = lib('slots.js');
const {todayKeyJst, weekKeyOf} = lib('slotSchedule.js');

initializeApp({projectId: PROJECT});
const db = getFirestore();

// LINE への送信は記録するだけ（テストの FakeLineApi と同じ差し替え）
const sent = [];
setLineApiForTest({
  async pushMessage(_t, to, m) { sent.push({kind: 'push', to: mask(to), m}); return {ok: true, httpStatus: 200}; },
  async pushText(_t, to, text) { sent.push({kind: 'push', to: mask(to), text}); return {ok: true, httpStatus: 200}; },
  async replyText(_t, token, text) { sent.push({kind: 'reply', token, text}); return {ok: true, httpStatus: 200}; },
  async replyMessage(_t, token, m) { sent.push({kind: 'reply', token, m}); return {ok: true, httpStatus: 200}; },
});
const mask = (u) => (typeof u === 'string' ? `${u.slice(0, 3)}…` : u);

const SECRET = 'verify-only-salt'; // 検証用の値（本物のチャネルシークレットではない）
const uidOf = (c) => 'U' + Buffer.from(c).toString('hex').padEnd(32, '0').slice(0, 32);
let evN = 0;
const ev = (action, cid, slotId, code) => ({
  type: 'postback',
  replyToken: `rt-${++evN}`,
  webhookEventId: `verify-${Date.now()}-${evN}`,
  source: {userId: uidOf(cid)},
  postback: {data: buildPostbackData(action, slotId, code)},
});
const callable = (data, uid) => ({data, auth: {uid, token: {}}, rawRequest: {}, acceptsStreaming: false});

const results = [];
const check = (name, ok, detail = '') => {
  results.push({name, ok});
  console.log(`${ok ? 'OK ' : 'NG '} ${name}${detail ? `  (${detail})` : ''}`);
};

async function clearProject() {
  // 自分のプロジェクト（demo-linkday-line）だけ消す
  const res = await fetch(`http://${HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, {
    method: 'DELETE',
  });
  if (!res.ok) throw new Error(`clear failed ${res.status}`);
}

const fcol = (fid, c) => db.collection(`facilities/${fid}/${c}`);

/** 利用する人数（予定＋在室中＋退室済）・お休み（欠席） */
async function counts(fid, dateKey) {
  const s = await fcol(fid, 'attendance').where('date', '==', dateKey).get();
  let used = 0, absent = 0;
  for (const d of s.docs) (d.data().status === 'absent' ? absent++ : used++);
  return {used, absent};
}

async function runIsolated() {
  await clearProject();
  const FAC = 'fac-line';
  const today = todayKeyJst(new Date());
  const week = weekKeyOf(today);
  const kids = ['k-absent', 'k-a', 'k-b', 'k-c'];
  const batch = db.batch();
  batch.set(db.collection('memberships').doc('staff-uid'), {facilityId: FAC});
  batch.set(fcol(FAC, 'scheduleWeeks').doc(week), {weekKey: week, weekStartDate: today, note: null});
  for (const k of kids) {
    batch.set(fcol(FAC, 'customers').doc(k), {name: `架空 ${k}`, isActive: true, regularDays: []});
    batch.set(db.collection('line_linkage').doc(k), {customerId: k, lineUserId: uidOf(k)});
  }
  // 欠席した児童（今日の予定・出席は欠席）
  batch.set(fcol(FAC, 'scheduleEntries').doc(`${today}_k-absent`), {
    date: today, weekKey: week, customerId: 'k-absent', customerName: '架空 k-absent',
    status: 'planned', plannedStartTime: '10:00', plannedEndTime: '16:00',
  });
  batch.set(fcol(FAC, 'attendance').doc(`${today}_k-absent`), {
    date: today, customerId: 'k-absent', customerName: '架空 k-absent', status: 'absent',
  });
  await batch.commit();

  // 1. 通知を送る（事業所は所属から。入力に別の事業所を書いても使わない）
  await handleSendVacancyNotice(
    callable({
      date: today,
      message: '検証用の空き枠のお知らせ',
      recipients: ['k-a', 'k-b', 'k-c'].map((c) => ({customerId: c, lineUserId: uidOf(c), childName: `架空 ${c}`})),
      sourceAbsentCustomerId: 'k-absent',
      facilityId: 'fac-other',
    }, 'staff-uid'),
    db, 'verify-token', SECRET);
  const slotId = makeSlotId(today, 'k-absent');
  const slot = (await db.collection('slots').doc(slotId).get()).data();
  check('通知: 空き枠に所属の事業所が書かれる', slot.facilityId === FAC, slot.facilityId);
  const log = (await db.collection('notification_logs').doc(`${today}_k-a`).get()).data();
  check('通知: 通知の記録にも事業所', log.facilityId === FAC);
  const code = slot.linkCode;
  const before = await counts(FAC, today);

  // 2. 同時に 2 人が押す（本物の transaction）
  const [ra, rb] = await Promise.all([
    handleSlotPostback(db, 'verify-token', ev('claim', 'k-a', slotId, code), SECRET),
    handleSlotPostback(db, 'verify-token', ev('claim', 'k-b', slotId, code), SECRET),
  ]);
  const outs = [ra.outcome, rb.outcome].sort();
  check('同時に押す: 1 人だけ確定・もう 1 人は埋まりました', outs.join(',') === 'already_filled,claimed', outs.join(','));
  const winner = ra.outcome === 'claimed' ? 'k-a' : 'k-b';
  const loser = winner === 'k-a' ? 'k-b' : 'k-a';
  const we = (await fcol(FAC, 'scheduleEntries').doc(`${today}_${winner}`).get()).data();
  const le = await fcol(FAC, 'scheduleEntries').doc(`${today}_${loser}`).get();
  check('確定した人は週間利用計画に「追加」（LINE の応募の印）', we?.status === 'additional' && we?.lineClaim?.slotId === slotId);
  check('先着に負けた人は予定に入らない', !le.exists);
  const wa = (await fcol(FAC, 'attendance').doc(`${today}_${winner}`).get()).data();
  check('確定した人は出席管理にも今日の予定として出る', wa?.status === 'scheduled');
  const after = await counts(FAC, today);
  check('欠席 1 人に 1 人が入る（利用する +1・お休みは 1 のまま）',
    after.used === before.used + 1 && after.absent === before.absent, JSON.stringify({before, after}));

  // 3. 同じ人がもう一度押す・LINE の再送 → 二重にならない
  const again = await handleSlotPostback(db, 'verify-token', ev('claim', winner, slotId, code), SECRET);
  const n = (await fcol(FAC, 'scheduleEntries').where('customerId', '==', winner).where('date', '==', today).get()).size;
  check('もう一度押しても二重にならない', again.outcome === 'already_claimed_by_self' && n === 1);

  // 4. 取り消し（入室前）→ 予定から外れる
  const rel = await handleSlotPostback(db, 'verify-token', ev('release', winner, slotId, code), SECRET);
  const e2 = await fcol(FAC, 'scheduleEntries').doc(`${today}_${winner}`).get();
  const a2 = await fcol(FAC, 'attendance').doc(`${today}_${winner}`).get();
  check('取り消すと予定と出席の予定から外れる', rel.outcome === 'released' && !e2.exists && !a2.exists);
  check('取り消しのあと数が元に戻る', JSON.stringify(await counts(FAC, today)) === JSON.stringify(before));

  // 5. もう 1 人が確定 → 入室 → 取り消し → 外れない
  const rc = await handleSlotPostback(db, 'verify-token', ev('claim', 'k-c', slotId, code), SECRET);
  await fcol(FAC, 'attendance').doc(`${today}_k-c`).update({status: 'present', checkInTime: new Date()});
  const rel2 = await handleSlotPostback(db, 'verify-token', ev('release', 'k-c', slotId, code), SECRET);
  const e3 = (await fcol(FAC, 'scheduleEntries').doc(`${today}_k-c`).get()).data();
  check('入室済みは取り消しても外れない（取り消された印を残す）',
    rc.outcome === 'claimed' && rel2.outcome === 'released' && e3?.status === 'additional' && !!e3?.lineClaim?.releasedAt);

  // 6. 受付時間を過ぎた枠
  const oldId = makeSlotId(today, 'k-old');
  await createSlotIfAbsent(db, {
    slotId: oldId, dateKey: today, sourceAbsent: 'k-old', linkCode: 'ZZ99ZZ',
    notifiedList: [{customerId: 'k-a', lineUserIdHash: hashLineUserId(uidOf('k-a'), SECRET), servedAt: new Date()}],
    createdBy: 'vacancy_notice', facilityId: FAC, now: new Date(Date.now() - 30 * 3600 * 1000), ttlHours: 1,
  });
  await fcol(FAC, 'attendance').doc(`${today}_k-a`).delete().catch(() => undefined);
  const ex = await handleSlotPostback(db, 'verify-token', ev('claim', 'k-a', oldId, 'ZZ99ZZ'), SECRET);
  const e4 = await fcol(FAC, 'scheduleEntries').doc(`${today}_k-a`).get();
  check('受付時間を過ぎたら入らない', ex.outcome === 'expired' && !e4.exists);

  // 7. 事業所の無い古い枠
  const legacyId = makeSlotId(today, 'k-legacy');
  await createSlotIfAbsent(db, {
    slotId: legacyId, dateKey: today, sourceAbsent: 'k-legacy', linkCode: 'YY88YY',
    notifiedList: [{customerId: 'k-a', lineUserIdHash: hashLineUserId(uidOf('k-a'), SECRET), servedAt: new Date()}],
    createdBy: 'vacancy_notice',
  });
  const lg = await handleSlotPostback(db, 'verify-token', ev('claim', 'k-a', legacyId, 'YY88YY'), SECRET);
  const e5 = await fcol(FAC, 'scheduleEntries').doc(`${today}_k-a`).get();
  check('事業所の無い古い枠は確定の印だけ（予定に入らない）', lg.outcome === 'claimed' && !e5.exists);

  // 8. 在籍していない児童
  await fcol(FAC, 'customers').doc('k-b').update({isActive: false});
  const nsId = makeSlotId(today, 'k-ns');
  await createSlotIfAbsent(db, {
    slotId: nsId, dateKey: today, sourceAbsent: 'k-ns', linkCode: 'XX77XX',
    notifiedList: [{customerId: 'k-b', lineUserIdHash: hashLineUserId(uidOf('k-b'), SECRET), servedAt: new Date()}],
    createdBy: 'vacancy_notice', facilityId: FAC,
  });
  const ne = await handleSlotPostback(db, 'verify-token', ev('claim', 'k-b', nsId, 'XX77XX'), SECRET);
  const ns = (await db.collection('slots').doc(nsId).get()).data();
  check('在籍していない児童は確定しない（案内を送っていない家庭と同じ返信）',
    ne.outcome === 'not_enrolled' && ns.status === 'open' && /お客様宛てではない/.test(ne.reply));
}

async function runApp() {
  // 検証データの事業所（ダミーデータ）に、今日の応募を 1 件入れる（画面で確かめる用）
  const mem = await db.collection('memberships').get();
  const fid = mem.docs.map((d) => d.data().facilityId).find((f) => typeof f === 'string');
  if (!fid) throw new Error('検証データの所属が見つかりません（seed を先に）');
  const staffUid = mem.docs.find((d) => d.data().facilityId === fid).id;
  const today = todayKeyJst(new Date());
  const att = await fcol(fid, 'attendance').where('date', '==', today).get();
  const absent = att.docs.find((d) => d.data().status === 'absent');
  if (!absent) throw new Error('今日の欠席の児童がいません');
  const inToday = new Set(att.docs.map((d) => d.data().customerId));
  const customers = await fcol(fid, 'customers').where('isActive', '==', true).get();
  // 送迎を使う児童を優先（「送迎計画に入っていません」も画面で確かめるため）
  const free = customers.docs.filter((d) => !inToday.has(d.id));
  const pick =
    free.find((d) => Array.isArray(d.data().transportLocations) && d.data().transportLocations.length > 0) ??
    free[0];
  if (!pick) throw new Error('今日の予定に入っていない児童がいません');
  const cid = pick.id;
  await db.collection('line_linkage').doc(cid).set({customerId: cid, lineUserId: uidOf(cid)});
  // ダミーデータに同じ名前の枠・通知の記録があれば消してから送る（検証データだけ）
  const sid0 = makeSlotId(today, absent.data().customerId);
  await db.collection('slots').doc(sid0).delete();
  await db.collection('notification_logs').doc(`${today}_${cid}`).delete();
  const before = await counts(fid, today);
  await handleSendVacancyNotice(callable({
    date: today, message: '検証用の空き枠のお知らせ',
    recipients: [{customerId: cid, lineUserId: uidOf(cid), childName: pick.data().name}],
    sourceAbsentCustomerId: absent.data().customerId,
  }, staffUid), db, 'verify-token', SECRET);
  const slotId = makeSlotId(today, absent.data().customerId);
  const slot = (await db.collection('slots').doc(slotId).get()).data();
  const r = await handleSlotPostback(db, 'verify-token', ev('claim', cid, slotId, slot.linkCode), SECRET);
  const after = await counts(fid, today);
  check(`検証データ: ${pick.data().name} さんが確定し、予定に入った`, r.outcome === 'claimed', `${JSON.stringify(before)} → ${JSON.stringify(after)}`);
  console.log(JSON.stringify({slotId, customerId: cid, name: pick.data().name, before, after}));
}

/** --app で確定した応募を、保護者が取り消したのと同じ処理で取り消す（画面で確かめる用） */
async function runAppRelease() {
  const today = todayKeyJst(new Date());
  const filled = await db.collection('slots').where('dateKey', '==', today).get();
  const s = filled.docs.find((d) => d.data().status === 'filled' && d.data().facilityId);
  if (!s) throw new Error('今日の確定済みの枠がありません（--app を先に）');
  const fid = s.data().facilityId;
  const cid = s.data().claimedBy.customerId;
  const before = await counts(fid, today);
  const r = await handleSlotPostback(db, 'verify-token', ev('release', cid, s.id, s.data().linkCode), SECRET);
  const after = await counts(fid, today);
  check('検証データ: 取り消して予定から外れた', r.outcome === 'released', `${JSON.stringify(before)} → ${JSON.stringify(after)}`);
}

(async () => {
  if (process.argv.includes('--app-release')) {
    if (PROJECT !== 'demo-linkday') throw new Error('--app-release は LINKDAY_LINE_PROJECT=demo-linkday のときだけ');
    await runAppRelease();
  } else if (process.argv.includes('--app')) {
    if (PROJECT !== 'demo-linkday') throw new Error('--app は LINKDAY_LINE_PROJECT=demo-linkday のときだけ');
    await runApp();
  } else {
    if (PROJECT === 'demo-linkday') throw new Error('検証データを消さないため、既定のプロジェクトで実行してください');
    await runIsolated();
  }
  const ng = results.filter((r) => !r.ok).length;
  console.log(`LINE への送信（記録のみ・外へは送っていない）: ${sent.length} 件`);
  console.log(ng === 0 ? `すべて OK（${results.length} 件）` : `NG ${ng} 件`);
  process.exit(ng === 0 ? 0 : 1);
})().catch((e) => { console.error('失敗:', e); process.exit(1); });
