import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/customer.dart';
import '../models/weekly_schedule.dart';
import '../utils/week_util.dart';

/// 週間利用計画サービス
/// Hive box 名: 'weekly_schedules'
/// キー: weekKey（例: "2026-W25"）
class WeeklyScheduleService {
  WeeklyScheduleService._();
  static final WeeklyScheduleService instance = WeeklyScheduleService._();

  late Box<WeeklySchedule> _box;

  // ── 初期化 ──────────────────────────────────────────────────

  Future<void> init() async {
    _box = await Hive.openBox<WeeklySchedule>('weekly_schedules');
    debugPrint(
        '[WeeklyScheduleService] initialized. schedules=${_box.length}');
  }

  // ── 基本 CRUD ────────────────────────────────────────────────

  WeeklySchedule? getScheduleByWeekKey(String weekKey) => _box.get(weekKey);

  Future<void> saveSchedule(WeeklySchedule schedule) async {
    schedule.updatedAt = DateTime.now();
    await _box.put(schedule.weekKey, schedule);
    debugPrint('[WeeklyScheduleService] saved: ${schedule.weekKey}');
  }

  Future<void> deleteSchedule(String weekKey) => _box.delete(weekKey);

  // ── 取得または新規作成 ────────────────────────────────────────

  /// 指定週のスケジュールを取得、なければ regularDays から自動生成して返す
  Future<WeeklySchedule> getOrCreateSchedule(
    DateTime weekStart,
    List<Customer> customers,
  ) async {
    final weekKey = WeekUtil.weekKeyFromDate(weekStart);
    final existing = _box.get(weekKey);
    if (existing != null) return existing;

    final schedule = _buildFromRegularDays(weekStart, weekKey, customers);
    await saveSchedule(schedule);
    return schedule;
  }

  // ── regularDays 同期 ─────────────────────────────────────────

  /// planned エントリだけ最新の regularDays に同期する
  /// additional / cancelled は手動編集済みなので保持する
  Future<WeeklySchedule> regenerateFromRegularDays(
    String weekKey,
    List<Customer> customers,
  ) async {
    final existing = _box.get(weekKey);
    if (existing == null) {
      final monday = WeekUtil.weekStartFromKey(weekKey);
      final fresh = _buildFromRegularDays(monday, weekKey, customers);
      await saveSchedule(fresh);
      return fresh;
    }

    // planned を削除して再構築、additional/cancelled は保持
    for (final slot in existing.dailySlots) {
      slot.entries.removeWhere((e) => e.status == ScheduleStatus.planned);
    }

    // 新しい planned を追加
    final customerMap = <String, Customer>{
      for (final c in customers) c.id: c,
    };
    for (final slot in existing.dailySlots) {
      for (final customer in customers) {
        if (!customer.isActive) continue;
        if (!customer.regularDays.contains(slot.dayOfWeek)) continue;
        // already has additional or cancelled → skip adding planned
        final alreadyExists =
            slot.entries.any((e) => e.customerId == customer.id);
        if (alreadyExists) continue;
        slot.entries.add(ScheduleEntry(
          customerId: customer.id,
          customerName: customer.name,
          status: ScheduleStatus.planned,
        ));
      }
      // 氏名スナップショットを更新
      for (final entry in slot.entries) {
        final c = customerMap[entry.customerId];
        if (c != null) entry.customerName = c.name;
      }
      // 氏名順にソート
      slot.entries.sort((a, b) => a.customerName.compareTo(b.customerName));
    }

    await saveSchedule(existing);
    return existing;
  }

  // ── エントリ操作 ──────────────────────────────────────────────

  /// エントリを追加する（同一 customerId が既にあれば上書き）
  Future<void> addEntry(
    String weekKey,
    int dayOfWeek,
    ScheduleEntry entry,
  ) async {
    final schedule = _box.get(weekKey);
    if (schedule == null) return;

    final slot = schedule.slotForDay(dayOfWeek);
    if (slot == null) return;

    final idx = slot.entries.indexWhere((e) => e.customerId == entry.customerId);
    if (idx >= 0) {
      slot.entries[idx] = entry;
    } else {
      slot.entries.add(entry);
      slot.entries.sort((a, b) => a.customerName.compareTo(b.customerName));
    }
    await saveSchedule(schedule);
  }

  /// エントリを削除する
  Future<void> removeEntry(
    String weekKey,
    int dayOfWeek,
    String customerId,
  ) async {
    final schedule = _box.get(weekKey);
    if (schedule == null) return;

    final slot = schedule.slotForDay(dayOfWeek);
    if (slot == null) return;

    slot.entries.removeWhere((e) => e.customerId == customerId);
    await saveSchedule(schedule);
  }

  /// エントリのステータスを更新する
  Future<void> updateEntryStatus(
    String weekKey,
    int dayOfWeek,
    String customerId,
    ScheduleStatus newStatus,
  ) async {
    final schedule = _box.get(weekKey);
    if (schedule == null) return;

    final slot = schedule.slotForDay(dayOfWeek);
    if (slot == null) return;

    final idx = slot.entries.indexWhere((e) => e.customerId == customerId);
    if (idx < 0) return;

    slot.entries[idx] = slot.entries[idx].copyWith(status: newStatus);
    await saveSchedule(schedule);
  }

