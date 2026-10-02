import 'package:flutter/foundation.dart';

import '../models/attendance_record.dart';
import '../models/customer.dart';
import '../models/weekly_schedule.dart';
import 'attendance_service.dart';
import 'customer_service.dart';
import 'weekly_schedule_service.dart';

/// 当月の 1 日分の利用種別（カレンダー描画用）
enum DayUsageKind {
  /// 実績あり（在室 or 退室）→ 支給量を消費した日
  actual,

  /// 今後の利用予定（出席予定 or 週間利用計画）
  planned,

  /// 欠席（支給量を消費しない）
  absent,

  /// 利用なし
  none,
}

/// 月間利用状況（1 児童 1 ヶ月分）
///
/// 【制度上の意味】
/// 放課後等デイサービスは受給者証に「月間支給量（日数）」が定められており、
/// これを超えた利用は原則自費（利用者負担）になる。
/// 本クラスは「実績」と「見込み」を分離して保持し、
/// 超過を事前に検知（[isOverProjected]）できるようにする。
@immutable
class MonthlyUsage {
  final String customerId;
  final String customerName;

  /// 対象月（その月の 1 日 0:00 に正規化）
  final DateTime month;

  /// 月間支給量（不正値はフォールバック後の有効値）
  final int available;

  /// 実績利用日数（在室 or 退室。同日複数レコードは 1 日）
  final int usedActual;

  /// 今後の利用予定日数（今日以降の予定。実績とは重複しない）
  final int plannedRemaining;

  /// 日別の利用種別（key = 日, 1..月末）
  final Map<int, DayUsageKind> dayKinds;

  /// 支給量が不正値でフォールバックしたか
  final bool availableFallback;

  /// 元の（生の）支給量
  final int rawAvailable;

  const MonthlyUsage({
    required this.customerId,
    required this.customerName,
    required this.month,
    required this.available,
    required this.usedActual,
    required this.plannedRemaining,
    this.dayKinds = const {},
    this.availableFallback = false,
    required this.rawAvailable,
  });

  /// 実績 + 今後予定の合計見込み
  int get projectedTotal => usedActual + plannedRemaining;

  /// 実績残（今日まで）= 支給量 - 実績
  int get remainingActual => available - usedActual;

  /// 見込み残 = 支給量 - (実績 + 今後予定)
  int get remainingProjected => available - projectedTotal;

  /// 支給超過見込み（最重要アラート）
  bool get isOverProjected => remainingProjected < 0;

  /// 既に実績で超過している
  bool get isOverActual => remainingActual < 0;

  /// 超過見込み日数（超過していなければ 0）
  int get overProjectedDays => isOverProjected ? -remainingProjected : 0;

  /// 残りわずか（1〜5 日）— UI の橙色判定
  bool get isLow => remainingActual >= 1 && remainingActual <= 5;

  /// 実績残が 0 以下 — UI の赤色判定
  bool get isExhausted => remainingActual <= 0;

  /// 「12/23日」形式の表示ラベル
  String get usageLabel => '$usedActual/$available日';

  /// 「今月 12/23日（残11）」形式のチップ用ラベル
  String get chipLabel => '今月 $usageLabel（残$remainingActual）';

  /// 月の表示ラベル（2026-10 形式）
  String get monthKey =>
      '${month.year}-${month.month.toString().padLeft(2, '0')}';

  @override
  String toString() => 'MonthlyUsage($customerName, $monthKey, '
      'available=$available, actual=$usedActual, planned=$plannedRemaining, '
      'remainActual=$remainingActual, remainProjected=$remainingProjected'
      '${isOverProjected ? ', OVER' : ''})';
}

/// 月間支給量の残日数管理サービス（Day 9）
///
/// 【集計の正は AttendanceRecord の動的計算】
/// Customer.currentMonthUsedDays は表示高速化のためのキャッシュであり、
/// 月跨ぎ・手動修正・インポートで実態とズレる可能性がある。
/// そのため本サービスは毎回 AttendanceService から動的に集計し、
/// キャッシュと差異があればログを出して補正する（[getUsage] の reconcile）。
///
/// 【Hive 直接アクセスをしない】
/// 集計は AttendanceService / WeeklyScheduleService / CustomerService の
/// 公開 API 経由のみで行う（box を直接触らない）。
class MonthlyUsageService {
  MonthlyUsageService._();
  static final MonthlyUsageService instance = MonthlyUsageService._();

