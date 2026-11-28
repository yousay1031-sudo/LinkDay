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

// ── LineClaimMark ───────────────────────────────────────────
/// LINE の空き枠の応募で予定に入った印（Functions が書く。アプリは書き換えない）。
///
/// 保存先の項目 `lineClaim` = { slotId, customerId, claimedAt, via: 'line',
/// prev, prevAttendance, releasedAt?, keptReason? }。ここでは表示に使うものだけ読む。
class LineClaimMark {
  /// 空き枠の記録の名前（日付_欠席した児童の ID）
  final String slotId;

  /// 確定した時刻（保護者が LINE で応募して確定した時刻）
  final DateTime? claimedAt;

  /// 保護者が取り消した時刻（入室済みで予定に残したときだけ入る）
  final DateTime? releasedAt;

  const LineClaimMark({required this.slotId, this.claimedAt, this.releasedAt});

  /// 取り消されたが、入室の記録があるため予定に残している
  bool get releasedButKept => releasedAt != null;

  static DateTime? _time(Object? v) {
    if (v is DateTime) return v;
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    try {
      // Firestore の Timestamp（この層では cloud_firestore を読み込まない）
      final d = (v as dynamic)?.toDate();
      return d is DateTime ? d : null;
    } catch (_) {
      return null;
    }
  }

  /// 保存先の値（Map）から読む。形が違えば null
  static LineClaimMark? read(Object? v) {
    if (v is! Map) return null;
    final id = v['slotId'];
    if (id is! String || id.isEmpty) return null;
    return LineClaimMark(
      slotId: id,
      claimedAt: _time(v['claimedAt']),
      releasedAt: _time(v['releasedAt']),
    );
  }

  /// 差分の比較用（届いた内容が変わったかを見る）
  Map<String, Object?> toFields() => {
        'slotId': slotId,
        'claimedAt': claimedAt?.millisecondsSinceEpoch,
        'releasedAt': releasedAt?.millisecondsSinceEpoch,
      };
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

  /// LINE の空き枠の応募で入った印（無ければ null。表示だけに使い、アプリからは書かない）
  LineClaimMark? lineClaim;

  ScheduleEntry({
    required this.customerId,
    required this.customerName,
    this.status = ScheduleStatus.planned,
    this.plannedStartTime,
    this.plannedEndTime,
    this.transportLocationIndex,
    this.note,
    this.lineClaim,
  });

  /// LINE の応募で入り、いまも利用する予定（取り消されていない・お休みでない）
  bool get isLineClaimActive =>
      lineClaim != null &&
      !lineClaim!.releasedButKept &&
      status != ScheduleStatus.cancelled;

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
      lineClaim: lineClaim,
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
