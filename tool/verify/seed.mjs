#!/usr/bin/env node
// ローカルエミュレータ専用の投入スクリプト（Auth ユーザー + Firestore の slots）。
//
// 使い方:
//   node tool/verify/seed.mjs            # 認証ユーザーと slots を投入（冪等）
//   node tool/verify/seed.mjs --reset    # エミュレータ内の Auth/Firestore を全消去して再投入
//   node tool/verify/seed.mjs --clear    # エミュレータ内を全消去のみ
//
// 顧客・出席・週間計画・設定・送迎・通知履歴は Hive(IndexedDB) 側なので、
// ここでは投入しない（検証ビルドが起動時に投入する。docs/VERIFY_ENV.md）。
import { assertLocalEmulator, PROJECT, HOST, AUTH_PORT, FS_PORT, loadOrCreateCredentials } from './guard.mjs';

await assertLocalEmulator();

const args = new Set(process.argv.slice(2));
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
if (signUp.ok) {
  console.log('[seed] 認証ユーザーを作成しました（資格情報は ~/.linkday_verify/credentials.json、表示しません）');
} else {
  const body = await signUp.json().catch(() => ({}));
  if (body?.error?.message === 'EMAIL_EXISTS') {
    console.log('[seed] 認証ユーザーは作成済みです');
  } else {
    console.error(`[seed] 認証ユーザー作成に失敗: HTTP ${signUp.status}`);
    process.exit(1);
  }
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