  /// 支給量の既定値（受給者証の一般的な上限）
  static const int defaultAvailableDays = 23;

  /// 支給量として妥当な上限（1 ヶ月の最大日数）
  static const int maxAvailableDays = 31;

  // ── 日付ユーティリティ ───────────────────────────────────────

  /// 月初（その月の 1 日 0:00）に正規化
  static DateTime monthStart(DateTime d) => DateTime(d.year, d.month);

  /// 月末日（28/29/30/31。うるう年対応）
  ///
  /// DateTime(year, month + 1, 0) は「翌月 0 日」=「当月末日」を表す。
  /// month = 12 のときも DateTime が自動的に翌年 1 月として扱うため安全。
  static int lastDayOfMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;

  /// 日付のみ（時刻切り捨て）
  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 同じ年月か
  static bool isSameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;

  /// 支給量の有効値を返す（不正値は既定値にフォールバック）
  ///
  /// - 0 以下（未設定・0 埋め）→ 既定値 23
  /// - 31 超（桁間違い等）→ 既定値 23
  static int effectiveAvailable(int raw) {
    if (raw < 1 || raw > maxAvailableDays) return defaultAvailableDays;
    return raw;
  }

  /// [raw] がフォールバック対象か
  static bool isAvailableFallback(int raw) => effectiveAvailable(raw) != raw;

  // ── 集計 ─────────────────────────────────────────────────────

  /// 1 児童の月間利用状況を算出する
  ///
  /// [yearMonth] は対象月（日は無視）。[today] はテスト用の基準日
  /// （省略時は DateTime.now()）。
  /// [reconcileCache] = true のとき、当月かつ Customer.currentMonthUsedDays が
  /// 実績と異なる場合にログを出してキャッシュを補正する。
  Future<MonthlyUsage> getUsage(
    String customerId,
    DateTime yearMonth, {
    DateTime? today,
    bool reconcileCache = true,
  }) async {
    final customer = CustomerService.instance.getCustomerById(customerId);
    final usage = _compute(
      customerId: customerId,
      customerName: customer?.name ?? '',
      rawAvailable: customer?.monthlyAvailableDays ?? defaultAvailableDays,
      yearMonth: yearMonth,
      today: today ?? DateTime.now(),
    );
    if (reconcileCache && customer != null) {
      await _reconcileCache(customer, usage, today ?? DateTime.now());
    }
    return usage;
  }

  /// 全（在籍）児童の月間利用状況を算出する
  ///
  /// [activeOnly] = true（既定）のとき isActive の児童のみ対象。
  Future<List<MonthlyUsage>> getAllUsage(
    DateTime yearMonth, {
    DateTime? today,
    bool activeOnly = true,
    bool reconcileCache = true,
  }) async {
    final base = today ?? DateTime.now();
    // getAllCustomers() は既定で isActive のみ返すため、
    // activeOnly=false のときは includeInactive で退所児童も取得する。
    final customers = CustomerService.instance
        .getAllCustomers(includeInactive: !activeOnly)
        .where((c) => !activeOnly || c.isActive)
        .toList();

    final out = <MonthlyUsage>[];
    for (final c in customers) {
      final usage = _compute(
        customerId: c.id,
        customerName: c.name,
        rawAvailable: c.monthlyAvailableDays,
        yearMonth: yearMonth,
        today: base,
      );
      if (reconcileCache) {
        await _reconcileCache(c, usage, base);
      }
      out.add(usage);
    }

    final over = out.where((u) => u.isOverProjected).length;
    debugPrint('[MonthlyUsage] ${out.isEmpty ? monthKeyOf(yearMonth) : out.first.monthKey}: '
        'computed ${out.length}件, overProjected=$over件');
    return out;
  }

  /// 支給超過見込みの児童のみ返す（ホーム画面サマリー用）
  Future<List<MonthlyUsage>> getOverProjected(
    DateTime yearMonth, {
    DateTime? today,
  }) async {
    final all = await getAllUsage(yearMonth, today: today);
    return all.where((u) => u.isOverProjected).toList()
      ..sort((a, b) => a.remainingProjected.compareTo(b.remainingProjected));
  }

