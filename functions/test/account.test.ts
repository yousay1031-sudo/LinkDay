/**
 * ステップ2: 個人アカウント（Google）の所属を付ける・外す処理と、
 * 「有効な所属が無ければ何も起動できない」ことのテスト。
 *
 * 保存先は FakeFirestore（本物の Firestore・エミュレータには接続しない）。
 * 関数の定義（onCall）を wrap して呼ぶと getFirestore() が本物の保存先を向くため、
 * ここでは中身の処理（claimMembership など）を直接呼ぶ。
 */
import {HttpsError, type CallableRequest} from 'firebase-functions/v2/https';

import {
  accountChangeRevokes,
  claimMembership,
  getValidMembership,
  maskEmail,
  revokePersonalMemberships,
  staffChangeRevokes,
  type TokenClaims,
} from '../src/account/membership';
import {setLineApiForTest} from '../src/line/client';
import {handleSendVacancyNotice} from '../src/sendVacancyNotice';
import {FakeFirestore} from './fakeFirestore';
import {FakeLineApi} from './fakeLineApi';

const FAC = 'fac-a';
const OTHER = 'fac-b';
const STAFF = `facilities/${FAC}/staff`;
const ACCOUNTS = `facilities/${FAC}/staffAccounts`;

let db: FakeFirestore;

/** Google でログインしたときの認証トークン */
const google = (email: string, verified = true): TokenClaims => ({
  email,
  email_verified: verified,
  firebase: {sign_in_provider: 'google.com'},
});

/** 自分で作ったメールアドレスとパスワードのアカウント */
const password = (email: string): TokenClaims => ({
  email,
  email_verified: false,
  firebase: {sign_in_provider: 'password'},
});

beforeEach(() => {
  db = new FakeFirestore();
  db.seed(STAFF, 's-haru', {name: '職員 春子', isActive: true, loginEnabled: true});
  db.seed(ACCOUNTS, 's-haru', {
    googleEmail: 'Haruko@Example.invalid',
    googleEmailLower: 'haruko@example.invalid',
  });
  db.seed(STAFF, 's-natsu', {name: '職員 夏男', isActive: true, loginEnabled: false});
  db.seed(ACCOUNTS, 's-natsu', {
    googleEmail: 'natsuo@example.invalid',
    googleEmailLower: 'natsuo@example.invalid',
  });
  db.seed(STAFF, 's-aki', {name: '職員 秋子', isActive: false, loginEnabled: true});
  db.seed(ACCOUNTS, 's-aki', {
    googleEmail: 'akiko@example.invalid',
    googleEmailLower: 'akiko@example.invalid',
  });
  // 共用端末アカウントの所属（ステップ1の形。kind が無い）
  db.seed('memberships', 'shared-uid', {facilityId: FAC});
});

