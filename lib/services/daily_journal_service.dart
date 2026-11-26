import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../data/audit.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';
import '../data/pending_echoes.dart';
import '../data/staff_session.dart';
import '../models/attendance_record.dart';
import '../models/daily_journal.dart';
import '../models/staff.dart';

/// 未来の日の日誌を保存しようとした
class JournalFutureDateException implements Exception {
  const JournalFutureDateException();
  @override
  String toString() => '未来の日の日誌は作れません';
}

/// 業務日誌の「利用者の入退室時間」の 1 行（出席の記録から作る。保存しない）
class JournalAttendanceRow {
  final String customerId;
  final String name;
  final AttendanceStatus status;
  final DateTime? checkIn;
  final DateTime? checkOut;
  final String? absenceReason;

  const JournalAttendanceRow({
    required this.customerId,
    required this.name,
    required this.status,
    this.checkIn,
    this.checkOut,
    this.absenceReason,
  });

  static String hm(DateTime? t) => t == null
      ? '--:--'
      : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// 入室の欄（欠席・未入室は空）
  String get inText => switch (status) {
        AttendanceStatus.present || AttendanceStatus.departed => hm(checkIn),
        _ => '',
      };

  /// 退室の欄（在室中は「在室中」）
  String get outText => switch (status) {
        AttendanceStatus.departed => hm(checkOut),
        AttendanceStatus.present => '在室中',
        _ => '',
      };

  /// 状態の欄（欠席は理由つき）
  String get statusText => switch (status) {
        AttendanceStatus.absent => (absenceReason ?? '').trim().isEmpty
            ? '欠席'
            : '欠席（${absenceReason!.trim()}）',
        AttendanceStatus.scheduled => '未入室',
        AttendanceStatus.present => '在室中',
        AttendanceStatus.departed => '退室済み',
      };

  /// 出席の記録から日誌の行を作る。
  /// 並び: 入室した人（入室の早い順）→ 未入室 → 欠席。同じなら氏名順。
  static List<JournalAttendanceRow> fromRecords(
      Iterable<AttendanceRecord> records) {
    int group(AttendanceStatus s) => switch (s) {
          AttendanceStatus.present || AttendanceStatus.departed => 0,
          AttendanceStatus.scheduled => 1,
          AttendanceStatus.absent => 2,
        };
    final rows = [
      for (final r in records)
        JournalAttendanceRow(
          customerId: r.customerId,
          name: r.customerName,
          status: r.status,
          checkIn: r.checkInTime,
          checkOut: r.checkOutTime,
          absenceReason: r.absenceReason,
        )
    ];
    rows.sort((a, b) {
      final g = group(a.status).compareTo(group(b.status));
      if (g != 0) return g;
      if (group(a.status) == 0) {
        final ta = a.checkIn, tb = b.checkIn;
        if (ta != null && tb != null && ta != tb) return ta.compareTo(tb);
        if (ta == null && tb != null) return 1;
        if (ta != null && tb == null) return -1;
      }
      return a.name.compareTo(b.name);
    });
    return rows;
  }
}

/// 1 日分の日誌の購読で届いたもの
class JournalSnapshot {
  /// 保存されていなければ null
  final DailyJournal? journal;

  /// 自分の古い書き込みの遅れて届いた折り返し（画面は無視する）
  final bool staleEcho;

  const JournalSnapshot(this.journal, {this.staleEcho = false});
}

/// 業務日誌の読み書き（facilities/{facilityId}/dailyJournals/{YYYY-MM-DD}）。
///
/// 1 日 1 文書（文書 ID が日付なので、同じ日の日誌は 2 つできない）。
/// 画面が開いている日だけを購読する。保存は「端末内へ反映 → 送信は待たない」
/// （ステップ1と同じ。通信が切れていても画面は止まらず、戻ったときに届く）。
class DailyJournalService {
  DailyJournalService._();
  static final DailyJournalService instance = DailyJournalService._();

  final PendingEchoesByDoc _echoes = PendingEchoesByDoc();

  /// テスト用: 今日を差し替える
  DateTime Function() now = DateTime.now;

  CollectionReference<Map<String, dynamic>> get _col =>
      FacilityContext.instance.col(FsPaths.dailyJournals);

  /// 今日（0 時）
  DateTime get today {
    final n = now();
    return DateTime(n.year, n.month, n.day);
  }

  bool isFuture(DateTime date) =>
      DateTime(date.year, date.month, date.day).isAfter(today);

  /// [date] の日誌を購読する
  Stream<JournalSnapshot> watch(DateTime date) {
    final key = DailyJournal.keyOf(date);
    return _col.doc(key).snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return const JournalSnapshot(null);
      final j = DailyJournal.fromFirestore(key, data);
      final stale = _echoes.isStaleEcho(key, j.toFirestoreData());
      return JournalSnapshot(j, staleEcho: stale);
    });
  }

  /// 日誌がまだ無い日に、最初から選んだ状態にする職員
  /// （在籍中で、職員管理の勤務日がその曜日に当たる人）
  static List<JournalStaff> defaultStaffFor(
          DateTime date, Iterable<Staff> activeStaff) =>
      [
        for (final s in activeStaff)
          if (s.isActive && s.workDays.contains(date.weekday))
            JournalStaff(staffId: s.id, name: s.name)
      ];

  /// 日誌を保存する（担当者が必要。未選択なら選ぶ画面を出す）。
  ///
  /// [exists] は保存先に既にあるか（作成日時を付けるかどうか）。
  /// 未来の日は [JournalFutureDateException]。使った担当者の記録を返す。
  Future<AuditStamp> save(DailyJournal journal,
      {required bool exists, AuditStamp? stamp}) async {
    if (isFuture(journal.date)) throw const JournalFutureDateException();
    final s = stamp ?? await StaffSession.instance.requireStamp();
    final data = journal.toFirestoreData();
    if (!FacilityContext.instance.isAttached) return s;
    _echoes.add(journal.dateKey, data);
    DataErrors.send(
      _col.doc(journal.dateKey).set(
        {...data, ...(exists ? s.toFields() : s.toCreateFields())},
        SetOptions(merge: true),
      ),
      what: '業務日誌（${journal.dateKey}）',
    );
    return s;
  }

  void reset() => _echoes.clear();
}
