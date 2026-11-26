// 検証用の個別支援計画（架空。ステップ3）。facilities/{facilityId}/supportPlans/{planId}。
//
// 文章はすべて架空のもの（実在の児童・支援の内容ではない）。値の形は
// lib/models/support_plan.dart の toFirestoreData と同じ。
//
// 更新期限（作成年月日の 6 か月後）の知らせを確かめられるよう、作成年月日をずらす。
//   001: 同意済み・作成 150 日前   → 期限まで約 1 か月（アセスメントの時期）
//   002: 同意済み・作成 175 日前   → 期限まで約 1 週間（更新期限が近い）
//   003: 同意済み・作成 190 日前   → 期限を過ぎている
//   004: 同意済み・作成 30 日前（新しい）＋ 210 日前（古い）→ 知らせなし・履歴が 2 件
//   005: 作成中だけ・作成 160 日前 → 作成中の作成年月日を仮の起点にして知らせる
//   006: 必須の行が足りない作成中・作成 5 日前 → 足りない点の表示の確認用
//   007〜058: 同意済み・作成 10〜69 日前 → 知らせなし
//   059・060: 計画なし → 「個別支援計画がまだありません」
import { buildCustomer, customerId } from './dummy_customers.mjs';
import { ymd } from './dummy_schedule.mjs';

const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

const row = (categories, goal, content, extra = {}) => ({
  categories,
  texts: { goal, content, period: '6か月後', provider: '検証用デイサービス（ダミー）', notes: '' },
  domains: [],
  staff: [{ staffId: 'dummy-s001', name: '職員 春子' }],
  priority: null,
  ...extra,
});

function fullRows() {
  return [
    row(['self'], '検証用ダミーの本人支援の目標（架空）', '検証用ダミーの支援内容（架空）', {
      domains: ['health', 'motor', 'cognition'],
      priority: 1,
    }),
    row(['self', 'transition'], '検証用ダミーの本人支援・移行支援の目標（架空）', '検証用ダミーの支援内容（架空）', {
      domains: ['language', 'social'],
      priority: 2,
    }),
    row(['family'], '検証用ダミーの家族支援の目標（架空）', '検証用ダミーの家族支援の内容（架空）'),
    row(['community'], '検証用ダミーの地域連携の目標（架空）', '検証用ダミーの連携の内容（架空）'),
  ];
}

function plan(n, today, daysAgo, { agreed = true, rows = fullRows(), suffix = '' } = {}) {
  const c = buildCustomer(n, today);
  const created = addDays(today, -daysAgo);
  return {
    id: `dummy-plan-${customerId(n)}${suffix}`,
    data: {
      customerId: c.id,
      customerName: c.data.name,
      birthday: c.data.birthday ?? null,
      createdOn: ymd(created),
      managerStaffId: 'dummy-s001',
      managerName: '職員 春子',
      texts: {
        intention: '検証用ダミーの意向（架空）。楽しく通いたい（本人）。',
        policy: '検証用ダミーの総合的な支援の方針（架空）。',
        longTerm: '検証用ダミーの長期目標（架空）',
        shortTerm: '検証用ダミーの短期目標（架空）',
        standardTime: '月・水・金曜日　14:30〜17:30',
      },
      rows,
      explainedOn: agreed ? ymd(created) : null,
      agreedOn: agreed ? ymd(addDays(created, 2)) : null,
      status: agreed ? 'agreed' : 'draft',
      assessmentDoneOn: null,
      copiedFromPlanId: null,
    },
  };
}

export function buildDemoPlans(today) {
  const list = [
    plan(1, today, 150),
    plan(2, today, 175),
    plan(3, today, 190),
    plan(4, today, 30),
    plan(4, today, 210, { suffix: '-old' }),
    plan(5, today, 160, { agreed: false }),
    plan(6, today, 5, { agreed: false, rows: [fullRows()[0]] }),
  ];
  for (let n = 7; n <= 58; n++) list.push(plan(n, today, 10 + (n % 60)));
  return list;
}
