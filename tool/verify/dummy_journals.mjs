// 検証用の業務日誌（架空。ステップ3）。facilities/{facilityId}/dailyJournals/{YYYY-MM-DD}。
//
// 昨日と一昨日の 2 件。今日の分は置かない（画面から新しく作る確認のため）。
// 一昨日の分には、設定の初期の選択肢に無い名前（「設定から消した選択肢」）を入れ、
// 選択肢を消しても過去の日誌に名前が残ることを確かめられるようにする。
// 値の形は lib/models/daily_journal.dart の toFirestoreData と同じ。
import { ymd } from './dummy_schedule.mjs';

const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

export function buildDemoJournals(today) {
  const y1 = addDays(today, -1);
  const y2 = addDays(today, -2);
  return [
    {
      id: ymd(y1),
      data: {
        date: ymd(y1),
        staff: [
          { staffId: 'dummy-s001', name: '職員 春子' },
          { staffId: 'dummy-s003', name: '職員 秋子' },
        ],
        activities: ['外遊び', 'おやつ', '宿題・学習'],
        note: '検証用ダミーの備考（架空）。公園で外遊び。',
      },
    },
    {
      id: ymd(y2),
      data: {
        date: ymd(y2),
        staff: [{ staffId: 'dummy-s002', name: '職員 夏男' }],
        activities: ['室内遊び', '検証用の消した選択肢'],
        note: '',
      },
    },
  ];
}