describe('claimMembership（Google でログインした直後）', () => {
  it('登録済み・在籍中・ログイン許可のアドレスなら所属を作る（大文字・小文字を区別しない）', async () => {
    const r = await claimMembership(db, 'g-uid', google('HARUKO@example.INVALID'));
    expect(r).toEqual({ok: true, facilityId: FAC, staffId: 's-haru'});
    expect(db.get('memberships', 'g-uid')).toMatchObject({
      facilityId: FAC,
      kind: 'personal',
      staffId: 's-haru',
      email: 'haruko@example.invalid',
    });
  });

  it('未登録のアドレスでは何も作らない', async () => {
    const r = await claimMembership(db, 'g-uid', google('stranger@example.invalid'));
    expect(r).toEqual({ok: false, reason: 'not-registered'});
    expect(db.get('memberships', 'g-uid')).toBeUndefined();
  });

  it('ログインの許可が無い・在籍終了の職員では作らない', async () => {
    expect(await claimMembership(db, 'g1', google('natsuo@example.invalid'))).toEqual({
      ok: false,
      reason: 'not-allowed',
    });
    expect(await claimMembership(db, 'g2', google('akiko@example.invalid'))).toEqual({
      ok: false,
      reason: 'not-allowed',
    });
    expect(db.get('memberships', 'g1')).toBeUndefined();
    expect(db.get('memberships', 'g2')).toBeUndefined();
  });

  it('Google が確認済みとしていないアドレスは使わない', async () => {
    const r = await claimMembership(db, 'g-uid', google('haruko@example.invalid', false));
    expect(r).toEqual({ok: false, reason: 'email-not-verified'});
    expect(db.get('memberships', 'g-uid')).toBeUndefined();
  });

  it('自分で作ったメールアドレスのアカウントは、同じアドレスでも所属を作らない', async () => {
    const r = await claimMembership(db, 'pw-uid', password('haruko@example.invalid'));
    expect(r).toEqual({ok: false, reason: 'not-google'});
    expect(db.get('memberships', 'pw-uid')).toBeUndefined();
  });

  it('同じアドレスが2人に登録されていたら（どの事業所でも）作らない', async () => {
    db.seed(`facilities/${OTHER}/staff`, 's-x', {isActive: true, loginEnabled: true});
    db.seed(`facilities/${OTHER}/staffAccounts`, 's-x', {
      googleEmailLower: 'haruko@example.invalid',
    });
    const r = await claimMembership(db, 'g-uid', google('haruko@example.invalid'));
    expect(r).toEqual({ok: false, reason: 'duplicate'});
    expect(db.get('memberships', 'g-uid')).toBeUndefined();
  });

  it('共用端末アカウントの所属は書き換えない', async () => {
    const r = await claimMembership(db, 'shared-uid', google('haruko@example.invalid'));
    expect(r).toEqual({ok: false, reason: 'shared-account'});
    expect(db.get('memberships', 'shared-uid')).toEqual({facilityId: FAC});
  });

  it('前に作った個人アカウントの所属は、一致しなくなっていたら消す', async () => {
    db.seed('memberships', 'g-uid', {facilityId: FAC, kind: 'personal', staffId: 's-natsu'});
    const r = await claimMembership(db, 'g-uid', google('natsuo@example.invalid'));
    expect(r.ok).toBe(false);
    expect(db.get('memberships', 'g-uid')).toBeUndefined();
  });

  it('ログに出すアドレスは伏せる', () => {
    expect(maskEmail('haruko@example.invalid')).toBe('h***@example.invalid');
    expect(maskEmail('bad')).toBe('***');
  });
});

describe('getValidMembership（ルールの membershipOk と同じ判定）', () => {
  it('共用端末（kind なし）は有効', async () => {
    expect(await getValidMembership(db, 'shared-uid')).toEqual({
      facilityId: FAC,
      kind: 'shared',
    });
  });
  it('所属が無ければ null', async () => {
    expect(await getValidMembership(db, 'nobody')).toBeNull();
  });
  it('個人アカウントは職員が在籍中かつログイン許可のときだけ有効', async () => {
    db.seed('memberships', 'p1', {facilityId: FAC, kind: 'personal', staffId: 's-haru'});
    db.seed('memberships', 'p2', {facilityId: FAC, kind: 'personal', staffId: 's-natsu'});
    db.seed('memberships', 'p3', {facilityId: FAC, kind: 'personal', staffId: 's-aki'});
    db.seed('memberships', 'p4', {facilityId: FAC, kind: 'personal', staffId: 'nope'});
    expect(await getValidMembership(db, 'p1')).toMatchObject({staffId: 's-haru'});
    expect(await getValidMembership(db, 'p2')).toBeNull();
    expect(await getValidMembership(db, 'p3')).toBeNull();
    expect(await getValidMembership(db, 'p4')).toBeNull();
  });
});

