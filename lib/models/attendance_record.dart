import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../data/audit.dart' show readTimestamp;
import '../data/fs_values.dart';

part 'attendance_record.g.dart';

/// 出席ステータス
/// Hive Type ID: 2
@HiveType(typeId: 2)
enum AttendanceStatus {
  /// 予定（当日登録済み・未入室）
  @HiveField(0)
  scheduled,

  /// 在室中（入室済み・退室前）
  @HiveField(1)
  present,

  /// 退室済み（入室・退室両方記録済み）
  @HiveField(2)
  departed,

  /// 欠席（理由あり）
  @HiveField(3)
  absent,
}

/// 出席レコード
/// Hive Type ID: 1
/// 1利用者1日1レコード。dateKey ベースで管理する。
@HiveType(typeId: 1)
class AttendanceRecord extends HiveObject {
  @HiveField(0)
  final String id; // UUID

  @HiveField(1)
  final String customerId;

  @HiveField(2)
  String customerName; // 氏名スナップショット（PDF・高速表示用）

  @HiveField(3)
  String dateKey; // "2026-06-15" 形式の日付キー

  @HiveField(4)
  AttendanceStatus status;

  @HiveField(5)
  DateTime? plannedStartTime; // 予定入室時刻

  @HiveField(6)
  DateTime? plannedEndTime; // 予定退室時刻

  @HiveField(7)
  DateTime? checkInTime; // 実際の入室時刻

  @HiveField(8)
  DateTime? checkOutTime; // 実際の退室時刻

  @HiveField(9)
  String? absenceReason; // 欠席理由

  @HiveField(10)
  String? note; // 備考

  @HiveField(11)
  DateTime createdAt;

  @HiveField(12)
  DateTime updatedAt;

  // ── Firestore のみ（段階5）: 入室・退室を記録した担当者 ─────────────
  // 後で作る業務日誌で「誰が入室を記録したか」を出すため（設計判断点⑥）。
  String? checkInByStaffId;
  String? checkInByStaffName;
  String? checkOutByStaffId;
  String? checkOutByStaffName;

  // ── 将来 daily_report 連携ポイント ──────────────────────────
  // TODO(daily_report): レポート生成時、日付とcustomerIdで検索して
  //   checkInTime/checkOutTime/absenceReason を参照してください。
  // AttendanceService.getRecordsByDate(date) で日次サマリー取得可能。
  // ─────────────────────────────────────────────────────────

