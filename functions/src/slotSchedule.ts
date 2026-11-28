/**
 * slotSchedule — 空き枠の確定・取り消しを、その日の予定（週間利用計画・出席）に反映する
 *
 * 【前提】
 *  - 反映先の事業所は、空き枠の記録の facilityId だけで決める（通知を送った職員の所属から
 *    sendVacancyNotice が書いた値）。facilityId が無い古い枠は予定に入れない。
 *  - 先着の確定（claimSlot）・取り消し（releaseSlot）と同じ transaction の中で読み書きする。
 *    「確定したのに予定に入っていない」状態を作らないため。
 *  - transaction の中では、読み取りをすべて済ませてから書く（Firestore の決まり）。
 *
 * 【アプリと同じ形で書く】（lib/services/weekly_schedule_service.dart・attendance_service.dart）
 *  - facilities/{f}/scheduleEntries/{YYYY-MM-DD}_{customerId}
 *  - facilities/{f}/scheduleWeeks/{YYYY-Www}（週の目印。無ければ利用曜日から週を作る）
 *  - facilities/{f}/attendance/{YYYY-MM-DD}_{customerId}（今日と過ぎた日だけ。明日以降は
 *    その日に出席管理を開いたとき、アプリが週間利用計画から作る）
 *  - 記録の欄（updatedAt / updatedByStaffId / updatedByStaffName / createdAt）は
 *    「LINEの応募」（担当者 ID なし）で付ける。
 *  - 応募で入れた印は lineClaim（予定と出席の文書に足す項目。アプリは書き換えない）。
 */
import {FieldValue} from 'firebase-admin/firestore';
import type {Firestore, Transaction} from 'firebase-admin/firestore';

/** 記録の欄に残す名前（担当者 ID は無し） */
export const LINE_CLAIM_STAFF_NAME = 'LINEの応募';

/** 週の自動作成に使う名前（アプリの AuditStamp.auto と同じ） */
const AUTO_STAFF_NAME = '自動';

/** 時刻の計算に使う時差（事業所は日本） */
const JST_OFFSET_MS = 9 * 3600 * 1000;

/** 予定への反映の結果 */
export type ScheduleOutcome =
  | 'added' // 予定に「追加」として入れた
  | 'restored_from_cancelled' // 予定では「お休み」だったのを「追加」にした
  | 'already_in_plan' // すでに予定に入っていた（二重に入れない）
  | 'no_facility' // 事業所が書かれていない古い枠（予定に入れない）
  | 'not_enrolled' // その事業所に在籍していない（確定しない）
  | 'removed' // 取り消しで予定から外した
  | 'kept_checked_in' // 取り消されたが入室の記録があるので残した
  | 'not_ours' // 取り消されたが、この枠で入れた予定ではない（何もしない）
  | 'none';

const entryId = (dateKey: string, customerId: string) =>
  `${dateKey}_${customerId}`;

const fpath = (facilityId: string, col: string) =>
  `facilities/${facilityId}/${col}`;

/** "YYYY-MM-DD" → その日（UTC の 0 時として扱う。曜日・週の計算だけに使う） */
function dayOf(dateKey: string): Date | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateKey);
  if (!m) return null;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return isNaN(d.getTime()) ? null : d;
}

const keyOf = (d: Date) =>
  `${d.getUTCFullYear().toString().padStart(4, '0')}-` +
  `${(d.getUTCMonth() + 1).toString().padStart(2, '0')}-` +
  `${d.getUTCDate().toString().padStart(2, '0')}`;

/** 1=月〜7=日（アプリの DateTime.weekday と同じ） */
const weekdayOf = (d: Date) => ((d.getUTCDay() + 6) % 7) + 1;

const addDays = (d: Date, n: number) =>
  new Date(d.getTime() + n * 24 * 3600 * 1000);

const mondayOf = (d: Date) => addDays(d, -(weekdayOf(d) - 1));

/** ISO 8601 の週のキー（アプリの WeekUtil.weekKeyFromDate と同じ結果） */
export function weekKeyOf(dateKey: string): string | null {
  const d = dayOf(dateKey);
  if (d === null) return null;
  const monday = mondayOf(d);
  const thursday = addDays(monday, 3);
  const year = thursday.getUTCFullYear();
  const firstMonday = mondayOf(new Date(Date.UTC(year, 0, 4)));
  const week =
    Math.floor((monday.getTime() - firstMonday.getTime()) / (7 * 86400000)) + 1;
  return `${year}-W${week.toString().padStart(2, '0')}`;
}

