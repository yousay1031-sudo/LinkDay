// 検証用の週間利用計画（先週・今週・来週）。
//
// lib/verify/verify_seed.dart の VerifySeed.buildDemoWeeks と同じ規則で作る。
// 週間利用計画は Firestore（段階4）、出席・送迎はまだ Hive 側（アプリが投入）で、
// 今日の出席・送迎は「今日のスロット」から作るため、両方の内容がそろっている必要がある。
// 片方を変えたらもう片方も変えること。
import { buildCustomer, CUSTOMER_COUNT, customerId } from './dummy_customers.mjs';

const TODAY_ABSENT_NUMBERS = [3, 7];

const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
const dayOfWeek = (d) => (d.getDay() === 0 ? 7 : d.getDay()); // 1=月〜7=日（Dart と同じ）
export const ymd = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const daysBetween = (a, b) => Math.round((a - b) / 86400000);
// Dart の String.compareTo と同じ（UTF-16 コード単位の比較）
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

export const weekStartFromDate = (d) => addDays(d, -(dayOfWeek(d) - 1));

/** lib/utils/week_util.dart の weekKeyFromDate と同じ計算 */
export function weekKeyFromDate(d) {
  const monday = weekStartFromDate(d);
  const firstMonday = weekStartFromDate(new Date(monday.getFullYear(), 0, 4));
  const weekNum = Math.floor(daysBetween(monday, firstMonday) / 7) + 1;
  if (weekNum < 1) {
    const prevFirst = weekStartFromDate(new Date(monday.getFullYear() - 1, 0, 4));
    const prevNum = Math.floor(daysBetween(monday, prevFirst) / 7) + 1;
    return `${monday.getFullYear() - 1}-W${String(prevNum).padStart(2, '0')}`;
  }
  if (weekNum > 52) {
    const nextFirst = weekStartFromDate(new Date(monday.getFullYear() + 1, 0, 4));
    if (!(monday < nextFirst)) return `${monday.getFullYear() + 1}-W01`;
  }
  return `${monday.getFullYear()}-W${String(weekNum).padStart(2, '0')}`;
}

function buildFromRegularDays(monday, active) {
  return Array.from({ length: 7 }, (_, i) => {
    const date = addDays(monday, i);
    const dow = dayOfWeek(date);
    const entries = active
      .filter((c) => c.data.regularDays.includes(dow))
      .map((c) => ({ customerId: c.id, customerName: c.data.name, status: 'planned', plannedStartTime: null, plannedEndTime: null }))
      .sort((a, b) => cmp(a.customerName, b.customerName));
    return { date, entries };
  });
}

/** 先週・今週・来週 → [{ weekKey, monday, slots: [{date, entries}] }] */
export function buildDemoWeeks(today) {
  const active = [];
  for (let n = 1; n <= CUSTOMER_COUNT; n++) active.push(buildCustomer(n, today));
  const monday = weekStartFromDate(today);
  const weeks = [-7, 0, 7].map((off) => {
    const ws = addDays(monday, off);
    const slots = buildFromRegularDays(ws, active);
    for (const slot of slots) {
      slot.entries.forEach((e, i) => {
        e.plannedStartTime ??= i % 2 === 0 ? '10:00' : '13:30';
        e.plannedEndTime ??= i % 2 === 0 ? '16:00' : '17:30';
      });
    }
    return { weekKey: weekKeyFromDate(ws), monday: ws, slots };
  });
  const slot = weeks[1].slots.find((s) => ymd(s.date) === ymd(today));
  const have = new Set(slot.entries.map((e) => e.customerId));
  const mustHave = new Set(TODAY_ABSENT_NUMBERS.map(customerId));
  let added = 0;
  for (const c of active) {
    if (slot.entries.length >= 14 && [...mustHave].every((id) => have.has(id))) break;
    if (have.has(c.id)) continue;
    if (slot.entries.length >= 14 && !mustHave.has(c.id)) continue;
    slot.entries.push({
      customerId: c.id,
      customerName: c.data.name,
      status: 'additional',
      plannedStartTime: added % 2 === 0 ? '10:00' : '13:30',
      plannedEndTime: added % 2 === 0 ? '16:00' : '17:30',
    });
    have.add(c.id);
    added++;
  }
  if (slot.entries.length > 3) slot.entries[slot.entries.length - 1].status = 'cancelled';
  return weeks;
}

/** Firestore に置く形（lib/services/weekly_schedule_service.dart の _docsOf / _markerData と同じ） */
export function scheduleDocs(weeks) {
  const markers = weeks.map((w) => ({
    id: w.weekKey,
    data: { weekKey: w.weekKey, weekStartDate: ymd(w.monday), note: null },
  }));
  const entries = [];
  for (const w of weeks) {
    for (const s of w.slots) {
      for (const e of s.entries) {
        entries.push({
          id: `${ymd(s.date)}_${e.customerId}`,
          data: {
            date: ymd(s.date),
            weekKey: w.weekKey,
            customerId: e.customerId,
            customerName: e.customerName,
            status: e.status,
            plannedStartTime: e.plannedStartTime,
            plannedEndTime: e.plannedEndTime,
            transportLocationIndex: null,
            note: null,
          },
        });
      }
    }
  }
  return { markers, entries };
}
