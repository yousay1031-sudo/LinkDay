// 検証用スクリプト共通の「本番を触らない」ガード。
// 全ての書込・削除の前に assertLocalEmulator() を通す。通らなければ即中断する。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const PROJECT = process.env.LINKDAY_VERIFY_PROJECT || 'demo-linkday';
export const HOST = process.env.LINKDAY_VERIFY_HOST || '127.0.0.1';
export const AUTH_PORT = Number(process.env.LINKDAY_VERIFY_AUTH_PORT || 9099);
export const FS_PORT = Number(process.env.LINKDAY_VERIFY_FIRESTORE_PORT || 8080);

const LOOPBACK = new Set(['127.0.0.1', 'localhost', '::1']);

function die(msg) {
  console.error(`[verify-guard] 中断: ${msg}`);
  process.exit(2);
}

export async function assertLocalEmulator() {
  if (!PROJECT.startsWith('demo-')) die(`プロジェクトIDが demo- で始まりません (${PROJECT})`);
  if (PROJECT === 'linkday-proud') die('本番プロジェクトIDです');
  if (!LOOPBACK.has(HOST)) die(`ホストがループバックではありません (${HOST})`);
  // 本番向けの環境変数が紛れていたら拒否（Admin SDK を使う他ツールとの取り違え防止）
  for (const k of ['GOOGLE_APPLICATION_CREDENTIALS', 'FIREBASE_TOKEN']) {
    if (process.env[k]) die(`${k} が設定されています。検証用シェルでは unset してください`);
  }
  // 実際にエミュレータが応答することを確認（応答しなければ何も書かない）
  const a = await probe(`http://${HOST}:${AUTH_PORT}/`, 'authEmulator');
  const f = await probe(`http://${HOST}:${FS_PORT}/`, 'Ok');
  if (!a) die(`Auth エミュレータに到達できません (${HOST}:${AUTH_PORT})`);
  if (!f) die(`Firestore エミュレータに到達できません (${HOST}:${FS_PORT})`);
}

async function probe(url, expect) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(3000) });
    return r.ok && (await r.text()).includes(expect);
  } catch {
    return false;
  }
}

// 認証情報はローカルのホーム配下に生成し、標準出力・ログへは出さない。
// ハイフンを含めない: 自動入力(puppeteer の keyboard.type)が NumpadSubtract を送って
// 既知のテンキー「−」例外(docs/VERIFY_ENV.md §既知の問題)を踏み、検証が止まるため。
export const CRED_DIR = path.join(os.homedir(), '.linkday_verify');
export const CRED_FILE = path.join(CRED_DIR, 'credentials.json');

export function loadOrCreateCredentials() {
  fs.mkdirSync(CRED_DIR, { recursive: true, mode: 0o700 });
  if (fs.existsSync(CRED_FILE)) return JSON.parse(fs.readFileSync(CRED_FILE, 'utf8'));
  const rnd = (n) =>
    Array.from({ length: n }, () => 'abcdefghjkmnpqrstuvwxyz23456789'[Math.floor(Math.random() * 31)]).join('');
  const cred = { email: 'verifystaff@example.invalid', password: `Vf${rnd(14)}` };
  fs.writeFileSync(CRED_FILE, JSON.stringify(cred), { mode: 0o600 });
  return cred;
}
