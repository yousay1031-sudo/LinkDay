#!/usr/bin/env node
// ローカルエミュレータ専用の投入スクリプト（Auth ユーザー + Firestore の slots）。
//
// 使い方:
//   node tool/verify/seed.mjs            # 認証ユーザーと slots を投入（冪等）
//   node tool/verify/seed.mjs --reset    # エミュレータ内の Auth/Firestore を全消去して再投入
//   node tool/verify/seed.mjs --clear    # エミュレータ内を全消去のみ
//   node tool/verify/seed.mjs --reset --data empty   # 顧客なし（空の状態の確認用）
//
// 投入するもの: 認証ユーザー / 事業所 demo-facility / 所属(memberships) / 職員 / 顧客 / 週間利用計画 /
//   出席 / 送迎 / 設定 / 業務日誌（ステップ3）/ slots
// 出席・設定・送迎・通知履歴は、Firestore 移行の各段階で
// こちらへ移すまでは Hive(IndexedDB) 側（検証ビルドが起動時に投入する。docs/VERIFY_ENV.md）。
import { assertLocalEmulator, PROJECT, HOST, AUTH_PORT, FS_PORT, loadOrCreateCredentials } from './guard.mjs';
import { buildCustomer, CUSTOMER_COUNT, toFsFields } from './dummy_customers.mjs';
import { buildDemoWeeks, scheduleDocs } from './dummy_schedule.mjs';
import { buildDemoAttendance } from './dummy_attendance.mjs';
import { buildDemoTransport } from './dummy_transport.mjs';
import { buildDemoSettings } from './dummy_settings.mjs';
import { buildDemoJournals } from './dummy_journals.mjs';

await assertLocalEmulator();

const args = new Set(process.argv.slice(2));
// --data normal（既定）| empty
const argv = process.argv.slice(2);
const dataIdx = argv.findIndex((a) => a === '--data' || a.startsWith('--data='));
const dataMode = dataIdx < 0
  ? 'normal'
  : argv[dataIdx].includes('=') ? argv[dataIdx].split('=')[1] : argv[dataIdx + 1];
if (!['normal', 'empty'].includes(dataMode)) {
  console.error('[seed] --data は normal か empty');
  process.exit(2);
}
const authBase = `http://${HOST}:${AUTH_PORT}`;
const fsBase = `http://${HOST}:${FS_PORT}`;

async function must(res, what) {
  if (!res.ok) {
    console.error(`[seed] ${what} に失敗: HTTP ${res.status}`);
    process.exit(1);
  }
  return res;
}

