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

// ステップ2: 個人アカウントにひも付く職員（在籍・ログインの許可の組み合わせ）
const PERSONAL_STAFF = {
  haru: { name: '職員 春子', isActive: true, loginEnabled: true, isAdmin: false },
  natsu: { name: '職員 夏男', isActive: true, loginEnabled: false, isAdmin: false },
  aki: { name: '職員 秋子', isActive: false, loginEnabled: true, isAdmin: false },
  boss: { name: '管理 一郎', isActive: true, loginEnabled: true, isAdmin: true },
};

/** 個人アカウント id 本人の担当者の記録付きの書き込みデータ */
const by = (id, extra = {}) => ({
  ...extra,
  updatedAt: serverTimestamp(),
  updatedByStaffId: id,
  updatedByStaffName: id,
});

// クライアントが触れうる最上位のコレクション（firestore.rules に書いたものすべて）
const TOP_LEVEL = [
  'line_linkage',
  'linking_codes',
  'notification_logs',
  'slots',
  'webhook_processed',
  'slot_audit',
  'slot_admin_targets',
];

/** Google でログインしたアカウントの認証トークン */
const googleToken = (email) => ({
  email,
  email_verified: true,
  firebase: { sign_in_provider: 'google.com' },
});

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
    // ステップ2: 個人アカウント（Google）。職員の状態で所属の有効・無効が決まる
    for (const [id, s] of Object.entries(PERSONAL_STAFF)) {
      await setDoc(doc(db, `facilities/${FAC}/staff/${id}`), s);
      await setDoc(doc(db, `memberships/p-${id}`), {
        facilityId: FAC,
        kind: 'personal',
        staffId: id,
      });
    }
    for (const c of TOP_LEVEL) {
      await setDoc(doc(db, `${c}/x1`), { customerId: 'x1', v: 1 });
    }
    await setDoc(doc(db, `facilities/${FAC}/staffAccounts/haru`), {
      googleEmail: 'haruko@example.invalid',
      googleEmailLower: 'haruko@example.invalid',
    });
    await setDoc(doc(db, `facilities/${FAC}/loginHistory/h1`), { uid: 'member-a' });
  });
});

const unauth = () => env.unauthenticatedContext().firestore();
const memberA = () => env.authenticatedContext('member-a').firestore();
const memberB = () => env.authenticatedContext('member-b').firestore();
const noMembership = () => env.authenticatedContext('stranger').firestore();
const personal = (id) =>
  env.authenticatedContext(`p-${id}`, googleToken(`${id}@example.invalid`)).firestore();
// 未登録の Google アカウント（登録済みの職員と同じアドレスでも、所属が無ければ同じ）
const unregisteredGoogle = () =>
  env.authenticatedContext('g-stranger', googleToken('haruko@example.invalid')).firestore();
// 自分で作ったメールアドレスとパスワードのアカウント
const selfMadePassword = () =>
  env
    .authenticatedContext('pw-stranger', {
      email: 'someone@example.invalid',
      email_verified: false,
      firebase: { sign_in_provider: 'password' },
    })
    .firestore();

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
      // ステップ2（判断点7）: 職員の登録は管理者だけ。共用端末は職員を作れない
      if (c === 'staff') {
        await assertFails(setDoc(doc(db, `facilities/${FAC}/${c}/new`), audited({ v: 1 })));
      } else {
        await assertSucceeds(setDoc(doc(db, `facilities/${FAC}/${c}/new`), audited({ v: 1 })));
      }
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

// ════════════════════════════════════════════════════════════════
// ステップ2: Google ログインと所属
// ════════════════════════════════════════════════════════════════