  /// エントリの時刻を更新する
  Future<void> updateEntryTimes(
    String weekKey,
    int dayOfWeek,
    String customerId,
    String? startTime,
    String? endTime,
  ) async {
    final schedule = _box.get(weekKey);
    if (schedule == null) return;

    final slot = schedule.slotForDay(dayOfWeek);
    if (slot == null) return;

    final idx = slot.entries.indexWhere((e) => e.customerId == customerId);
    if (idx < 0) return;

    slot.entries[idx] = slot.entries[idx].copyWith(
      plannedStartTime: startTime,
      plannedEndTime: endTime,
    );
    await saveSchedule(schedule);
  }

  // ── 日付ベースの参照 ─────────────────────────────────────────

  /// 当日出席管理から呼ぶ: 指定日の有効エントリ（planned + additional）を返す
  /// 該当週のスケジュールがなければ空リストを返す
  List<ScheduleEntry> getEntriesForDate(DateTime date) {
    final weekKey = WeekUtil.weekKeyFromDate(date);
    final schedule = _box.get(weekKey);
    if (schedule == null) return [];

    final slot = schedule.slotForDate(date);
    if (slot == null) return [];

    return slot.entries
        .where((e) => e.status != ScheduleStatus.cancelled)
        .toList();
  }

  // ── 利用日数集計 ─────────────────────────────────────────────

  /// 指定顧客の月間利用予定日数を集計（cancelled 除く）
  ///
  /// TODO(monthly_reset): 月初にこのメソッドで集計して
  ///   Customer.currentMonthUsedDays を更新してください。
  int countUsageByCustomer(
    String customerId,
    DateTime monthStart,
    DateTime monthEnd,
  ) {
    int count = 0;
    for (final schedule in _box.values) {
      // 週が月の範囲内か
      final weekEnd = schedule.weekStartDate.add(const Duration(days: 6));
      if (weekEnd.isBefore(monthStart)) continue;
      if (schedule.weekStartDate.isAfter(monthEnd)) continue;

      for (final slot in schedule.dailySlots) {
        if (slot.date.isBefore(monthStart)) continue;
        if (slot.date.isAfter(monthEnd)) continue;
        for (final entry in slot.entries) {
          if (entry.customerId != customerId) continue;
          if (entry.status == ScheduleStatus.cancelled) continue;
          count++;
        }
      }
    }
    return count;
  }

  // ── 翌週コピー ────────────────────────────────────────────────

  /// 現在の週を翌週にコピー（planned/additional だけ、cancelled は引き継がない）
  Future<WeeklySchedule> copyScheduleToNextWeek(String fromWeekKey) async {
    final source = _box.get(fromWeekKey);
    final nextMonday = WeekUtil.nextWeekStart(
      WeekUtil.weekStartFromKey(fromWeekKey),
    );
    final nextWeekKey = WeekUtil.weekKeyFromDate(nextMonday);

    // 翌週が既に存在する場合は上書き確認はサービス層では行わず
    // 呼び出し元（UI）で確認ダイアログを表示すること

    if (source == null) {
      // 元が存在しない → 空のスケジュールを作成
      final empty = WeeklySchedule(
        weekStartDate: nextMonday,
        weekKey: nextWeekKey,
      );
      await saveSchedule(empty);
      return empty;
    }

    // ソースの planned/additional だけコピー
    final newSlots = List.generate(7, (i) {
      final sourceSlot = source.dailySlots[i];
      final newDate = nextMonday.add(Duration(days: i));
      final copiedEntries = sourceSlot.entries
          .where((e) => e.status != ScheduleStatus.cancelled)
          .map((e) => ScheduleEntry(
                customerId: e.customerId,
                customerName: e.customerName,
                // additional → planned に戻す（翌週は通常予定として扱う）
                status: ScheduleStatus.planned,
                plannedStartTime: e.plannedStartTime,
                plannedEndTime: e.plannedEndTime,
                transportLocationIndex: e.transportLocationIndex,
                note: e.note,
              ))
          .toList();
      return DailySlot(
        date: newDate,
        dayOfWeek: newDate.weekday,
        entries: copiedEntries,
      );
    });

    final newSchedule = WeeklySchedule(
      weekStartDate: nextMonday,
      weekKey: nextWeekKey,
      dailySlots: newSlots,
    );
    await saveSchedule(newSchedule);
    return newSchedule;
  }

  // ── プライベートヘルパー ──────────────────────────────────────

  WeeklySchedule _buildFromRegularDays(
    DateTime monday,
    String weekKey,
    List<Customer> customers,
  ) {
    final slots = List.generate(7, (i) {
      final date = monday.add(Duration(days: i));
      final dayOfWeek = date.weekday; // 1=月〜7=日
      final entries = <ScheduleEntry>[];

      for (final customer in customers) {
        if (!customer.isActive) continue;
        if (!customer.regularDays.contains(dayOfWeek)) continue;
        entries.add(ScheduleEntry(
          customerId: customer.id,
          customerName: customer.name,
          status: ScheduleStatus.planned,
        ));
      }
      // 氏名順
      entries.sort((a, b) => a.customerName.compareTo(b.customerName));

      return DailySlot(date: date, dayOfWeek: dayOfWeek, entries: entries);
    });

    return WeeklySchedule(
      weekStartDate: monday,
      weekKey: weekKey,
      dailySlots: slots,
    );
  }
}