/** 日本時間の今日（"YYYY-MM-DD"） */
export function todayKeyJst(now: Date): string {
  return keyOf(new Date(now.getTime() + JST_OFFSET_MS));
}

/** "YYYY-MM-DD" と "HH:mm"（日本時間）→ その時刻（アプリの出席の予定時刻と同じ値） */
function jstTime(dateKey: string, hm: string | null): Date | null {
  if (hm === null) return null;
  const d = dayOf(dateKey);
  const m = /^(\d{1,2}):(\d{2})$/.exec(hm);
  if (d === null || !m) return null;
  return new Date(d.getTime() + (+m[1] * 60 + +m[2]) * 60000 - JST_OFFSET_MS);
}

const str = (v: unknown): string | null =>
  typeof v === 'string' && v.length > 0 ? v : null;

/**
 * ふだんの利用時間: 同じ週のほかの日の予定の時間で一番多いもの（同数なら近い日）。
 * アプリの「追加」（WeeklyScheduleService.sameWeekTimesFor）と同じ決め方。無ければ空。
 */
export function usualTimes(
  weekEntries: Array<Record<string, unknown>>,
  customerId: string,
  dateKey: string
): {start: string | null; end: string | null} {
  const target = dayOf(dateKey);
  const counts = new Map<string, number>();
  const nearest = new Map<string, number>();
  for (const e of weekEntries) {
    if (e.customerId !== customerId || e.date === dateKey) continue;
    const s = str(e.plannedStartTime);
    const t = str(e.plannedEndTime);
    if (s === null && t === null) continue;
    const k = JSON.stringify([s, t]);
    counts.set(k, (counts.get(k) ?? 0) + 1);
    const d = dayOf(String(e.date ?? ''));
    const dist =
      d === null || target === null
        ? 99
        : Math.abs(Math.round((d.getTime() - target.getTime()) / 86400000));
    nearest.set(k, Math.min(nearest.get(k) ?? 99, dist));
  }
  let best: string | null = null;
  for (const k of counts.keys()) {
    if (
      best === null ||
      counts.get(k)! > counts.get(best)! ||
      (counts.get(k) === counts.get(best) && nearest.get(k)! < nearest.get(best)!)
    ) {
      best = k;
    }
  }
  if (best === null) return {start: null, end: null};
  const [s, t] = JSON.parse(best) as [string | null, string | null];
  return {start: s, end: t};
}

function stamp(name: string, create: boolean): Record<string, unknown> {
  return {
    updatedAt: FieldValue.serverTimestamp(),
    updatedByStaffId: null,
    updatedByStaffName: name,
    ...(create ? {createdAt: FieldValue.serverTimestamp()} : {}),
  };
}

/** 確定の書き込み（読み取りを済ませた後に [apply] で書く） */
export interface ClaimPlan {
  outcome: ScheduleOutcome;
  apply: (tx: Transaction) => void;
}

const NOOP = (): void => undefined;

/**
 * 確定のときの読み取り（transaction の中・書き込みの前に呼ぶ）。
 *
 * @param facilityId 空き枠に書かれた事業所（無ければ予定に入れない）
 */