describe('条件A: 誰でもアカウントを作れても、有効な所属が無ければ何も読めず何も書けない', () => {
  const FACILITY_COLS = [...BUSINESS, 'staffAccounts', 'loginHistory'];
  const existingId = (c) => (c === 'staffAccounts' ? 'haru' : c === 'loginHistory' ? 'h1' : 'd1');
  for (const [label, who, myUid] of [
    ['未登録の Google アカウント', unregisteredGoogle, 'g-stranger'],
    ['自分で作ったメールアドレスのアカウント', selfMadePassword, 'pw-stranger'],
  ]) {
    test(`${label}: 事業所の下の全コレクションを読めない・書けない`, async () => {
      const db = who();
      await assertFails(getDoc(doc(db, `facilities/${FAC}`)));
      for (const c of FACILITY_COLS) {
        const id = existingId(c);
        await assertFails(getDoc(doc(db, `facilities/${FAC}/${c}/${id}`)));
        await assertFails(getDocs(collection(db, `facilities/${FAC}/${c}`)));
        await assertFails(setDoc(doc(db, `facilities/${FAC}/${c}/new`), audited()));
        await assertFails(updateDoc(doc(db, `facilities/${FAC}/${c}/${id}`), audited({ v: 9 })));
        await assertFails(deleteDoc(doc(db, `facilities/${FAC}/${c}/${id}`)));
      }
      await assertFails(setDoc(doc(db, `facilities/${FAC}/customers/d1/sub/x`), { v: 1 }));
    });

    test(`${label}: 最上位の全コレクション（LINE 連携を含む）を読めない・書けない`, async () => {
      const db = who();
      for (const c of TOP_LEVEL) {
        await assertFails(getDoc(doc(db, `${c}/x1`)));
        await assertFails(getDocs(collection(db, c)));
        await assertFails(setDoc(doc(db, `${c}/new`), { customerId: 'new', v: 1 }));
        await assertFails(deleteDoc(doc(db, `${c}/x1`)));
      }
      // 形式の正しい連携コードの発行・連携の作成も不可
      await assertFails(
        setDoc(doc(db, 'linking_codes/ABC123'), {
          code: 'ABC123',
          customerId: 'c1',
          expiresAt: new Date(2030, 0, 1),
        }),
      );
      await assertFails(
        setDoc(doc(db, 'line_linkage/c1'), { customerId: 'c1', lineUserId: 'U' + 'a'.repeat(32) }),
      );
    });

    test(`${label}: 所属を自分で作れない・他人の所属を読めない`, async () => {
      const db = who();
      await assertFails(setDoc(doc(db, `memberships/${myUid}`), { facilityId: FAC }));
      await assertFails(
        setDoc(doc(db, `memberships/${myUid}`), { facilityId: FAC, kind: 'personal', staffId: 'haru' }),
      );
      await assertFails(getDoc(doc(db, 'memberships/member-a')));
      await assertFails(getDocs(collection(db, 'memberships')));
      await assertFails(getDoc(doc(db, 'other_top/x')));
      // 自分の所属（無い）を読むことだけはできる（アプリが「登録されていません」を出すため）
      await assertSucceeds(getDoc(doc(db, `memberships/${myUid}`)));
    });
  }
});

describe('個人アカウントの所属', () => {
  test('在籍中・ログイン許可の職員の個人アカウントは読み書きできる', async () => {
    const db = personal('haru');
    await assertSucceeds(getDoc(doc(db, `facilities/${FAC}/customers/d1`)));
    await assertSucceeds(
      setDoc(doc(db, `facilities/${FAC}/customers/p1`), {
        updatedAt: serverTimestamp(),
        updatedByStaffId: 'haru',
        updatedByStaffName: '職員 春子',
      }),
    );
    await assertSucceeds(getDoc(doc(db, 'line_linkage/x1')));
  });

  for (const [id, why] of [
    ['natsu', 'ログインの許可が外れた'],
    ['aki', '在籍終了になった'],
  ]) {
    test(`${why}職員の個人アカウントは、所属の文書が残っていても読み書きできない`, async () => {
      const db = personal(id);
      await assertFails(getDoc(doc(db, `facilities/${FAC}/customers/d1`)));
      await assertFails(getDocs(collection(db, `facilities/${FAC}/customers`)));
      await assertFails(
        setDoc(doc(db, `facilities/${FAC}/customers/p1`), {
          updatedAt: serverTimestamp(),
          updatedByStaffId: id,
          updatedByStaffName: 'x',
        }),
      );
      await assertFails(getDoc(doc(db, 'line_linkage/x1')));
    });
  }

  test('所属が消えたアカウントは読み書きできない', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await deleteDoc(doc(ctx.firestore(), 'memberships/p-haru'));
    });
    const db = personal('haru');
    await assertFails(getDoc(doc(db, `facilities/${FAC}/customers/d1`)));
    await assertFails(
      setDoc(doc(db, `facilities/${FAC}/customers/p1`), {
        updatedAt: serverTimestamp(),
        updatedByStaffId: 'haru',
        updatedByStaffName: '職員 春子',
      }),
    );
    await assertFails(getDoc(doc(db, 'line_linkage/x1')));
  });

  test('職員の文書が無い個人アカウントは読めない', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'memberships/p-ghost'), {
        facilityId: FAC,
        kind: 'personal',
        staffId: 'ghost',
      });
    });
    await assertFails(getDoc(doc(personal('ghost'), `facilities/${FAC}/customers/d1`)));
  });

  test('個人アカウントは本人の職員 ID でしか記録できない（自動処理は可）', async () => {
    const db = personal('haru');
    await assertFails(
      setDoc(doc(db, `facilities/${FAC}/customers/p2`), {
        updatedAt: serverTimestamp(),
        updatedByStaffId: 'natsu',
        updatedByStaffName: '職員 夏男',
      }),
    );
    await assertFails(
      setDoc(doc(db, `facilities/${FAC}/customers/p2`), {
        updatedAt: serverTimestamp(),
        updatedByStaffId: null,
        updatedByStaffName: '職員 夏男',
      }),
    );
    await assertSucceeds(
      setDoc(doc(db, `facilities/${FAC}/attendance/auto2`), {
        updatedAt: serverTimestamp(),
        updatedByStaffId: null,
        updatedByStaffName: '自動',
      }),
    );
  });

  test('共用端末アカウントは従来どおり、選んだ担当者の名前で記録できる', async () => {
    await assertSucceeds(
      setDoc(doc(memberA(), `facilities/${FAC}/customers/s1`), {
        updatedAt: serverTimestamp(),
        updatedByStaffId: 'natsu',
        updatedByStaffName: '職員 夏男',
      }),
    );
  });

  test('所属の無いアカウントは LINE 連携のコレクションを読めない（締めた）', async () => {
    await assertFails(getDoc(doc(noMembership(), 'line_linkage/x1')));
    await assertFails(getDoc(doc(noMembership(), 'notification_logs/2026-11-19_c1')));
    await assertSucceeds(getDoc(doc(memberA(), 'line_linkage/x1')));
  });
});

