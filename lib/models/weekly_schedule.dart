import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'weekly_schedule.g.dart';

// ── ScheduleStatus ──────────────────────────────────────────
/// Hive Type ID: 5
@HiveType(typeId: 5)
enum ScheduleStatus {
  /// 通常予定（regularDays から自動生成）
  @HiveField(0)
  planned,

  /// 追加（イレギュラーで増やした）
  @HiveField(1)
  additional,

  /// キャンセル（regularDays 対象だが今週は休む）
  @HiveField(2)
  cancelled,
}

// ── ScheduleEntry ────────────────────────────────────────────
/// 1利用者の1日分のエントリ
/// Hive Type ID: 6
@HiveType(typeId: 6)
class ScheduleEntry extends HiveObject {
  @HiveField(0)
  String customerId;

  @HiveField(1)
  String customerName; // スナップショット

  @HiveField(2)
  ScheduleStatus status;

  @HiveField(3)
  String? plannedStartTime; // "09:00" 形式

  @HiveField(4)
  String? plannedEndTime; // "15:00" 形式

  @HiveField(5)
  int? transportLocationIndex; // Customer.transportLocations のインデックス

  @HiveField(6)
  String? note;

  ScheduleEntry({
    required this.customerId,
    required this.customerName,
    this.status = ScheduleStatus.planned,
    this.plannedStartTime,
    this.plannedEndTime,
    this.transportLocationIndex,
    this.note,
  });

  /// ステータスのラベル
  String get statusLabel {
    switch (status) {
      case ScheduleStatus.planned:
        return '予定';
      case ScheduleStatus.additional:
        return '追加';
      case ScheduleStatus.cancelled:
        return 'キャンセル';
    }
  }

  /// コピーを作成
  ScheduleEntry copyWith({
    ScheduleStatus? status,
    String? plannedStartTime,
    String? plannedEndTime,
    int? transportLocationIndex,
    String? note,
    bool clearTransport = false,
    bool clearNote = false,
  }) {
    return ScheduleEntry(
      customerId: customerId,
      customerName: customerName,
      status: status ?? this.status,
      plannedStartTime: plannedStartTime ?? this.plannedStartTime,
      plannedEndTime: plannedEndTime ?? this.plannedEndTime,
      transportLocationIndex: clearTransport
          ? null
          : (transportLocationIndex ?? this.transportLocationIndex),
      note: clearNote ? null : (note ?? this.note),
    );
  }
}

// ── DailySlot ────────────────────────────────────────────────
/// 1日分のスロット（複数利用者のエントリを保持）
/// Hive Type ID: 4
@HiveType(typeId: 4)
class DailySlot extends HiveObject {
  @HiveField(0)
  DateTime date;

  @HiveField(1)
  int dayOfWeek; // 1=月〜7=日

  @HiveField(2)
  List<ScheduleEntry> entries;

  DailySlot({
    required this.date,
    required this.dayOfWeek,
    List<ScheduleEntry>? entries,
  }) : entries = entries ?? [];

  /// customerId でエントリを検索
  ScheduleEntry? findEntry(String customerId) {
    try {
      return entries.firstWhere((e) => e.customerId == customerId);
    } catch (_) {
      return null;
    }
  }

  /// cancelled を除く有効なエントリ数
  int get activeCount =>
      entries.where((e) => e.status != ScheduleStatus.cancelled).length;
}

// ── WeeklySchedule ───────────────────────────────────────────
/// 週間利用計画
/// Hive Type ID: 3
/// キー: weekKey（例: "2026-W25"）
@HiveType(typeId: 3)
class WeeklySchedule extends HiveObject {
  @HiveField(0)
  final String id; // UUID

  @HiveField(1)
  DateTime weekStartDate; // 月曜日 0:00

  @HiveField(2)
  String weekKey; // "2026-W25"

  @HiveField(3)
  List<DailySlot> dailySlots; // 7日分

  @HiveField(4)
  DateTime createdAt;

  @HiveField(5)
  DateTime updatedAt;

  @HiveField(6)
  String? note;

  WeeklySchedule({
    String? id,
    required this.weekStartDate,
    required this.weekKey,
    List<DailySlot>? dailySlots,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.note,
  })  : id = id ?? const Uuid().v4(),
        dailySlots = dailySlots ?? _emptySlots(weekStartDate),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// 月曜〜日曜の空スロットリストを生成
  static List<DailySlot> _emptySlots(DateTime monday) {
    return List.generate(7, (i) {
      final date = monday.add(Duration(days: i));
      return DailySlot(date: date, dayOfWeek: date.weekday);
    });
  }

  /// 曜日番号（1〜7）でスロットを取得
  DailySlot? slotForDay(int dayOfWeek) {
    try {
      return dailySlots.firstWhere((s) => s.dayOfWeek == dayOfWeek);
    } catch (_) {
      return null;
    }
  }

  /// 日付でスロットを取得
  DailySlot? slotForDate(DateTime date) {
    try {
      return dailySlots.firstWhere(
        (s) =>
            s.date.year == date.year &&
            s.date.month == date.month &&
            s.date.day == date.day,
      );
    } catch (_) {
      return null;
    }
  }

  /// 今週の利用者ごとの有効日数（cancelled 除く）
  Map<String, int> usageByCustomer() {
    final result = <String, int>{};
    for (final slot in dailySlots) {
      for (final entry in slot.entries) {
        if (entry.status == ScheduleStatus.cancelled) continue;
        result[entry.customerId] = (result[entry.customerId] ?? 0) + 1;
      }
    }
    return result;
  }

  /// 全利用者 ID のセット
  Set<String> get allCustomerIds {
    final ids = <String>{};
    for (final slot in dailySlots) {
      for (final entry in slot.entries) {
        ids.add(entry.customerId);
      }
    }
    return ids;
  }
}
