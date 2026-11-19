// 検証用の出席記録（架空）。直近 5 日の実績 + 今日の混在（予定 / 在室 / 退室済 / 欠席）。
//
// 以前 lib/verify/verify_seed.dart が Hive に入れていたものと同じ規則
// （出席は段階5で Firestore へ移した）。今日の対象は週間利用計画の今日のスロット
// （dummy_schedule.mjs の buildDemoWeeks。キャンセルは除く）。
import { buildCustomer, CUSTOMER_COUNT } from './dummy_customers.mjs';
import { buildDemoWeeks, ymd } from './dummy_schedule.mjs';

const TODAY_ABSENT_NUMBERS = [3, 7];
const ID_PREFIX = 'dummy-c';
const at = (d, h, m) => new Date(d.getFullYear(), d.getMonth(), d.getDate(), h, m);
const dayOfWeek = (d) => (d.getDay() === 0 ? 7 : d.getDay());

function record(customerId, customerName, date, status, extra = {}) {
  return {
    id: `${ymd(date)}_${customerId}`,
    data: {
      date: ymd(date),
      customerId,
      customerName,
      status,
      plannedStartTime: at(date, 10, 0),
      plannedEndTime: at(date, 16, 0),
      checkInTime: null,
      checkOutTime: null,
      absenceReason: null,
      note: null,
      checkInByStaffId: null,
      checkInByStaffName: null,
      checkOutByStaffId: null,
      checkOutByStaffName: null,
      ...extra,
    },
  };
}

export function buildDemoAttendance(today) {
  const active = [];
  for (let n = 1; n <= CUSTOMER_COUNT; n++) active.push(buildCustomer(n, today));
  const out = [];
  // 直近 5 日の実績
  for (let back = 1; back <= 5; back++) {
    const d = new Date(today.getFullYear(), today.getMonth(), today.getDate() - back);
    let i = 0;
    for (const c of active) {
      if (!c.data.regularDays.includes(dayOfWeek(d))) continue;
      const absent = i % 9 === 4;
      out.push(record(c.id, c.data.name, d, absent ? 'absent' : 'departed', absent
        ? { absenceReason: '体調不良' }
        : { checkInTime: at(d, 10, i % 20), checkOutTime: at(d, 16, i % 25) }));
      i++;
    }
  }
  // 今日: 週間利用計画の今日のスロット（キャンセル以外）
  const weeks = buildDemoWeeks(today);
  const slot = weeks[1].slots.find((s) => ymd(s.date) === ymd(today));
  let k = 0;
  for (const e of slot.entries) {
    if (e.status === 'cancelled') continue;
    const n = Number(e.customerId.slice(ID_PREFIX.length)) || 0;
    const st = TODAY_ABSENT_NUMBERS.includes(n)
      ? 'absent'
      : ['scheduled', 'present', 'departed', 'scheduled'][k % 4];
    k++;
    out.push(record(e.customerId, e.customerName, today, st, {
      checkInTime: st === 'present' || st === 'departed' ? at(today, 10, k % 30) : null,
      checkOutTime: st === 'departed' ? at(today, 15, 30) : null,
      absenceReason: st === 'absent' ? '家庭の都合' : null,
    }));
  }
  return out;
}
