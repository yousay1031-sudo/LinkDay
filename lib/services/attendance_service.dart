import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/attendance_record.dart';
import '../models/customer.dart';
import 'weekly_schedule_service.dart';

/// 欠席ダイアログ選択肢
const List<String> kAbsenceReasons = [
  '体調不良',
  '家庭の都合',
  '連絡なし欠席',
  '学校都合',
  'その他',
];

/// markDeparted の結果
enum DepartResult {
  success,
  noCheckIn, // 入室記録がない
}

/// 出席管理サービス
/// Hive box 名: 'attendance_records'
/// キー: ${customerId}_${dateKey}
class AttendanceService {
  AttendanceService._();
  static final AttendanceService instance = AttendanceService._();

  late Box<AttendanceRecord> _box;

  // ── 初期化 ──────────────────────────────────────────────────

  Future<void> init() async {
    _box = await Hive.openBox<AttendanceRecord>('attendance_records');
    debugPrint('[AttendanceService] initialized. records=${_box.length}');
  }

  // ── 基本 CRUD ────────────────────────────────────────────────

  /// 指定日の全レコードを取得
  List<AttendanceRecord> getRecordsByDate(DateTime date) {
    final key = AttendanceRecord.makeDateKey(date);
    return _box.values
        .where((r) => r.dateKey == key)
        .toList()
      ..sort((a, b) => a.customerName.compareTo(b.customerName));
  }

  /// 特定利用者・特定日のレコードを取得（なければ null）
  AttendanceRecord? getRecord(String customerId, DateTime date) {
    final boxKey = '${customerId}_${AttendanceRecord.makeDateKey(date)}';
    return _box.get(boxKey);
  }

  /// レコードを保存・上書きする（upsert）
  Future<void> upsertRecord(AttendanceRecord record) async {
    await _box.put(record.boxKey, record);
    debugPrint('[AttendanceService] upsert: ${record.boxKey} status=${record.status}');
  }

  /// レコードを削除する
  Future<void> deleteRecord(String customerId, DateTime date) async {
    final boxKey = '${customerId}_${AttendanceRecord.makeDateKey(date)}';
    await _box.delete(boxKey);
  }

  // ── 当日スケジュール生成 ────────────────────────────────────

  /// 当日対象の顧客を scheduled レコードとして自動生成する。
  /// 既に当日のレコードが存在する場合は上書きしない。
  ///
  /// 優先順位:
  ///   1. WeeklyScheduleService に当日の週間利用計画がある場合:
  ///      planned + additional の顧客を対象にする（cancelled は除外）
  ///   2. 週間利用計画がない場合:
  ///      従来どおり customer.regularDays から生成
  ///
  ///   ScheduleEntry.plannedStartTime / plannedEndTime がある場合は
  ///   AttendanceRecord にコピーする。
  Future<int> ensureTodayScheduledRecords(
    DateTime date,
    List<Customer> customers,
  ) async {
    final dateKey = AttendanceRecord.makeDateKey(date);

    // ── 週間利用計画から当日エントリを取得
    final weeklyEntries =
        WeeklyScheduleService.instance.getEntriesForDate(date);

    int created = 0;

    if (weeklyEntries.isNotEmpty) {
      // ── 週間利用計画ベース ────────────────────────────────
      // cancelled は既に除外済み（WeeklyScheduleService.getEntriesForDate）
      final customerMap = <String, Customer>{
        for (final c in customers) c.id: c,
      };

      for (final entry in weeklyEntries) {
        final boxKey = '${entry.customerId}_$dateKey';
        if (_box.containsKey(boxKey)) continue; // 既存レコードは触らない

        // 週間計画から名前を取得（念のため Customer マスタでも上書き）
        final customerName =
            customerMap[entry.customerId]?.name ?? entry.customerName;

        // 週間計画の文字列時刻（"HH:mm"）を DateTime? に変換
        final plannedStart = _parseTimeString(dateKey, entry.plannedStartTime);
        final plannedEnd = _parseTimeString(dateKey, entry.plannedEndTime);

        final record = AttendanceRecord(
          customerId: entry.customerId,
          customerName: customerName,
          dateKey: dateKey,
          status: AttendanceStatus.scheduled,
          // 週間計画の時刻設定をコピー
          plannedStartTime: plannedStart,
          plannedEndTime: plannedEnd,
        );
        await _box.put(boxKey, record);
        created++;
      }
      debugPrint(
        '[AttendanceService] ensureTodayScheduled (weekly plan): created=$created',
      );
    } else {
      // ── 従来の regularDays ベース（週間計画なし）────────────
      final weekday = date.weekday; // 1=月,2=火,3=水,4=木,5=金,6=土,7=日

      for (final customer in customers) {
        if (!customer.isActive) continue;
        // 日曜（7）は regularDays には含まれないが念のためスキップ
        if (!customer.regularDays.contains(weekday)) continue;

        final boxKey = '${customer.id}_$dateKey';
        if (_box.containsKey(boxKey)) continue; // 既存レコードは触らない

        final record = AttendanceRecord(
          customerId: customer.id,
          customerName: customer.name,
          dateKey: dateKey,
          status: AttendanceStatus.scheduled,
        );
        await _box.put(boxKey, record);
        created++;
      }
      debugPrint(
        '[AttendanceService] ensureTodayScheduled (regularDays fallback): created=$created',
      );
    }

    return created;
  }