export async function readClaimPlan(
  db: Firestore,
  tx: Transaction,
  p: {
    facilityId: string | null;
    slotId: string;
    dateKey: string;
    customerId: string;
    now: Date;
  }
): Promise<ClaimPlan> {
  if (p.facilityId === null) return {outcome: 'no_facility', apply: NOOP};
  const fid = p.facilityId;
  const weekKey = weekKeyOf(p.dateKey);
  const day = dayOf(p.dateKey);
  if (weekKey === null || day === null) {
    return {outcome: 'not_enrolled', apply: NOOP};
  }

  // 在籍の確認（その事業所の児童で、在籍中）
  const custRef = db.collection(fpath(fid, 'customers')).doc(p.customerId);
  const cust = await tx.get(custRef);
  const c = cust.exists ? (cust.data() as Record<string, unknown>) : null;
  if (c === null || c.isActive !== true) {
    return {outcome: 'not_enrolled', apply: NOOP};
  }
  const name = str(c.name) ?? '';

  const entriesCol = db.collection(fpath(fid, 'scheduleEntries'));
  const weeksCol = db.collection(fpath(fid, 'scheduleWeeks'));
  const attCol = db.collection(fpath(fid, 'attendance'));
  const marker = await tx.get(weeksCol.doc(weekKey));
  const weekSnap = await tx.get(entriesCol.where('weekKey', '==', weekKey));
  const weekEntries = weekSnap.docs.map(
    (d) => d.data() as Record<string, unknown>
  );
  const id = entryId(p.dateKey, p.customerId);
  const existing = weekSnap.docs.find((d) => d.id === id);
  const cur = existing ? (existing.data() as Record<string, unknown>) : null;

  // 今日と過ぎた日だけ出席の予定も書く（明日以降はその日にアプリが作る）
  const writeAttendance = p.dateKey <= todayKeyJst(p.now);
  const attSnap = writeAttendance ? await tx.get(attCol.doc(id)) : null;
  const att =
    attSnap !== null && attSnap.exists
      ? (attSnap.data() as Record<string, unknown>)
      : null;

  // 週の目印もマスも無い週: アプリと同じく利用曜日から週を作る
  const weekMissing = !marker.exists && weekSnap.docs.length === 0;
  // 週を作るときの各日の利用者（その日の対象の児童は「追加」で書くので除く）
  const weekDays = weekMissing
    ? Array.from({length: 7}, (_, i) => addDays(mondayOf(day), i))
    : [];
  let allCustomers: Array<{id: string; name: string; days: number[]}> = [];
  if (weekMissing) {
    const all = await tx.get(
      db.collection(fpath(fid, 'customers')).where('isActive', '==', true)
    );
    allCustomers = all.docs.map((d) => {
      const x = d.data() as Record<string, unknown>;
      return {
        id: d.id,
        name: str(x.name) ?? '',
        days: Array.isArray(x.regularDays)
          ? (x.regularDays as unknown[]).filter(
              (n): n is number => typeof n === 'number'
            )
          : [],
      };
    });
  }

  const curStatus = cur === null ? null : str(cur.status) ?? 'planned';
  // 出席の予定がすでにある（お休み以外）も、予定に入っているものとして扱う
  const attActive = att !== null && att.status !== 'absent';
  if (curStatus === 'planned' || curStatus === 'additional' || attActive) {
    // すでに予定に入っている（二重に入れない・予定は変えない）
    return {outcome: 'already_in_plan', apply: NOOP};
  }

  const times = usualTimes(weekEntries, p.customerId, p.dateKey);
  const mark = {
    slotId: p.slotId,
    customerId: p.customerId,
    claimedAt: p.now,
    via: 'line',
    // 予定では「お休み」だった（取り消されたら元に戻すため）
    prev:
      cur === null
        ? null
        : {
            status: curStatus,
            plannedStartTime: str(cur.plannedStartTime),
            plannedEndTime: str(cur.plannedEndTime),
          },
    prevAttendance:
      att === null
        ? null
        : {
            status: str(att.status) ?? 'scheduled',
            absenceReason: str(att.absenceReason),
          },
  };
  const start = cur !== null ? str(cur.plannedStartTime) ?? times.start : times.start;
  const end = cur !== null ? str(cur.plannedEndTime) ?? times.end : times.end;
  const outcome: ScheduleOutcome =
    cur === null ? 'added' : 'restored_from_cancelled';
  // 出席: 入室・退室の記録があるものは触らない
  const attBusy =
    att !== null &&
    (att.checkInTime != null ||
      att.status === 'present' ||
      att.status === 'departed');

  return {
    outcome,
    apply: (t) => {
      if (weekMissing) {
        t.set(weeksCol.doc(weekKey), {
          weekKey,
          weekStartDate: keyOf(mondayOf(day)),
          note: null,
          ...stamp(AUTO_STAFF_NAME, true),
        });
        for (const d of weekDays) {
          const dk = keyOf(d);
          for (const x of allCustomers) {
            if (!x.days.includes(weekdayOf(d))) continue;
            if (dk === p.dateKey && x.id === p.customerId) continue;
            t.set(entriesCol.doc(entryId(dk, x.id)), {
              date: dk,
              weekKey,
              customerId: x.id,
              customerName: x.name,
              status: 'planned',
              plannedStartTime: null,
              plannedEndTime: null,
              transportLocationIndex: null,
              note: null,
              ...stamp(AUTO_STAFF_NAME, true),
            });
          }
        }
      }
      t.set(
        entriesCol.doc(id),
        {
          date: p.dateKey,
          weekKey,
          customerId: p.customerId,
          customerName: name || str(cur?.customerName) || '',
          status: 'additional',
          plannedStartTime: start,
          plannedEndTime: end,
          transportLocationIndex:
            cur !== null && typeof cur.transportLocationIndex === 'number'
              ? cur.transportLocationIndex
              : null,
          note: cur !== null ? str(cur.note) : null,
          lineClaim: mark,
          ...stamp(LINE_CLAIM_STAFF_NAME, cur === null),
        },
        {merge: true}
      );
      if (writeAttendance && !attBusy) {
        t.set(
          attCol.doc(id),
          {
            date: p.dateKey,
            customerId: p.customerId,
            customerName: name,
            status: 'scheduled',
            plannedStartTime: jstTime(p.dateKey, start),
            plannedEndTime: jstTime(p.dateKey, end),
            checkInTime: null,
            checkOutTime: null,
            absenceReason: null,
            lineClaim: mark,
            ...stamp(LINE_CLAIM_STAFF_NAME, att === null),
          },
          {merge: true}
        );
      }
    },
  };
}