describe('所属を外す（在籍終了・ログイン停止・アドレスの変更）', () => {
  it('職員が在籍終了・ログイン停止・削除なら外す', () => {
    expect(staffChangeRevokes({isActive: true, loginEnabled: true})).toBe(false);
    expect(staffChangeRevokes({isActive: false, loginEnabled: true})).toBe(true);
    expect(staffChangeRevokes({isActive: true, loginEnabled: false})).toBe(true);
    expect(staffChangeRevokes(undefined)).toBe(true);
  });

  it('アドレスが変わった・消えたら外す（変わらなければ外さない）', () => {
    const a = {googleEmailLower: 'a@example.invalid'};
    const b = {googleEmailLower: 'b@example.invalid'};
    expect(accountChangeRevokes(a, a)).toBe(false);
    expect(accountChangeRevokes(a, b)).toBe(true);
    expect(accountChangeRevokes(a, {googleEmailLower: ''})).toBe(true);
    expect(accountChangeRevokes(a, undefined)).toBe(true);
    expect(accountChangeRevokes(undefined, a)).toBe(true);
  });

  it('その職員の個人アカウントの所属だけを消す（共用端末・他の職員は残す）', async () => {
    db.seed('memberships', 'p1', {facilityId: FAC, kind: 'personal', staffId: 's-haru'});
    db.seed('memberships', 'p1b', {facilityId: FAC, kind: 'personal', staffId: 's-haru'});
    db.seed('memberships', 'p2', {facilityId: FAC, kind: 'personal', staffId: 's-natsu'});
    db.seed('memberships', 'odd', {facilityId: FAC, staffId: 's-haru'}); // kind なし = 共用
    const n = await revokePersonalMemberships(db, FAC, 's-haru');
    expect(n).toBe(2);
    expect(db.get('memberships', 'p1')).toBeUndefined();
    expect(db.get('memberships', 'p1b')).toBeUndefined();
    expect(db.get('memberships', 'p2')).toBeDefined();
    expect(db.get('memberships', 'odd')).toBeDefined();
    expect(db.get('memberships', 'shared-uid')).toBeDefined();
  });
});

describe('sendVacancyNotice: 有効な所属が無ければ起動できない', () => {
  let line: FakeLineApi;
  beforeEach(() => {
    line = new FakeLineApi();
    setLineApiForTest(line);
  });
  afterEach(() => setLineApiForTest(null));

  const req = (uid: string, token: TokenClaims): CallableRequest<unknown> =>
    ({
      data: {
        date: '2026-10-02',
        message: 'テスト',
        recipients: [
          {customerId: 'c1', lineUserId: 'U' + 'a'.repeat(32), childName: 'テスト'},
        ],
      },
      auth: {uid, token},
      rawRequest: {},
      acceptsStreaming: false,
    }) as unknown as CallableRequest<unknown>;

  const cases: Array<[string, string, TokenClaims, () => void]> = [
    ['未登録の Google アカウント', 'g-new', google('stranger@example.invalid'), () => {}],
    ['自分で作ったメールアドレスのアカウント', 'pw-new', password('x@example.invalid'), () => {}],
    [
      '在籍終了の職員の個人アカウント（所属の文書が残っていても）',
      'p-aki',
      google('akiko@example.invalid'),
      () =>
        db.seed('memberships', 'p-aki', {facilityId: FAC, kind: 'personal', staffId: 's-aki'}),
    ],
    [
      'ログイン停止の職員の個人アカウント',
      'p-natsu',
      google('natsuo@example.invalid'),
      () =>
        db.seed('memberships', 'p-natsu', {
          facilityId: FAC,
          kind: 'personal',
          staffId: 's-natsu',
        }),
    ],
  ];
  for (const [name, uid, token, setup] of cases) {
    it(`${name}は permission-denied で拒否され、LINE に送信されない`, async () => {
      setup();
      const p = handleSendVacancyNotice(req(uid, token), db.asFirestore(), 'dummy-token');
      await expect(p).rejects.toThrow(HttpsError);
      await expect(
        handleSendVacancyNotice(req(uid, token), db.asFirestore(), 'dummy-token')
      ).rejects.toMatchObject({code: 'permission-denied'});
      expect(line.pushCalls).toHaveLength(0);
      expect(db.docs('notification_logs')).toEqual({});
    });
  }

  it('有効な個人アカウント（在籍中・ログイン許可）は送信できる', async () => {
    db.seed('memberships', 'p-haru', {facilityId: FAC, kind: 'personal', staffId: 's-haru'});
    const out = await handleSendVacancyNotice(
      req('p-haru', google('haruko@example.invalid')),
      db.asFirestore(),
      'dummy-token'
    );
    expect(out.sentCount).toBe(1);
  });
});
