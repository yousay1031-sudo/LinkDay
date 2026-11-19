#!/usr/bin/env node
// エミュレータが「いまの firestore.rules」で判定していることを確かめる（ルールテストの最初に実行）。
//
// 背景: ブランチの書き直しの後、エミュレータが「Rules updated」と表示しながら古いルールの
// ままだったことがある（docs/VERIFY_ENV.md §既知の問題）。古いルールのまま
// 「合格」と出ないよう、次の 2 つを行う。
//   1. いまの firestore.rules を、検証用プロジェクト（demo-linkday）と
//      ルールテスト用プロジェクト（demo-linkday-rules）の両方へ明示的に読み込ませる
//      （エミュレータの管理用 API。ローカルのエミュレータだけが対象）。
//   2. 検証用プロジェクトで、いまのルールでしか成り立たない判定を実際に試す
//      （所属アカウントは読める／所属なし・未認証は拒否／担当者の記録がない書き込みは拒否）。
// 試しに作ったドキュメントは最後に消す。本番には接続しない。
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertLocalEmulator, PROJECT, HOST, FS_PORT } from './guard.mjs';

await assertLocalEmulator();

const RULES_PROJECT = 'demo-linkday-rules';
const here = path.dirname(fileURLToPath(import.meta.url));
const rulesPath = path.join(here, '..', '..', 'firestore.rules');
const rules = fs.readFileSync(rulesPath, 'utf8');
const fingerprint = crypto.createHash('sha256').update(rules).digest('hex').slice(0, 12);
const base = `http://${HOST}:${FS_PORT}`;

function fail(msg) {
  console.error(`[rules-check] NG: ${msg}`);
  console.error('[rules-check] エミュレータを起動し直してください: tool/verify/stop_emulators.sh → start_emulators.sh → node tool/verify/seed.mjs');
  process.exit(1);
}

// ── 1. いまのルールを読み込ませる（--check-only なら読み込ませずに判定だけ試す）
const checkOnly = process.argv.includes('--check-only');
for (const p of checkOnly ? [] : [PROJECT, RULES_PROJECT]) {
  const r = await fetch(`${base}/emulator/v1/projects/${p}:securityRules`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ rules: { files: [{ name: 'firestore.rules', content: rules }] } }),
  });
  if (!r.ok) fail(`${p} へのルールの読み込みに失敗 (HTTP ${r.status}): ${(await r.text()).slice(0, 300)}`);
}

// ── 2. 検証用プロジェクトで判定を試す
const UID = 'rules-probe-member';
const FID = 'rules-probe-facility';
const docs = `${base}/v1/projects/${PROJECT}/databases/(default)/documents`;
const owner = { 'content-type': 'application/json', authorization: 'Bearer owner' };
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
/** エミュレータ用の署名なしトークン（ローカルのエミュレータだけが受け付ける） */
const mockToken = (uid) => {
  const now = Math.floor(Date.now() / 1000);
  return `${b64({ alg: 'none', typ: 'JWT' })}.${b64({
    iss: `https://securetoken.google.com/${PROJECT}`, aud: PROJECT, iat: now, exp: now + 3600,
    auth_time: now, sub: uid, user_id: uid, firebase: { sign_in_provider: 'custom', identities: {} },
  })}.`;
};
const as = (uid) => ({ 'content-type': 'application/json', ...(uid ? { authorization: `Bearer ${mockToken(uid)}` } : {}) });
const put = (p, fields, headers) =>
  fetch(`${docs}/${p}`, { method: 'PATCH', headers, body: JSON.stringify({ fields }) });

const probes = [];
try {
  const setup = [
    [`memberships/${UID}`, { facilityId: { stringValue: FID } }],
    [`facilities/${FID}/staff/p1`, { name: { stringValue: '確認用' }, isActive: { booleanValue: true } }],
  ];
  for (const [p, f] of setup) {
    probes.push(p);
    const r = await put(p, f, owner);
    if (!r.ok) fail(`確認用ドキュメントの作成に失敗 (HTTP ${r.status})`);
  }
  const checks = [
    ['所属アカウントは事業所のデータを読める', await fetch(`${docs}/facilities/${FID}/staff/p1`, { headers: as(UID) }), 200],
    ['所属のないアカウントは読めない', await fetch(`${docs}/facilities/${FID}/staff/p1`, { headers: as('rules-probe-other') }), 403],
    ['未認証は読めない', await fetch(`${docs}/facilities/${FID}/staff/p1`, { headers: as(null) }), 403],
    ['担当者の記録がない書き込みは拒否', await put(`facilities/${FID}/staff/p2`, { name: { stringValue: 'x' } }, as(UID)), 403],
  ];
  for (const [name, res, want] of checks) {
    if (res.status !== want) fail(`${name}: HTTP ${res.status}（期待 ${want}）。古いルールで判定されている可能性があります`);
    console.log(`[rules-check] OK ${name}`);
  }
  console.log(`[rules-check] エミュレータは現在の firestore.rules（sha256 ${fingerprint}…）で判定しています（${PROJECT} / ${RULES_PROJECT}）`);
} finally {
  for (const p of [...probes, `facilities/${FID}/staff/p2`].reverse()) {
    await fetch(`${docs}/${p}`, { method: 'DELETE', headers: owner }).catch(() => {});
  }
}
