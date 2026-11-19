import 'package:uuid/uuid.dart';

// ── ScheduleStatus ──────────────────────────────────────────
enum ScheduleStatus {
  /// 通常予定（regularDays から自動生成）
  planned,

  /// 追加（イレギュラーで増やした）
  additional,

  /// キャンセル（regularDays 対象だが今週は休む）
  cancelled,
}

// ── ScheduleEntry ────────────────────────────────────────────
/// 1利用者の1日分のエントリ
class ScheduleEntry {
  String customerId;

  String customerName; // スナップショット

  ScheduleStatus status;

  String? plannedStartTime; // "09:00" 形式

  String? plannedEndTime; // "15:00" 形式

  int? transportLocationIndex; // Customer.transportLocations のインデックス

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
class DailySlot {
  DateTime date;

  int dayOfWeek; // 1=月〜7=日

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
/// キー: weekKey（例: "2026-W25"）
class WeeklySchedule {
  final String id; // UUID

  DateTime weekStartDate; // 月曜日 0:00

  String weekKey; // "2026-W25"

  List<DailySlot> dailySlots; // 7日分

  DateTime createdAt;

  DateTime updatedAt;

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