  /// 「在室」登録直後の超過判定（出席画面の即時警告用）
  ///
  /// 警告が不要な場合は null を返す。
  Future<MonthlyUsage?> checkOverageAfterCheckIn(
    String customerId, {
    DateTime? today,
  }) async {
    final base = today ?? DateTime.now();
    final usage = await getUsage(customerId, base, today: base);
    if (!usage.isOverProjected) return null;
    debugPrint('[MonthlyUsage] overage warning: ${usage.customerName} '
        '${usage.projectedTotal}/${usage.available}日 '
        '(超過${usage.overProjectedDays}日)');
    return usage;
  }

  /// 月キー文字列（2026-10）
  static String monthKeyOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}';

  // ── 内部実装 ─────────────────────────────────────────────────

  /// 月間利用状況の実計算
  ///
  /// 【カウントルール】
  /// - 実績: status が present / departed の日（1 日 1 回）
  /// - カウントしない: absent（欠席）、過去の scheduled（未出席）、cancelled
  /// - 今後予定: 今日以降の日で
  ///     1) 出席レコードが scheduled → 予定 1 日
  ///     2) 出席レコードなし かつ 週間利用計画に非 cancelled エントリあり → 予定 1 日
  ///   （出席レコードを優先するため二重計上しない）
  MonthlyUsage _compute({
    required String customerId,
    required String customerName,
    required int rawAvailable,
    required DateTime yearMonth,
    required DateTime today,
  }) {
    final month = monthStart(yearMonth);
    final lastDay = lastDayOfMonth(month);
    final todayDate = dateOnly(today);

    int actual = 0;
    int planned = 0;
    final kinds = <int, DayUsageKind>{};

    final attendance = AttendanceService.instance;
    final weekly = WeeklyScheduleService.instance;

    for (int day = 1; day <= lastDay; day++) {
      final date = DateTime(month.year, month.month, day);
      // 日付のみ比較（時刻は無視）
      final isFutureOrToday = !date.isBefore(todayDate);

      // 出席レコードは customerId + dateKey で一意（1 日 1 レコード）なので、
      // 同日複数レコードは構造上 1 日扱いになる。
      final record = attendance.getRecord(customerId, date);

      if (record != null) {
        switch (record.status) {
          case AttendanceStatus.present:
          case AttendanceStatus.departed:
            // 実績（過去・当日どちらでもカウント）
            actual++;
            kinds[day] = DayUsageKind.actual;
          case AttendanceStatus.absent:
            // 欠席は支給量を消費しない
            kinds[day] = DayUsageKind.absent;
          case AttendanceStatus.scheduled:
            if (isFutureOrToday) {
              // 今日以降の未出席予定 → 見込みに算入
              planned++;
              kinds[day] = DayUsageKind.planned;
            } else {
              // 過去の「予定のみ」は実績ではない（未出席）
              kinds[day] = DayUsageKind.none;
            }
        }
        continue;
      }

      // 出席レコードなし → 今日以降なら週間利用計画を見る
      if (isFutureOrToday) {
        final entries = weekly.getEntriesForDate(date);
        // getEntriesForDate は cancelled を除外済み
        final hasPlan = entries.any((e) =>
            e.customerId == customerId && e.status != ScheduleStatus.cancelled);
        if (hasPlan) {
          planned++;
          kinds[day] = DayUsageKind.planned;
          continue;
        }
      }
      kinds[day] = DayUsageKind.none;
    }

    return MonthlyUsage(
      customerId: customerId,
      customerName: customerName,
      month: month,
      available: effectiveAvailable(rawAvailable),
      usedActual: actual,
      plannedRemaining: planned,
      dayKinds: kinds,
      availableFallback: isAvailableFallback(rawAvailable),
      rawAvailable: rawAvailable,
    );
  }

  /// Customer.currentMonthUsedDays（キャッシュ）と実績の差異を検出・補正する
  ///
  /// 動的計算（AttendanceRecord）を正とし、差異があればログを出して
  /// キャッシュを実績値に書き換える。対象は当月のみ
  /// （過去月の集計でキャッシュを壊さないため）。
  Future<void> _reconcileCache(
    Customer customer,
    MonthlyUsage usage,
    DateTime today,
  ) async {
    if (!isSameMonth(usage.month, today)) return;
    if (customer.currentMonthUsedDays == usage.usedActual) return;

    debugPrint('[MonthlyUsage] cache mismatch: ${customer.name} '
        'currentMonthUsedDays=${customer.currentMonthUsedDays} → '
        '実績${usage.usedActual}日 に補正します（動的計算を正とする）');
    customer.currentMonthUsedDays = usage.usedActual;
    await CustomerService.instance.updateCustomer(customer);
  }
}