  AttendanceRecord({
    String? id,
    required this.customerId,
    required this.customerName,
    required this.dateKey,
    this.status = AttendanceStatus.scheduled,
    this.plannedStartTime,
    this.plannedEndTime,
    this.checkInTime,
    this.checkOutTime,
    this.absenceReason,
    this.note,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.checkInByStaffId,
    this.checkInByStaffName,
    this.checkOutByStaffId,
    this.checkOutByStaffName,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// 提供時間（分単位）を返す。両時刻未設定なら null
  int? get serviceMinutes {
    if (checkInTime == null || checkOutTime == null) return null;
    return checkOutTime!.difference(checkInTime!).inMinutes;
  }

  /// 提供時間を "H時間M分" 形式の文字列で返す
  String? get serviceTimeLabel {
    final minutes = serviceMinutes;
    if (minutes == null || minutes <= 0) return null;
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '$m分';
    if (m == 0) return '$h時間';
    return '$h時間$m分';
  }

  /// dateKey から DateTime を生成
  DateTime get date {
    final parts = dateKey.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  /// ステータスの日本語ラベル
  String get statusLabel {
    switch (status) {
      case AttendanceStatus.scheduled:
        return '予定';
      case AttendanceStatus.present:
        return '在室中';
      case AttendanceStatus.departed:
        return '退室済';
      case AttendanceStatus.absent:
        return '欠席';
    }
  }

  /// updatedAt を更新した新しいレコードを返す
  AttendanceRecord copyWith({
    AttendanceStatus? status,
    DateTime? plannedStartTime,
    DateTime? plannedEndTime,
    DateTime? checkInTime,
    DateTime? checkOutTime,
    String? absenceReason,
    String? note,
    bool clearAbsenceReason = false,
    bool clearCheckIn = false,
    bool clearCheckOut = false,
  }) {
    return AttendanceRecord(
      id: id,
      customerId: customerId,
      customerName: customerName,
      dateKey: dateKey,
      status: status ?? this.status,
      plannedStartTime: plannedStartTime ?? this.plannedStartTime,
      plannedEndTime: plannedEndTime ?? this.plannedEndTime,
      checkInTime: clearCheckIn ? null : (checkInTime ?? this.checkInTime),
      checkOutTime: clearCheckOut ? null : (checkOutTime ?? this.checkOutTime),
      absenceReason:
          clearAbsenceReason ? null : (absenceReason ?? this.absenceReason),
      note: note ?? this.note,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      checkInByStaffId: clearCheckIn ? null : checkInByStaffId,
      checkInByStaffName: clearCheckIn ? null : checkInByStaffName,
      checkOutByStaffId: clearCheckOut ? null : checkOutByStaffId,
      checkOutByStaffName: clearCheckOut ? null : checkOutByStaffName,
    );
  }

  /// 日付キーを "YYYY-MM-DD" 形式で生成するユーティリティ
  static String makeDateKey(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Hive ボックスのキー（customerId + dateKey の組み合わせ）
  String get boxKey => '${customerId}_$dateKey';

  // ── Firestore ─────────────────────────────────────────────────
  // facilities/{facilityId}/attendance/{YYYY-MM-DD}_{customerId}
  // ドキュメント ID が日付と顧客から決まるので、同じ日・同じ顧客の記録は 1 件だけ。

  static String docIdOf(String dateKey, String customerId) =>
      '${dateKey}_$customerId';

  String get docId => docIdOf(dateKey, customerId);

  static Timestamp? _ts(DateTime? d) => d == null ? null : Timestamp.fromDate(d);

  /// 業務データの項目（記録欄・作成日時を除く）
  Map<String, dynamic> toFirestoreData() => {
        'date': dateKey,
        'customerId': customerId,
        'customerName': customerName,
        'status': status.name,
        'plannedStartTime': _ts(plannedStartTime),
        'plannedEndTime': _ts(plannedEndTime),
        'checkInTime': _ts(checkInTime),
        'checkOutTime': _ts(checkOutTime),
        'absenceReason': absenceReason,
        'note': note,
        'checkInByStaffId': checkInByStaffId,
        'checkInByStaffName': checkInByStaffName,
        'checkOutByStaffId': checkOutByStaffId,
        'checkOutByStaffName': checkOutByStaffName,
      };

  factory AttendanceRecord.fromFirestore(String id, Map<String, dynamic> d) =>
      AttendanceRecord(
        id: id,
        customerId: readString(d['customerId']) ?? '',
        customerName: readString(d['customerName']) ?? '',
        dateKey: readString(d['date']) ?? '',
        status: AttendanceStatus.values.firstWhere(
          (s) => s.name == d['status'],
          orElse: () => AttendanceStatus.scheduled,
        ),
        plannedStartTime: readTimestamp(d['plannedStartTime']),
        plannedEndTime: readTimestamp(d['plannedEndTime']),
        checkInTime: readTimestamp(d['checkInTime']),
        checkOutTime: readTimestamp(d['checkOutTime']),
        absenceReason: readString(d['absenceReason']),
        note: readString(d['note']),
        createdAt: readTimestamp(d['createdAt']),
        updatedAt: readTimestamp(d['updatedAt']),
        checkInByStaffId: readString(d['checkInByStaffId']),
        checkInByStaffName: readString(d['checkInByStaffName']),
        checkOutByStaffId: readString(d['checkOutByStaffId']),
        checkOutByStaffName: readString(d['checkOutByStaffName']),
      );
}

/// AttendanceService.getTodaySummary() の戻り値
class AttendanceSummary {
  final int scheduledCount;
  final int presentCount;
  final int departedCount;
  final int absentCount;
  final int capacity; // 定員（現時点では固定値）

  const AttendanceSummary({
    required this.scheduledCount,
    required this.presentCount,
    required this.departedCount,
    required this.absentCount,
    this.capacity = 10,
  });

  /// 空き枠 = 定員 - (予定 + 在室中)
  int get availableSlots =>
      (capacity - scheduledCount - presentCount).clamp(0, capacity);

  int get totalActive => scheduledCount + presentCount + departedCount;
}
