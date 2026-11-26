import '../data/audit.dart';
import '../data/fs_values.dart';

/// 業務日誌の「今日いた職員」の 1 人。
///
/// 名前を写して残す（在籍終了・改名の後も、その日の日誌には当時の名前が出る）。
class JournalStaff {
  final String? staffId;
  final String name;

  const JournalStaff({required this.staffId, required this.name});

  Map<String, dynamic> toMap() => {'staffId': staffId, 'name': name};

  static JournalStaff? fromMap(Object? v) {
    if (v is! Map) return null;
    final name = v['name'];
    if (name is! String || name.isEmpty) return null;
    final id = v['staffId'];
    return JournalStaff(staffId: id is String ? id : null, name: name);
  }

  @override
  bool operator ==(Object other) =>
      other is JournalStaff && other.staffId == staffId && other.name == name;

  @override
  int get hashCode => Object.hash(staffId, name);
}

/// 業務日誌（facilities/{facilityId}/dailyJournals/{YYYY-MM-DD}）。1 日 1 文書。
///
/// 利用者の入退室時間は持たない（表示・印刷のたびに出席の記録から読む）。
/// 「その日の内容」は選んだ名前を写して残す（設定から選択肢を消しても残る）。
class DailyJournal {
  /// "YYYY-MM-DD"（文書 ID と同じ）
  final String dateKey;
  final List<JournalStaff> staff;
  final List<String> activities;
  final String note;

  // 記録（読み取り専用。書き込みは AuditStamp が付ける）
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? updatedByStaffId;
  final String? updatedByStaffName;

  const DailyJournal({
    required this.dateKey,
    this.staff = const [],
    this.activities = const [],
    this.note = '',
    this.createdAt,
    this.updatedAt,
    this.updatedByStaffId,
    this.updatedByStaffName,
  });

  static const String fDate = 'date';
  static const String fStaff = 'staff';
  static const String fActivities = 'activities';
  static const String fNote = 'note';

  /// ルールと同じ上限
  static const int maxStaff = 100;
  static const int maxActivities = 50;
  static const int maxNoteLength = 4000;

  /// 日付 → 文書 ID（"YYYY-MM-DD"）
  static String keyOf(DateTime d) => dateOnlyToString(d)!;

  DateTime get date => dateOnlyFromString(dateKey)!;

  /// 保存する業務データ（記録欄を除く）
  Map<String, dynamic> toFirestoreData() => {
        fDate: dateKey,
        fStaff: [for (final s in staff) s.toMap()],
        fActivities: List<String>.from(activities),
        fNote: note,
      };

  factory DailyJournal.fromFirestore(String id, Map<String, dynamic> d) {
    final staffRaw = d[fStaff];
    return DailyJournal(
      dateKey: id,
      staff: staffRaw is List
          ? [
              for (final e in staffRaw)
                if (JournalStaff.fromMap(e) case final s?) s
            ]
          : const [],
      activities: readStringList(d[fActivities]),
      note: readString(d[fNote]) ?? '',
      createdAt: readTimestamp(d[AuditStamp.fCreatedAt]),
      updatedAt: readTimestamp(d[AuditStamp.fUpdatedAt]),
      updatedByStaffId: readString(d[AuditStamp.fUpdatedByStaffId]),
      updatedByStaffName: readString(d[AuditStamp.fUpdatedByStaffName]),
    );
  }

  DailyJournal copyWith({
    List<JournalStaff>? staff,
    List<String>? activities,
    String? note,
  }) =>
      DailyJournal(
        dateKey: dateKey,
        staff: staff ?? this.staff,
        activities: activities ?? this.activities,
        note: note ?? this.note,
        createdAt: createdAt,
        updatedAt: updatedAt,
        updatedByStaffId: updatedByStaffId,
        updatedByStaffName: updatedByStaffName,
      );

  /// 業務データの中身が同じか（記録欄は比べない）
  bool sameContent(DailyJournal other) =>
      fsChangedFields(toFirestoreData(), other.toFirestoreData()).isEmpty &&
      fsChangedFields(other.toFirestoreData(), toFirestoreData()).isEmpty;
}