describe('管理者の権限（アカウントに関わる項目）', () => {
  const PROTECTED = {
    isAdmin: true,
    loginEnabled: true, // 夏男はログイン停止なので、許可に変える
    isActive: false,
    hasGoogleEmail: true,
    deactivatedAt: new Date(2026, 0, 1),
    otherAdminId: 'boss',
    pinHash: 'x',
  };
  const email = (addr) => ({ googleEmail: addr, googleEmailLower: addr.toLowerCase() });

  for (const [label, who, stamp] of [
    // 共用端末で担当者に管理者（管理 一郎）を選んでいる状態
    ['共用端末アカウント（担当者に管理者を選んでいても）', memberA, (x) => by('boss', x)],
    ['管理者でない個人アカウント', () => personal('haru'), (x) => by('haru', x)],
  ]) {
    test(`${label}: アカウントに関わる項目を1つも変えられない`, async () => {
      const db = who();
      for (const [k, v] of Object.entries(PROTECTED)) {
        await assertFails(updateDoc(doc(db, `facilities/${FAC}/staff/natsu`), stamp({ [k]: v })));
      }
    });
    test(`${label}: 職員を登録できない・メールアドレスを読めない・書けない`, async () => {
      const db = who();
      await assertFails(setDoc(doc(db, `facilities/${FAC}/staff/new`), stamp({ name: '新人' })));
      await assertFails(getDoc(doc(db, `facilities/${FAC}/staffAccounts/haru`)));
      await assertFails(getDocs(collection(db, `facilities/${FAC}/staffAccounts`)));
      await assertFails(
        setDoc(doc(db, `facilities/${FAC}/staffAccounts/natsu`), stamp(email('n@example.invalid'))),
      );
    });
    test(`${label}: 氏名・ふりがな・役割・資格・勤務日・送迎の可否は変えられる`, async () => {
      await assertSucceeds(
        updateDoc(
          doc(who(), `facilities/${FAC}/staff/natsu`),
          stamp({
            name: '職員 夏男2',
            kana: 'なつお',
            role: 'driver',
            qualifications: '中型',
            workDays: [1, 2],
            canDrive: true,
          }),
        ),
      );
    });
  }

  test('自分で自分を管理者にできない（管理者でない個人アカウント）', async () => {
    const db = personal('haru');
    await assertFails(updateDoc(doc(db, `facilities/${FAC}/staff/haru`), by('haru', { isAdmin: true })));
    await assertFails(
      setDoc(doc(db, `facilities/${FAC}/staff/haru`), by('haru', { ...PERSONAL_STAFF.haru, isAdmin: true })),
    );
  });

  test('管理者（個人アカウント）は、アカウントに関わる項目を変えられる', async () => {
    const db = personal('boss');
    await assertSucceeds(updateDoc(doc(db, `facilities/${FAC}/staff/haru`), by('boss', { isAdmin: true })));
    // 春子は直前に管理者になったので、ログインの停止は「管理者を減らす変更」。残る管理者を示す
    await assertSucceeds(
      updateDoc(doc(db, `facilities/${FAC}/staff/haru`), by('boss', { loginEnabled: false, otherAdminId: 'boss' })),
    );
    await assertSucceeds(updateDoc(doc(db, `facilities/${FAC}/staff/natsu`), by('boss', { hasGoogleEmail: true })));
    await assertSucceeds(
      updateDoc(doc(db, `facilities/${FAC}/staff/natsu`), by('boss', { isActive: false, deactivatedAt: serverTimestamp() })),
    );
    await assertSucceeds(
      setDoc(doc(db, `facilities/${FAC}/staff/new`), by('boss', { name: '新人', isActive: true, isAdmin: false })),
    );
    await assertSucceeds(getDocs(collection(db, `facilities/${FAC}/staffAccounts`)));
    await assertSucceeds(
      setDoc(doc(db, `facilities/${FAC}/staffAccounts/natsu`), by('boss', email('Natsuo@Example.invalid'))),
    );
    await assertSucceeds(setDoc(doc(db, `facilities/${FAC}/staffAccounts/natsu`), by('boss', email(''))));
  });

  test('管理者でも: 小文字の照合用が合わない・形の違うアドレスは拒否。削除は誰もできない', async () => {
    const db = personal('boss');
    await assertFails(
      setDoc(doc(db, `facilities/${FAC}/staffAccounts/natsu`), by('boss', {
        googleEmail: 'Natsuo@Example.invalid',
        googleEmailLower: 'other@example.invalid',
      })),
    );
    await assertFails(setDoc(doc(db, `facilities/${FAC}/staffAccounts/natsu`), by('boss', email('not-an-address'))));
    await assertFails(deleteDoc(doc(db, `facilities/${FAC}/staffAccounts/haru`)));
    await assertFails(deleteDoc(doc(db, `facilities/${FAC}/staff/haru`)));
    // 在籍終了での登録は不可（在籍終了は更新で行う）
    await assertFails(
      setDoc(doc(db, `facilities/${FAC}/staff/new2`), by('boss', { name: 'x', isActive: false })),
    );
  });

  test('ログインを停止された管理者・在籍終了の管理者は管理者として扱わない', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), `facilities/${FAC}/staff/natsu`), { isAdmin: true });
    });
    // 夏男は管理者だがログイン停止 → 所属自体が無効
    const db = personal('natsu');
    await assertFails(updateDoc(doc(db, `facilities/${FAC}/staff/haru`), by('natsu', { isAdmin: true })));
    await assertFails(getDoc(doc(db, `facilities/${FAC}/staffAccounts/haru`)));
  });

  describe('最後の管理者', () => {
    test('別の管理者を示さないと、管理者を減らす変更はできない', async () => {
      const db = personal('boss');
      await assertFails(updateDoc(doc(db, `facilities/${FAC}/staff/boss`), by('boss', { isAdmin: false })));
      await assertFails(updateDoc(doc(db, `facilities/${FAC}/staff/boss`), by('boss', { loginEnabled: false })));
      await assertFails(updateDoc(doc(db, `facilities/${FAC}/staff/boss`), by('boss', { isActive: false })));
      // 示した職員が管理者でない・自分自身・存在しない
      for (const other of ['haru', 'boss', 'ghost']) {
        await assertFails(
          updateDoc(doc(db, `facilities/${FAC}/staff/boss`), by('boss', { isAdmin: false, otherAdminId: other })),
        );
      }
    });

    test('別の管理者（在籍中・ログイン許可）を示せば外せる', async () => {
      await env.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `facilities/${FAC}/staff/boss2`), {
          name: '管理 二郎', isActive: true, loginEnabled: true, isAdmin: true,
        });
      });
      const db = personal('boss');
      await assertSucceeds(
        updateDoc(doc(db, `facilities/${FAC}/staff/boss2`), by('boss', { isActive: false, otherAdminId: 'boss' })),
      );
      // boss2 が在籍終了になった後は、boss 自身を外すのに boss2 は使えない
      await assertFails(
        updateDoc(doc(db, `facilities/${FAC}/staff/boss`), by('boss', { isAdmin: false, otherAdminId: 'boss2' })),
      );
    });
  });
});