/**
 * 取り消しのときの読み取り（transaction の中・書き込みの前に呼ぶ）。
 *
 * この枠の確定で入れた予定（lineClaim.slotId が一致）だけを外す。
 *  - 入室の記録がある（在室中・退室済・入室時刻あり）→ 外さずに、取り消された印を残す
 *  - 予定で「お休み」だったのを「追加」にした → 元の「お休み」に戻す
 *  - それ以外 → 予定と出席の予定を消す
 */
export async function readReleasePlan(
  db: Firestore,
  tx: Transaction,
  p: {
    facilityId: string | null;
    slotId: string;
    dateKey: string;
    customerId: string;
    now: Date;
  }
): Promise<ClaimPlan> {
  if (p.facilityId === null) return {outcome: 'no_facility', apply: NOOP};
  const fid = p.facilityId;
  const id = entryId(p.dateKey, p.customerId);
  const entryRef = db.collection(fpath(fid, 'scheduleEntries')).doc(id);
  const attRef = db.collection(fpath(fid, 'attendance')).doc(id);
  const e = await tx.get(entryRef);
  const a = await tx.get(attRef);
  const cur = e.exists ? (e.data() as Record<string, unknown>) : null;
  const att = a.exists ? (a.data() as Record<string, unknown>) : null;
  const mark =
    cur !== null && cur.lineClaim !== null && typeof cur.lineClaim === 'object'
      ? (cur.lineClaim as Record<string, unknown>)
      : null;
  if (mark === null || mark.slotId !== p.slotId || mark.releasedAt != null) {
    return {outcome: 'not_ours', apply: NOOP};
  }
  const checkedIn =
    att !== null &&
    (att.checkInTime != null ||
      att.status === 'present' ||
      att.status === 'departed');
  if (checkedIn) {
    return {
      outcome: 'kept_checked_in',
      apply: (t) => {
        t.update(entryRef, {
          'lineClaim.releasedAt': p.now,
          'lineClaim.keptReason': 'checked_in',
          ...stamp(LINE_CLAIM_STAFF_NAME, false),
        });
        if (att !== null && att.lineClaim != null) {
          t.update(attRef, {
            'lineClaim.releasedAt': p.now,
            'lineClaim.keptReason': 'checked_in',
            ...stamp(LINE_CLAIM_STAFF_NAME, false),
          });
        }
      },
    };
  }
  const prev =
    mark.prev !== null && typeof mark.prev === 'object'
      ? (mark.prev as Record<string, unknown>)
      : null;
  const prevAtt =
    mark.prevAttendance !== null && typeof mark.prevAttendance === 'object'
      ? (mark.prevAttendance as Record<string, unknown>)
      : null;
  return {
    outcome: 'removed',
    apply: (t) => {
      if (prev !== null) {
        t.update(entryRef, {
          status: str(prev.status) ?? 'cancelled',
          plannedStartTime: str(prev.plannedStartTime),
          plannedEndTime: str(prev.plannedEndTime),
          lineClaim: FieldValue.delete(),
          ...stamp(LINE_CLAIM_STAFF_NAME, false),
        });
      } else {
        t.delete(entryRef);
      }
      if (att === null) return;
      // 出席の予定（入室前）: 応募の前に出席の記録があれば元に戻し、無ければ消す。
      // 応募のあとアプリが週間利用計画から作った出席の予定（印なし）も同じく消す。
      if (prevAtt !== null) {
        t.update(attRef, {
          status: str(prevAtt.status) ?? 'scheduled',
          absenceReason: str(prevAtt.absenceReason),
          lineClaim: FieldValue.delete(),
          ...stamp(LINE_CLAIM_STAFF_NAME, false),
        });
      } else if (att.status === 'scheduled') {
        t.delete(attRef);
      }
    },
  };
}
