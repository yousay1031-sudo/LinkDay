// firestore.rules のテスト（ローカルの Firestore エミュレータ専用）。
//
// 実行: tool/verify/test_rules.sh
//   - 起動中のエミュレータ（127.0.0.1:8080）に、検証データとは別のプロジェクトID
//     demo-linkday-rules で接続する。検証用データ（demo-linkday）は消さない。
//   - 本番プロジェクトには接続しない（demo- 以外・ループバック以外は中断）。
import { after, before, beforeEach, describe, test } from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  collection,
  serverTimestamp,
  setDoc,
  updateDoc,
} from 'firebase/firestore';

const PROJECT = 'demo-linkday-rules';
const HOST = process.env.LINKDAY_VERIFY_HOST || '127.0.0.1';
const PORT = Number(process.env.LINKDAY_VERIFY_FIRESTORE_PORT || 8080);
if (!PROJECT.startsWith('demo-')) throw new Error('demo- プロジェクト以外では実行しません');
if (!['127.0.0.1', 'localhost', '::1'].includes(HOST)) {
  throw new Error(`ループバック以外のホストでは実行しません: ${HOST}`);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const rules = fs.readFileSync(path.join(here, '..', 'firestore.rules'), 'utf8');

const FAC = 'fac-a';
const OTHER = 'fac-b';
const BUSINESS = [
  'customers',
  'scheduleEntries',
  'scheduleWeeks',
  'attendance',
  'transportRoutes',
  'settings',
  'staff',
];

let env;

/** 担当者の記録付きの書き込みデータ */
const audited = (extra = {}) => ({
  ...extra,
  updatedAt: serverTimestamp(),
  updatedByStaffId: 's-1',
  updatedByStaffName: '山田',
});

before(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT,
    firestore: { rules, host: HOST, port: PORT },
  });
});

after(async () => {
  await env?.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  // 管理者権限（ルール無視）で前提データを置く
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'memberships/member-a'), { facilityId: FAC });
    await setDoc(doc(db, 'memberships/member-b'), { facilityId: OTHER });
    await setDoc(doc(db, `facilities/${FAC}`), { name: '事業所A' });
    await setDoc(doc(db, `facilities/${OTHER}`), { name: '事業所B' });
    for (const c of BUSINESS) {
      await setDoc(doc(db, `facilities/${FAC}/${c}/d1`), { v: 1 });
    }
    await setDoc(doc(db, 'notification_logs/2026-11-19_c1'), { status: 'sent' });
    await setDoc(doc(db, 'slots/2026-11-19_c1'), { status: 'open' });
  });
});

const unauth = () => env.unauthenticatedContext().firestore();
const memberA = () => env.authenticatedContext('member-a').firestore();
const memberB = () => env.authenticatedContext('member-b').firestore();
const noMembership = () => env.authenticatedContext('stranger').firestore();

describe('未認証は拒否', () => {
  for (const c of BUSINESS) {
    test(`${c}: 読み取り・書き込みとも拒否`, async () => {
      const db = unauth();
      await assertFails(getDoc(doc(db, `facilities/${FAC}/${c}/d1`)));
      await assertFails(getDocs(collection(db, `facilities/${FAC}/${c}`)));
      await assertFails(setDoc(doc(db, `facilities/${FAC}/${c}/new`), audited()));
    });
  }
  test('事業所ドキュメント・所属ドキュメントも拒否', async () => {
    const db = unauth();
    await assertFails(getDoc(doc(db, `facilities/${FAC}`)));
    await assertFails(getDoc(doc(db, 'memberships/member-a')));
  });
});

describe('他事業所のアカウントは拒否', () => {
  for (const c of BUSINESS) {
    test(`${c}: 事業所Bのアカウントは事業所Aを読めない・書けない`, async () => {
      const db = memberB();
      await assertFails(getDoc(doc(db, `facilities/${FAC}/${c}/d1`)));
      await assertFails(getDocs(collection(db, `facilities/${FAC}/${c}`)));
      await assertFails(setDoc(doc(db, `facilities/${FAC}/${c}/new`), audited()));
      await assertFails(updateDoc(doc(db, `facilities/${FAC}/${c}/d1`), audited({ v: 2 })));
    });
  }
  test('ログイン済みでも所属がなければ拒否（「ログイン済みなら誰でも」にしない）', async () => {
    const db = noMembership();
    await assertFails(getDoc(doc(db, `facilities/${FAC}/customers/d1`)));
    await assertFails(setDoc(doc(db, `facilities/${FAC}/customers/new`), audited()));
  });
});

