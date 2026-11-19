// 検証用の架空の顧客（実在の人物・住所・LINE userId ではない）。
//
// lib/verify/verify_seed.dart の VerifySeed.buildCustomer と同じ規則・同じ ID で作る。
// 顧客は Firestore（段階3）、出席・週間計画などはまだ Hive 側（アプリが投入）なので、
// 両方で ID と氏名がそろっている必要がある。片方を変えたらもう片方も変えること。

export const CUSTOMER_COUNT = 60; // 在籍中。61 番は在籍終了
export const customerId = (n) => `dummy-c${String(n).padStart(3, '0')}`;

const SURNAMES = ['検証', 'テスト', '見本', '試験', '仮名', '例示'];
const GIVEN = [
  ['一郎', 'イチロウ'], ['花子', 'ハナコ'], ['次郎', 'ジロウ'], ['桃子', 'モモコ'],
  ['三郎', 'サブロウ'], ['梅子', 'ウメコ'], ['四郎', 'シロウ'], ['菊子', 'キクコ'],
  ['五郎', 'ゴロウ'], ['藤子', 'フジコ'],
];
const SURNAME_KANA = ['ケンショウ', 'テスト', 'ミホン', 'シケン', 'カメイ', 'レイジ'];
const AREAS = [
  '帯広市西2条南9丁目（検証用）', '帯広市東3条南5丁目（検証用）',
  '帯広市稲田町西2線（検証用）', '帯広市大空町3丁目（検証用）',
  '帯広市西19条南4丁目（検証用）', '音更町木野大通西（検証用）',
  '帯広市柏林台西町（検証用）', '帯広市自由が丘（検証用）',
];
const DAY_PATTERNS = [[1, 3, 5], [2, 4], [1, 2, 3, 4, 5], [6], [1, 5, 6], [3, 4, 5]];

const ymd = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

/** 顧客 n 番（1 始まり）。値は Firestore に置く形（lib/models/customer.dart の toFirestoreData と同じ） */
export function buildCustomer(n, now) {
  const g = GIVEN[Math.floor(n / 2) % GIVEN.length];
  let name = `${SURNAMES[n % SURNAMES.length]} ${g[0]}`;
  let kana = `${SURNAME_KANA[n % SURNAME_KANA.length]} ${g[1]}`;
  if (n % 15 === 0) {
    name = `検証用ダミーの非常に長い氏名 ${g[0]}ジョセフ`;
    kana = `ケンショウヨウダミー ${g[1]}`;
  }
  const area = AREAS[n % AREAS.length];
  const addresses = [`${area} ${n}番`];
  if (n % 4 === 0) addresses.push(`帯広市（検証用・祖父母宅）${n + 100}番`);
  const transportLocations = addresses.map((address, i) => {
    const k = (n + i) % 5;
    let lat = null, lng = null, status = 'unresolved';
    if (k === 0 || k === 1) {
      lat = 42.92 + (n % 9) * 0.004 + i * 0.002;
      lng = 143.19 + (n % 7) * 0.005 + i * 0.002;
      status = 'resolved';
    } else if (k === 2) {
      lat = 42.91 + (n % 6) * 0.005;
      lng = 143.20 + (n % 5) * 0.004;
      status = 'manual';
    } else if (k === 3) {
      status = 'failed';
    }
    return { address, lat, lng, status, formattedAddress: null, types: [] };
  });
  const expiry = n % 10 === 4 ? addDays(now, 5 + (n % 20)) : addDays(now, 200 + n);
  return {
    id: customerId(n),
    data: {
      name,
      nameKana: kana,
      birthday: ymd(new Date(2012 + (n % 6), n % 12, 1 + (n % 27))),
      gender: n % 2 === 0 ? '男児' : '女児',
      phone: null,
      // 架空の規則的な LINE userId（U + 32 桁 16 進。実在しない）。検証構成では送信しない
      lineUserId: n % 3 === 0 ? `U${'0'.repeat(24)}${n.toString(16).padStart(8, '0')}` : null,
      guardianName: `保護者${n}（ダミー）`,
      guardianPhone: `090-0000-${String(n).padStart(4, '0')}`,
      recipientCertNumber: String(1000000000 + n),
      recipientCertExpiry: ymd(expiry),
      monthlyAvailableDays: n % 9 === 0 ? 8 : n % 11 === 0 ? 12 : 23,
      currentMonthUsedDays: 0,
      regularDays: DAY_PATTERNS[n % DAY_PATTERNS.length],
      transportLocations,
      notes: n % 7 === 0 ? 'ダミー備考: アレルギー確認の表示テスト用' : null,
      isActive: n <= CUSTOMER_COUNT,
    },
  };
}

/** JS の値 → Firestore REST の値（lat/lng など小数は doubleValue） */
export function toFsValue(v, key = '') {
  if (v === null || v === undefined) return { nullValue: null };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'string') return { stringValue: v };
  if (typeof v === 'number') {
    if ((key === 'lat' || key === 'lng') || !Number.isInteger(v)) return { doubleValue: v };
    return { integerValue: String(v) };
  }
  if (Array.isArray(v)) return { arrayValue: { values: v.map((e) => toFsValue(e)) } };
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  return { mapValue: { fields: toFsFields(v) } };
}

export const toFsFields = (obj) =>
  Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, toFsValue(v, k)]));