  /// ensureTodayScheduledRecords で利用した週間計画があるかどうかを返す
  /// （デバッグ / ホーム画面のバッジ更新用）
  bool hasWeeklyPlanForDate(DateTime date) {
    return WeeklyScheduleService.instance.getEntriesForDate(date).isNotEmpty;
  }

  // ── ステータス変更 ──────────────────────────────────────────

  /// 入室処理
  /// - status → present
  /// - checkInTime が未設定なら現在時刻をセット
  Future<void> markPresent({
    required String customerId,
    required DateTime date,
    DateTime? time,
  }) async {
    final existing = getRecord(customerId, date);
    final now = time ?? DateTime.now();

    if (existing != null) {
      final updated = AttendanceRecord(
        id: existing.id,
        customerId: existing.customerId,
        customerName: existing.customerName,
        dateKey: existing.dateKey,
        status: AttendanceStatus.present,
        plannedStartTime: existing.plannedStartTime,
        plannedEndTime: existing.plannedEndTime,
        checkInTime: existing.checkInTime ?? now,
        checkOutTime: existing.checkOutTime,
        absenceReason: null,
        note: existing.note,
        createdAt: existing.createdAt,
        updatedAt: DateTime.now(),
      );
      await upsertRecord(updated);
    } else {
      // scheduled レコードがない場合でも入室可能
      final record = AttendanceRecord(
        customerId: customerId,
        customerName: '', // ensureScheduled 経由でない場合は名前不明
        dateKey: AttendanceRecord.makeDateKey(date),
        status: AttendanceStatus.present,
        checkInTime: now,
      );
      await upsertRecord(record);
    }
  }