if (args.has('--reset') || args.has('--clear')) {
  await must(
    await fetch(`${authBase}/emulator/v1/projects/${PROJECT}/accounts`, { method: 'DELETE' }),
    'Auth 全消去'
  );
  await must(
    await fetch(`${fsBase}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' }),
    'Firestore 全消去'
  );
  console.log('[seed] エミュレータ内の Auth / Firestore を消去しました');
  if (args.has('--clear')) process.exit(0);
}

// ── 認証ユーザー（ローカル専用。資格情報は ~/.linkday_verify に保存・表示しない）
const cred = loadOrCreateCredentials();
const signUp = await fetch(`${authBase}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-api-key`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ email: cred.email, password: cred.password, returnSecureToken: false }),
});
let uid;
if (signUp.ok) {
  uid = (await signUp.json()).localId;
  console.log('[seed] 認証ユーザーを作成しました（資格情報は ~/.linkday_verify/credentials.json、表示しません）');
} else {
  const body = await signUp.json().catch(() => ({}));
  if (body?.error?.message === 'EMAIL_EXISTS') {
    // uid を得るためにサインインする（資格情報は表示しない）
    const signIn = await must(
      await fetch(`${authBase}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-api-key`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ email: cred.email, password: cred.password, returnSecureToken: false }),
      }),
      '認証ユーザーの uid 取得'
    );
    uid = (await signIn.json()).localId;
    console.log('[seed] 認証ユーザーは作成済みです');
  } else {
    console.error(`[seed] 認証ユーザー作成に失敗: HTTP ${signUp.status}`);
    process.exit(1);
  }
}
if (!uid) {
  console.error('[seed] 認証ユーザーの uid を取得できませんでした');
  process.exit(1);
}

// ── Firestore 共通（書込はエミュレータの管理者トークン 'owner'。rules は緩めない）
const docUrl = (p) => `${fsBase}/v1/projects/${PROJECT}/databases/(default)/documents/${p}`;
const fsHeaders = { 'content-type': 'application/json', authorization: 'Bearer owner' };
const nowTs = () => ({ timestampValue: new Date().toISOString() });

/** 上書き投入 */
async function putDoc(p, fields, what) {
  await must(
    await fetch(docUrl(p), { method: 'PATCH', headers: fsHeaders, body: JSON.stringify({ fields }) }),
    what
  );
}

/** 無いときだけ作る（検証中に画面で変えた内容を再投入で戻さない） */
async function createIfMissing(p, fields, what) {
  const res = await fetch(`${docUrl(p)}?currentDocument.exists=false`, {
    method: 'PATCH',
    headers: fsHeaders,
    body: JSON.stringify({ fields }),
  });
  if (res.ok) return true;
  if (res.status === 409 || res.status === 400) return false; // 既にある
  console.error(`[seed] ${what} に失敗: HTTP ${res.status}`);
  process.exit(1);
}

// ── 事業所・所属・職員（Firestore 移行ステップ2）
// 検証用の事業所 ID。アプリは memberships/{uid}.facilityId からこれを解決する。
const FACILITY_ID = 'demo-facility';
const audit = {
  createdAt: nowTs(),
  updatedAt: nowTs(),
  updatedByStaffId: { nullValue: null },
  updatedByStaffName: { stringValue: '検証データ' },
};
await putDoc(`facilities/${FACILITY_ID}`, { name: { stringValue: '検証用事業所' } }, '事業所の投入');
await putDoc(
  `memberships/${uid}`,
  { facilityId: { stringValue: FACILITY_ID }, createdAt: nowTs() },
  '所属(memberships)の投入'
);
// 架空の職員（実在の人物ではない）。ダミー顧客（検証 花子 など）と名前が重ならないようにする
// ステップ2: Google ログイン用のアドレスは実在しない .invalid。
//   春子 = 最初の管理者（本番では Firebase コンソールで登録する。docs/RELEASE_FIRESTORE_MIGRATION.md）
//   夏男 = 管理者でない職員（ログイン許可）
//   秋子 = Google アカウントを持たない職員（共用端末だけを使う）
const staff = [
  { id: 'dummy-s001', name: '職員 春子', kana: 'しょくいん はるこ', role: 'childDevManager',
    workDays: [1, 2, 3, 4, 5], canDrive: false, isAdmin: true, login: true, email: 'haruko@example.invalid' },
  { id: 'dummy-s002', name: '職員 夏男', kana: 'しょくいん なつお', role: 'driver',
    workDays: [1, 3, 5], canDrive: true, isAdmin: false, login: true, email: 'natsuo@example.invalid' },
  { id: 'dummy-s003', name: '職員 秋子', kana: 'しょくいん あきこ', role: 'nurseryTeacher',
    workDays: [2, 4], canDrive: false, isAdmin: false, login: false, email: '' },
];
let staffCreated = 0;
for (const s of staff) {
  const created = await createIfMissing(
    `facilities/${FACILITY_ID}/staff/${s.id}`,
    {
      name: { stringValue: s.name },
      kana: { stringValue: s.kana },
      role: { stringValue: s.role },
      qualifications: { stringValue: '' },
      workDays: { arrayValue: { values: s.workDays.map((d) => ({ integerValue: String(d) })) } },
      canDrive: { booleanValue: s.canDrive },
      isActive: { booleanValue: true },
      deactivatedAt: { nullValue: null },
      isAdmin: { booleanValue: s.isAdmin },
      loginEnabled: { booleanValue: s.login },
      hasGoogleEmail: { booleanValue: s.email !== '' },
      pinHash: { nullValue: null },
      pinSalt: { nullValue: null },
      ...audit,
    },
    `職員 ${s.id} の投入`
  );
  if (created) staffCreated++;
  if (s.email) {
    await createIfMissing(
      `facilities/${FACILITY_ID}/staffAccounts/${s.id}`,
      {
        googleEmail: { stringValue: s.email },
        googleEmailLower: { stringValue: s.email.toLowerCase() },
        ...audit,
      },
      `職員 ${s.id} のメールアドレスの投入`
    );
  }
}
console.log(
  `[seed] 事業所 ${FACILITY_ID} と所属を投入しました。職員: 新規 ${staffCreated} 件 / 既存 ${staff.length - staffCreated} 件`
);

// ── 顧客（Firestore 移行ステップ3）。--data empty なら投入しない（空の状態の確認用）
// 無いときだけ作る（画面で変えた内容・他のブラウザでの編集を再投入で戻さない）。
if (dataMode === 'empty') {
  console.log('[seed] --data empty: 顧客は投入しません');
} else {
  const now = new Date();
  let created = 0;
  for (let n = 1; n <= CUSTOMER_COUNT + 1; n++) {
    const c = buildCustomer(n, now);
    const ok = await createIfMissing(
      `facilities/${FACILITY_ID}/customers/${c.id}`,
      {
        ...toFsFields(c.data),
        deactivatedAt: c.data.isActive ? { nullValue: null } : nowTs(),
        ...audit,
      },
      `顧客 ${c.id} の投入`
    );
    if (ok) created++;
  }
  console.log(
    `[seed] 顧客: 新規 ${created} 件 / 既存 ${CUSTOMER_COUNT + 1 - created} 件（在籍中 ${CUSTOMER_COUNT} + 在籍終了 1）`
  );

  // ── 週間利用計画（Firestore 移行ステップ4）: 先週・今週・来週。無いときだけ作る
  // 週の目印が既にある週は、マスも含めて触らない（画面で編集した内容を戻さない）
  const { markers, entries } = scheduleDocs(buildDemoWeeks(now));
  const skipWeeks = new Set();
  for (const m of markers) {
    const ok = await createIfMissing(
      `facilities/${FACILITY_ID}/scheduleWeeks/${m.id}`,
      { ...toFsFields(m.data), ...audit },
      `週の目印 ${m.id} の投入`
    );
    if (!ok) skipWeeks.add(m.id);
  }
  const todo = entries.filter((e) => !skipWeeks.has(e.data.weekKey));
  for (let i = 0; i < todo.length; i += 25) {
    await Promise.all(
      todo.slice(i, i + 25).map((e) =>
        createIfMissing(
          `facilities/${FACILITY_ID}/scheduleEntries/${e.id}`,
          { ...toFsFields(e.data), ...audit },
          `利用予定 ${e.id} の投入`
        )
      )
    );
  }
  console.log(
    `[seed] 週間利用計画: 新規 ${markers.length - skipWeeks.size} 週・${todo.length} マス / 既存 ${skipWeeks.size} 週（触らない）`
  );

  // ── 出席（Firestore 移行ステップ5）: 直近 5 日の実績 + 今日の混在。無いときだけ作る
  const att = buildDemoAttendance(now);
  let attCreated = 0;
  for (let i = 0; i < att.length; i += 25) {
    const res = await Promise.all(
      att.slice(i, i + 25).map((r) =>
        createIfMissing(
          `facilities/${FACILITY_ID}/attendance/${r.id}`,
          { ...toFsFields(r.data), ...audit },
          `出席 ${r.id} の投入`
        )
      )
    );
    attCreated += res.filter(Boolean).length;
  }
  console.log(`[seed] 出席: 新規 ${attCreated} 件 / 既存 ${att.length - attCreated} 件`);

  // ── 送迎計画（Firestore 移行ステップ6）: 今日のお迎え 3 台・お送り 2 台。無いときだけ作る
  const routes = buildDemoTransport(now);
  let routeCreated = 0;
  for (const r of routes) {
    const ok = await createIfMissing(
      `facilities/${FACILITY_ID}/transportRoutes/${r.id}`,
      { ...toFsFields(r.data), ...audit },
      `送迎計画 ${r.id} の投入`
    );
    if (ok) routeCreated++;
  }
  console.log(`[seed] 送迎計画: 新規 ${routeCreated} 件 / 既存 ${routes.length - routeCreated} 件`);

  // ── 設定（Firestore 移行ステップ7）: 事業所で 1 件。無いときだけ作る
  const settingsCreated = await createIfMissing(
    `facilities/${FACILITY_ID}/settings/app`,
    { ...toFsFields(buildDemoSettings()), ...audit },
    '設定の投入'
  );
  console.log(`[seed] 設定: ${settingsCreated ? '新規' : '既存のまま（触らない）'}`);

  // ── 業務日誌（ステップ3）: 昨日と一昨日。無いときだけ作る
  let journalCreated = 0;
  const journals = buildDemoJournals(now);
  for (const j of journals) {
    const ok = await createIfMissing(
      `facilities/${FACILITY_ID}/dailyJournals/${j.id}`,
      { ...toFsFields(j.data), ...audit },
      `業務日誌 ${j.id} の投入`
    );
    if (ok) journalCreated++;
  }
  console.log(`[seed] 業務日誌: 新規 ${journalCreated} 件 / 既存 ${journals.length - journalCreated} 件`);
}

// ── Firestore: slots（出席画面の「LINE応募」表示用）
// 書込はエミュレータの管理者トークン('owner')で行う（クライアントの rules は緩めない）。
const today = new Date();
const dateKey = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
const iso = (d) => ({ timestampValue: d.toISOString() });
const str = (s) => ({ stringValue: s });
const inH = (h) => new Date(Date.now() + h * 3600 * 1000);

const slots = [
  {
    id: `${dateKey}_dummy-c003`,
    fields: {
      dateKey: str(dateKey),
      sourceAbsent: str('dummy-c003'),
      status: str('filled'),
      expiresAt: iso(inH(3)),
      claimedBy: { mapValue: { fields: { customerId: str('dummy-c010'), claimedAt: iso(inH(-1)) } } },
      notifiedList: { arrayValue: { values: [str('dummy-c006'), str('dummy-c009'), str('dummy-c010')] } },
    },
  },
  {
    id: `${dateKey}_dummy-c007`,
    fields: {
      dateKey: str(dateKey),
      sourceAbsent: str('dummy-c007'),
      status: str('open'),
      expiresAt: iso(inH(4)),
      notifiedList: { arrayValue: { values: [str('dummy-c012'), str('dummy-c015')] } },
    },
  },
];
for (const s of slots) {
  const url = `${fsBase}/v1/projects/${PROJECT}/databases/(default)/documents/slots/${encodeURIComponent(s.id)}`;
  await must(
    await fetch(url, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', authorization: 'Bearer owner' },
      body: JSON.stringify({ fields: s.fields }),
    }),
    `slots/${s.id} の投入`
  );
}
console.log(`[seed] Firestore slots を ${slots.length} 件投入しました (dateKey=${dateKey}, project=${PROJECT})`);