describe('所属アカウントは許可', () => {
  for (const c of BUSINESS) {
    test(`${c}: 読み取り・作成・更新できる`, async () => {
      const db = memberA();
      await assertSucceeds(getDoc(doc(db, `facilities/${FAC}/${c}/d1`)));
      await assertSucceeds(getDocs(collection(db, `facilities/${FAC}/${c}`)));
      await assertSucceeds(setDoc(doc(db, `facilities/${FAC}/${c}/new`), audited({ v: 1 })));
      await assertSucceeds(updateDoc(doc(db, `facilities/${FAC}/${c}/d1`), audited({ v: 2 })));
    });
  }
  test('自動処理（担当者ID なし・名前「自動」）の書き込みも許可', async () => {
    const db = memberA();
    await assertSucceeds(
      setDoc(doc(db, `facilities/${FAC}/attendance/auto`), {
        updatedAt: serverTimestamp(),
        updatedByStaffId: null,
        updatedByStaffName: '自動',
      }),
    );
  });
  test('自分の事業所ドキュメントと自分の所属は読める', async () => {
    const db = memberA();
    await assertSucceeds(getDoc(doc(db, `facilities/${FAC}`)));
    await assertSucceeds(getDoc(doc(db, 'memberships/member-a')));
  });
});

describe('書き込みの条件', () => {
  test('担当者の記録がない書き込みは拒否', async () => {
    const db = memberA();
    await assertFails(setDoc(doc(db, `facilities/${FAC}/customers/x`), { name: 'a' }));
    await assertFails(
      setDoc(doc(db, `facilities/${FAC}/customers/x`), {
        name: 'a',
        updatedAt: serverTimestamp(),
        updatedByStaffName: '',
      }),
    );
    // updatedAt をクライアント時刻で偽装できない
    await assertFails(
      setDoc(doc(db, `facilities/${FAC}/customers/x`), {
        name: 'a',
        updatedAt: new Date(2020, 0, 1),
        updatedByStaffName: '山田',
      }),
    );
  });
  test('顧客・職員は削除できない。週間計画・送迎・出席は削除できる', async () => {
    const db = memberA();
    await assertFails(deleteDoc(doc(db, `facilities/${FAC}/customers/d1`)));
    await assertFails(deleteDoc(doc(db, `facilities/${FAC}/staff/d1`)));
    await assertSucceeds(deleteDoc(doc(db, `facilities/${FAC}/scheduleEntries/d1`)));
    await assertSucceeds(deleteDoc(doc(db, `facilities/${FAC}/transportRoutes/d1`)));
    await assertSucceeds(deleteDoc(doc(db, `facilities/${FAC}/attendance/d1`)));
  });
  test('事業所ドキュメントはクライアントから作成・変更できない', async () => {
    const db = memberA();
    await assertFails(setDoc(doc(db, `facilities/${FAC}`), { name: 'x' }));
    await assertFails(setDoc(doc(db, 'facilities/fac-new'), { name: 'x' }));
  });
});

describe('所属をクライアントから書き換えられない', () => {
  test('自分の所属を他事業所に変えられない・新規作成もできない', async () => {
    await assertFails(setDoc(doc(memberA(), 'memberships/member-a'), { facilityId: OTHER }));
    await assertFails(setDoc(doc(noMembership(), 'memberships/stranger'), { facilityId: FAC }));
    await assertFails(deleteDoc(doc(memberA(), 'memberships/member-a')));
  });
  test('他人の所属は読めない', async () => {
    await assertFails(getDoc(doc(memberA(), 'memberships/member-b')));
  });
});

describe('既存ルールの回帰（変えていないこと）', () => {
  test('notification_logs: クライアントから作成・更新・削除できない（読みは可）', async () => {
    const db = memberA();
    await assertSucceeds(getDoc(doc(db, 'notification_logs/2026-11-19_c1')));
    await assertFails(setDoc(doc(db, 'notification_logs/2026-11-20_c1'), { status: 'sent' }));
    await assertFails(updateDoc(doc(db, 'notification_logs/2026-11-19_c1'), { status: 'x' }));
    await assertFails(deleteDoc(doc(db, 'notification_logs/2026-11-19_c1')));
  });
  test('slots: クライアントから書けない（読みは可）', async () => {
    const db = memberA();
    await assertSucceeds(getDoc(doc(db, 'slots/2026-11-19_c1')));
    await assertFails(updateDoc(doc(db, 'slots/2026-11-19_c1'), { status: 'filled' }));
  });
  test('上記以外の最上位コレクションは拒否', async () => {
    const db = memberA();
    await assertFails(getDoc(doc(db, 'customers/c1')));
    await assertFails(setDoc(doc(db, 'customers/c1'), { name: 'x' }));
  });
});