  /// 退室処理
  /// - checkInTime が null の場合は DepartResult.noCheckIn を返し保存しない
  /// - status → departed
  /// - checkOutTime が未設定なら現在時刻をセット
  Future<DepartResult> markDeparted({
    required String customerId,
    required DateTime date,
    DateTime? time,
  }) async {
    final existing = getRecord(customerId, date);
    if (existing == null || existing.checkInTime == null) {
      return DepartResult.noCheckIn;
    }

    final now = time ?? DateTime.now();
    final updated = AttendanceRecord(
      id: existing.id,
      customerId: existing.customerId,
      customerName: existing.customerName,
      dateKey: existing.dateKey,
      status: AttendanceStatus.departed,
      plannedStartTime: existing.plannedStartTime,
      plannedEndTime: existing.plannedEndTime,
      checkInTime: existing.checkInTime,
      checkOutTime: existing.checkOutTime ?? now,
      absenceReason: null,
      note: existing.note,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    await upsertRecord(updated);
    return DepartResult.success;
  }

  /// 欠席処理
  /// - status → absent
  /// - absenceReason を保存
  /// - checkInTime/checkOutTime は null にリセット
  Future<void> markAbsent({
    required String customerId,
    required DateTime date,
    required String reason,
  }) async {
    final existing = getRecord(customerId, date);
    if (existing == null) return;

    final updated = AttendanceRecord(
      id: existing.id,
      customerId: existing.customerId,
      customerName: existing.customerName,
      dateKey: existing.dateKey,
      status: AttendanceStatus.absent,
      plannedStartTime: existing.plannedStartTime,
      plannedEndTime: existing.plannedEndTime,
      checkInTime: null,
      checkOutTime: null,
      absenceReason: reason,
      note: existing.note,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    await upsertRecord(updated);
  }

  /// 欠席取り消し
  /// - absent → scheduled
  /// - absenceReason をクリア
  Future<void> resetAbsent({
    required String customerId,
    required DateTime date,
  }) async {
    final existing = getRecord(customerId, date);
    if (existing == null || existing.status != AttendanceStatus.absent) return;

    final updated = AttendanceRecord(
      id: existing.id,
      customerId: existing.customerId,
      customerName: existing.customerName,
      dateKey: existing.dateKey,
      status: AttendanceStatus.scheduled,
      plannedStartTime: existing.plannedStartTime,
      plannedEndTime: existing.plannedEndTime,
      checkInTime: null,
      checkOutTime: null,
      absenceReason: null,
      note: existing.note,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    await upsertRecord(updated);
  }

  // ── 時刻の手動修正 ────────────────────────────────────────

  /// 入室時刻を更新する
  Future<void> updateCheckInTime({
    required String customerId,
    required DateTime date,
    required DateTime newTime,
  }) async {
    final existing = getRecord(customerId, date);
    if (existing == null) return;

    final updated = AttendanceRecord(
      id: existing.id,
      customerId: existing.customerId,
      customerName: existing.customerName,
      dateKey: existing.dateKey,
      status: existing.status,
      plannedStartTime: existing.plannedStartTime,
      plannedEndTime: existing.plannedEndTime,
      checkInTime: newTime,
      checkOutTime: existing.checkOutTime,
      absenceReason: existing.absenceReason,
      note: existing.note,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    await upsertRecord(updated);
  }

  /// 退室時刻を更新する
  Future<void> updateCheckOutTime({
    required String customerId,
    required DateTime date,
    required DateTime newTime,
  }) async {
    final existing = getRecord(customerId, date);
    if (existing == null) return;

    final updated = AttendanceRecord(
      id: existing.id,
      customerId: existing.customerId,
      customerName: existing.customerName,
      dateKey: existing.dateKey,
      status: existing.status,
      plannedStartTime: existing.plannedStartTime,
      plannedEndTime: existing.plannedEndTime,
      checkInTime: existing.checkInTime,
      checkOutTime: newTime,
      absenceReason: existing.absenceReason,
      note: existing.note,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    await upsertRecord(updated);
  }

  /// 備考を更新する
  Future<void> updateNote({
    required String customerId,
    required DateTime date,
    required String note,
  }) async {
    final existing = getRecord(customerId, date);
    if (existing == null) return;

    final updated = AttendanceRecord(
      id: existing.id,
      customerId: existing.customerId,
      customerName: existing.customerName,
      dateKey: existing.dateKey,
      status: existing.status,
      plannedStartTime: existing.plannedStartTime,
      plannedEndTime: existing.plannedEndTime,
      checkInTime: existing.checkInTime,
      checkOutTime: existing.checkOutTime,
      absenceReason: existing.absenceReason,
      note: note,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    await upsertRecord(updated);
  }

  // ── サマリー取得 ─────────────────────────────────────────────

  /// 当日の集計サマリーを返す
  ///
  /// TODO(daily_report): このメソッドで取得した AttendanceSummary を
  ///   業務日誌の「本日の利用状況」欄に連携してください。
  AttendanceSummary getTodaySummary(DateTime date) {
    final records = getRecordsByDate(date);
    int scheduled = 0, present = 0, departed = 0, absent = 0;
    for (final r in records) {
      switch (r.status) {
        case AttendanceStatus.scheduled:
          scheduled++;
          break;
        case AttendanceStatus.present:
          present++;
          break;
        case AttendanceStatus.departed:
          departed++;
          break;
        case AttendanceStatus.absent:
          absent++;
          break;
      }
    }
    return AttendanceSummary(
      scheduledCount: scheduled,
      presentCount: present,
      departedCount: departed,
      absentCount: absent,
    );
  }

  /// 欠席レコードを返す
  List<AttendanceRecord> getAbsentRecords(DateTime date) =>
      getRecordsByDate(date)
          .where((r) => r.status == AttendanceStatus.absent)
          .toList();

  /// 在室中レコードを返す
  List<AttendanceRecord> getPresentRecords(DateTime date) =>
      getRecordsByDate(date)
          .where((r) => r.status == AttendanceStatus.present)
          .toList();

  /// 退室済みレコードを返す
  List<AttendanceRecord> getDepartedRecords(DateTime date) =>
      getRecordsByDate(date)
          .where((r) => r.status == AttendanceStatus.departed)
          .toList();

  /// 未処理（scheduled のまま）のレコード数を返す（ホーム画面のバッジ用）
  int getUnprocessedCount(DateTime date) =>
      getRecordsByDate(date)
          .where((r) => r.status == AttendanceStatus.scheduled)
          .length;

  // ── プライベートヘルパー ──────────────────────────────────────

  /// "HH:mm" 形式の文字列を dateKey の日付の DateTime に変換する
  /// 変換できない場合は null を返す
  DateTime? _parseTimeString(String dateKey, String? timeStr) {
    if (timeStr == null) return null;
    try {
      // dateKey = "2026-06-15"
      final dateParts = dateKey.split('-');
      if (dateParts.length != 3) return null;
      final year = int.parse(dateParts[0]);
      final month = int.parse(dateParts[1]);
      final day = int.parse(dateParts[2]);

      // timeStr = "09:00"
      final timeParts = timeStr.split(':');
      if (timeParts.length != 2) return null;
      final hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);

      return DateTime(year, month, day, hour, minute);
    } catch (_) {
      return null;
    }
  }
}
