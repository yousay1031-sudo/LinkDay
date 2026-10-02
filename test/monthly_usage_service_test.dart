import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/monthly_usage_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/utils/week_util.dart';

/// Day 9: 月間支給量の残日数管理
///
/// 【Hive.init（hive パッケージ）を使う理由】
/// Hive.initFlutter（hive_flutter）は path_provider に依存し VM テストで
/// MissingPluginException になるため、一時ディレクトリを明示指定する。
void main() {
  late Directory tmp;
  final svc = MonthlyUsageService.instance;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('linkday_day9_');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(CustomerAdapter());
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(AttendanceRecordAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(AttendanceStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(WeeklyScheduleAdapter());
    }
    if (!Hive.isAdapterRegistered(4)) Hive.registerAdapter(DailySlotAdapter());
    if (!Hive.isAdapterRegistered(5)) {
      Hive.registerAdapter(ScheduleStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(6)) {
      Hive.registerAdapter(ScheduleEntryAdapter());
    }
    await CustomerService.instance.init();
    await AttendanceService.instance.init();
    await WeeklyScheduleService.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  setUp(() async {
    await Hive.box<Customer>('customers').clear();
    await Hive.box<AttendanceRecord>('attendance_records').clear();
    await Hive.box<WeeklySchedule>('weekly_schedules').clear();
  });

  // ── ヘルパー ─────────────────────────────────────────────────

  Future<Customer> addCustomer({
    String id = 'c1',
    String name = '田中 健太',
    int available = 23,
    int cachedUsed = 0,
    List<int>? regularDays,
    bool isActive = true,
  }) async {
    final c = Customer(
      id: id,
      name: name,
      nameKana: 'タナカ ケンタ',
      monthlyAvailableDays: available,
      currentMonthUsedDays: cachedUsed,
      regularDays: regularDays ?? [],
      isActive: isActive,
    );
    await CustomerService.instance.addCustomer(c);
    return c;
  }

  /// 出席レコードを直接作る（status を厳密に制御するため service の markX は使わない）
  Future<void> putRecord(
    String customerId,
    DateTime date,
    AttendanceStatus status, {
    String name = '田中 健太',
  }) async {
    await AttendanceService.instance.upsertRecord(AttendanceRecord(
      customerId: customerId,
      customerName: name,
      dateKey: AttendanceRecord.makeDateKey(date),
      status: status,
      checkInTime: (status == AttendanceStatus.present ||
              status == AttendanceStatus.departed)
          ? DateTime(date.year, date.month, date.day, 9)
          : null,
      checkOutTime: status == AttendanceStatus.departed
          ? DateTime(date.year, date.month, date.day, 15)
          : null,
    ));
  }

  /// 週間利用計画にエントリを追加する
  Future<void> putWeeklyEntry(
    String customerId,
    DateTime date,
    ScheduleStatus status, {
    String name = '田中 健太',
  }) async {
    final weekStart = WeekUtil.weekStartFromDate(date);
    final weekKey = WeekUtil.weekKeyFromDate(date);
    // regularDays からの自動生成を避けるため、顧客リストは空で作る
    // （テストは明示的に追加したエントリのみを検証したい）
    final schedule = await WeeklyScheduleService.instance
        .getOrCreateSchedule(weekStart, const []);
    final slot = schedule.slotForDate(date)!;
    slot.entries.removeWhere((e) => e.customerId == customerId);
    slot.entries.add(ScheduleEntry(
      customerId: customerId,
      customerName: name,
      status: status,
    ));
    await WeeklyScheduleService.instance.saveSchedule(schedule);
    expect(WeeklyScheduleService.instance.getScheduleByWeekKey(weekKey),
        isNotNull);
  }

  // ════════════════════════════════════════════════════════════════
  // 日付ユーティリティ（境界: 月跨ぎ・うるう年）
  // ════════════════════════════════════════════════════════════════

  group('日付境界', () {
    test('lastDayOfMonth: 31/30/28 日の月', () {
      expect(MonthlyUsageService.lastDayOfMonth(DateTime(2026, 1)), 31);
      expect(MonthlyUsageService.lastDayOfMonth(DateTime(2026, 4)), 30);
      expect(MonthlyUsageService.lastDayOfMonth(DateTime(2026, 2)), 28);
    });

    test('lastDayOfMonth: うるう年 2 月は 29 日', () {
      expect(MonthlyUsageService.lastDayOfMonth(DateTime(2024, 2)), 29);
      expect(MonthlyUsageService.lastDayOfMonth(DateTime(2028, 2)), 29);
      // 400年ルール: 2000 はうるう年、2100 は平年
      expect(MonthlyUsageService.lastDayOfMonth(DateTime(2000, 2)), 29);
      expect(MonthlyUsageService.lastDayOfMonth(DateTime(2100, 2)), 28);
    });

    test('lastDayOfMonth: 12 月（翌年繰り上がり）も正しく 31 日', () {
      expect(MonthlyUsageService.lastDayOfMonth(DateTime(2026, 12)), 31);
    });

    test('monthStart / isSameMonth', () {
      expect(MonthlyUsageService.monthStart(DateTime(2026, 10, 17, 23, 59)),
          DateTime(2026, 10));
      expect(
          MonthlyUsageService.isSameMonth(
              DateTime(2026, 10, 1), DateTime(2026, 10, 31, 23, 59)),
          isTrue);
      expect(
          MonthlyUsageService.isSameMonth(
              DateTime(2026, 10, 31), DateTime(2026, 11, 1)),
          isFalse);
    });

    test('monthKeyOf: ゼロ埋め', () {
      expect(MonthlyUsageService.monthKeyOf(DateTime(2026, 3, 5)), '2026-03');
      expect(MonthlyUsageService.monthKeyOf(DateTime(2026, 12, 5)), '2026-12');
    });
  });

  // ════════════════════════════════════════════════════════════════
  // 支給量のフォールバック
  // ════════════════════════════════════════════════════════════════

  group('monthlyAvailableDays のフォールバック', () {
    test('0 / 負数 → 既定 23', () {
      expect(MonthlyUsageService.effectiveAvailable(0), 23);
      expect(MonthlyUsageService.effectiveAvailable(-5), 23);
      expect(MonthlyUsageService.isAvailableFallback(0), isTrue);
    });

    test('31 超（桁間違い）→ 既定 23', () {
      expect(MonthlyUsageService.effectiveAvailable(32), 23);
      expect(MonthlyUsageService.effectiveAvailable(230), 23);
      expect(MonthlyUsageService.isAvailableFallback(230), isTrue);
    });

    test('1〜31 は有効値としてそのまま', () {
      for (final v in [1, 10, 23, 31]) {
        expect(MonthlyUsageService.effectiveAvailable(v), v);
        expect(MonthlyUsageService.isAvailableFallback(v), isFalse);
      }
    });

    test('支給量 0 の児童は 23 日としてフォールバックし、フラグが立つ', () async {
      await addCustomer(available: 0);
      final u = await svc.getUsage('c1', DateTime(2026, 10, 15),
          today: DateTime(2026, 10, 15));
      expect(u.available, 23);
      expect(u.rawAvailable, 0);
      expect(u.availableFallback, isTrue);
    });
  });

  // ════════════════════════════════════════════════════════════════
  // 実績カウントルール
  // ════════════════════════════════════════════════════════════════

  group('実績カウント', () {
    test('在室 / 退室 はカウント、欠席 / 予定(過去) はカウントしない', () async {
      await addCustomer();
      final today = DateTime(2026, 10, 20);
      // 実績 3 日（present 1 + departed 2）
      await putRecord('c1', DateTime(2026, 10, 1), AttendanceStatus.departed);
      await putRecord('c1', DateTime(2026, 10, 2), AttendanceStatus.departed);
      await putRecord('c1', DateTime(2026, 10, 20), AttendanceStatus.present);
      // カウントしない
      await putRecord('c1', DateTime(2026, 10, 5), AttendanceStatus.absent);
      await putRecord('c1', DateTime(2026, 10, 6), AttendanceStatus.scheduled);

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.usedActual, 3);
      expect(u.dayKinds[1], DayUsageKind.actual);
      expect(u.dayKinds[20], DayUsageKind.actual);
      expect(u.dayKinds[5], DayUsageKind.absent);
      // 過去の「予定のみ」は実績でも予定でもない
      expect(u.dayKinds[6], DayUsageKind.none);
      expect(u.plannedRemaining, 0);
    });

    test('同日複数レコードは 1 日扱い（customerId + dateKey で一意）', () async {
      await addCustomer();
      final date = DateTime(2026, 10, 10);
      // 同じ児童・同じ日に 3 回 upsert しても 1 レコードに収束する
      await putRecord('c1', date, AttendanceStatus.present);
      await putRecord('c1', date, AttendanceStatus.departed);
      await putRecord('c1', date, AttendanceStatus.departed);

      final u = await svc.getUsage('c1', date, today: DateTime(2026, 10, 20));
      expect(u.usedActual, 1, reason: '同日複数レコードは 1 日としてカウントされるべき');
      expect(u.dayKinds[10], DayUsageKind.actual);
    });

    test('他児童のレコードは混ざらない', () async {
      await addCustomer(id: 'c1', name: 'A');
      await addCustomer(id: 'c2', name: 'B');
      await putRecord('c1', DateTime(2026, 10, 1), AttendanceStatus.departed,
          name: 'A');
      await putRecord('c2', DateTime(2026, 10, 1), AttendanceStatus.departed,
          name: 'B');
      await putRecord('c2', DateTime(2026, 10, 2), AttendanceStatus.departed,
          name: 'B');

      final today = DateTime(2026, 10, 20);
      expect((await svc.getUsage('c1', today, today: today)).usedActual, 1);
      expect((await svc.getUsage('c2', today, today: today)).usedActual, 2);
    });

    test('月跨ぎ: 前月・翌月の実績は当月に含まれない', () async {
      await addCustomer();
      // 前月末・当月初・当月末・翌月初
      await putRecord('c1', DateTime(2026, 9, 30), AttendanceStatus.departed);
      await putRecord('c1', DateTime(2026, 10, 1), AttendanceStatus.departed);
      await putRecord('c1', DateTime(2026, 10, 31), AttendanceStatus.departed);
      await putRecord('c1', DateTime(2026, 11, 1), AttendanceStatus.departed);

      final u = await svc.getUsage('c1', DateTime(2026, 10, 15),
          today: DateTime(2026, 11, 5));
      expect(u.usedActual, 2, reason: '10/1 と 10/31 のみ');
      // 前月を集計すれば 9/30 の 1 件
      final prev = await svc.getUsage('c1', DateTime(2026, 9, 15),
          today: DateTime(2026, 11, 5));
      expect(prev.usedActual, 1);
    });

    test('うるう年 2/29 の実績がカウントされる', () async {
      await addCustomer();
      await putRecord('c1', DateTime(2024, 2, 29), AttendanceStatus.departed);
      final u = await svc.getUsage('c1', DateTime(2024, 2, 1),
          today: DateTime(2024, 3, 5));
      expect(u.usedActual, 1);
      expect(u.dayKinds[29], DayUsageKind.actual);
      // 平年 2 月には 29 日が存在しない
      final u2 = await svc.getUsage('c1', DateTime(2026, 2, 1),
          today: DateTime(2026, 3, 5));
      expect(u2.dayKinds.containsKey(29), isFalse);
    });

    test('日跨ぎ: 当日の実績は時刻に関係なくカウントされる', () async {
      await addCustomer();
      final date = DateTime(2026, 10, 20);
      await putRecord('c1', date, AttendanceStatus.present);
      // 同日の 0:01 / 23:59 どちらを「今日」としても結果は同じ
      for (final t in [
        DateTime(2026, 10, 20, 0, 1),
        DateTime(2026, 10, 20, 23, 59),
      ]) {
        final u = await svc.getUsage('c1', t, today: t);
        expect(u.usedActual, 1, reason: '$t');
      }
    });
  });

  // ════════════════════════════════════════════════════════════════
  // 見込み残（今後の予定の取り込み）
  // ════════════════════════════════════════════════════════════════

  group('見込み残の計算', () {
    test('今日以降の出席予定（scheduled）が見込みに算入される', () async {
      await addCustomer(available: 10);
      final today = DateTime(2026, 10, 15);
      // 実績 4 日
      for (final d in [1, 2, 3, 4]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.departed);
      }
      // 今日以降の予定 3 日（今日含む）
      for (final d in [15, 16, 20]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.scheduled);
      }

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.usedActual, 4);
      expect(u.plannedRemaining, 3);
      expect(u.projectedTotal, 7);
      expect(u.remainingActual, 6); // 10 - 4
      expect(u.remainingProjected, 3); // 10 - 7
      expect(u.isOverProjected, isFalse);
      expect(u.dayKinds[15], DayUsageKind.planned);
    });

    test('週間利用計画の予定（出席レコードなし）が見込みに算入される', () async {
      await addCustomer(available: 5);
      final today = DateTime(2026, 10, 15);
      await putRecord('c1', DateTime(2026, 10, 1), AttendanceStatus.departed);
      // 週間利用計画のみ（出席レコード未生成）
      await putWeeklyEntry('c1', DateTime(2026, 10, 16), ScheduleStatus.planned);
      await putWeeklyEntry(
          'c1', DateTime(2026, 10, 17), ScheduleStatus.additional);

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.usedActual, 1);
      expect(u.plannedRemaining, 2, reason: 'planned + additional');
      expect(u.remainingProjected, 2); // 5 - 3
    });

    test('cancelled の週間計画は見込みに算入されない', () async {
      await addCustomer(available: 5);
      final today = DateTime(2026, 10, 15);
      await putWeeklyEntry(
          'c1', DateTime(2026, 10, 16), ScheduleStatus.cancelled);
      await putWeeklyEntry('c1', DateTime(2026, 10, 17), ScheduleStatus.planned);

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.plannedRemaining, 1, reason: 'cancelled は除外、planned のみ');
      expect(u.dayKinds[16], DayUsageKind.none);
      expect(u.dayKinds[17], DayUsageKind.planned);
    });

    test('出席レコードが週間計画より優先され二重計上しない', () async {
      await addCustomer(available: 10);
      final today = DateTime(2026, 10, 15);
      final target = DateTime(2026, 10, 16);
      // 同じ日に「出席予定」と「週間計画」の両方がある
      await putRecord('c1', target, AttendanceStatus.scheduled);
      await putWeeklyEntry('c1', target, ScheduleStatus.planned);

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.plannedRemaining, 1, reason: '同日は 1 日としてのみ算入');
    });

    test('同日に実績があれば週間計画は加算されない（実績優先）', () async {
      await addCustomer(available: 10);
      final today = DateTime(2026, 10, 16);
      final target = DateTime(2026, 10, 16);
      await putRecord('c1', target, AttendanceStatus.present);
      await putWeeklyEntry('c1', target, ScheduleStatus.planned);

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.usedActual, 1);
      expect(u.plannedRemaining, 0, reason: '実績日は予定として二重計上しない');
      expect(u.projectedTotal, 1);
    });

    test('過去日の週間計画は見込みに算入されない', () async {
      await addCustomer(available: 10);
      final today = DateTime(2026, 10, 15);
      // 過去日（出席レコードなし = 結果的に未利用）
      await putWeeklyEntry('c1', DateTime(2026, 10, 5), ScheduleStatus.planned);

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.plannedRemaining, 0);
      expect(u.dayKinds[5], DayUsageKind.none);
    });

    test('欠席予定日（absent）は今後日でも見込みに算入されない', () async {
      await addCustomer(available: 10);
      final today = DateTime(2026, 10, 15);
      await putRecord('c1', DateTime(2026, 10, 20), AttendanceStatus.absent);

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.plannedRemaining, 0);
      expect(u.dayKinds[20], DayUsageKind.absent);
    });
  });

  // ════════════════════════════════════════════════════════════════
  // 超過判定
  // ════════════════════════════════════════════════════════════════

  group('超過判定', () {
    test('見込み残マイナス → isOverProjected', () async {
      await addCustomer(available: 5);
      final today = DateTime(2026, 10, 15);
      for (final d in [1, 2, 3, 4]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.departed);
      }
      for (final d in [16, 17, 18]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.scheduled);
      }

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.usedActual, 4);
      expect(u.plannedRemaining, 3);
      expect(u.projectedTotal, 7);
      expect(u.remainingActual, 1);
      expect(u.remainingProjected, -2);
      expect(u.isOverProjected, isTrue);
      expect(u.overProjectedDays, 2);
      expect(u.isOverActual, isFalse, reason: '実績だけならまだ超過していない');
    });

    test('実績で既に超過 → isOverActual かつ isExhausted', () async {
      await addCustomer(available: 2);
      final today = DateTime(2026, 10, 15);
      for (final d in [1, 2, 3]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.departed);
      }
      final u = await svc.getUsage('c1', today, today: today);
      expect(u.remainingActual, -1);
      expect(u.isOverActual, isTrue);
      expect(u.isExhausted, isTrue);
      expect(u.isOverProjected, isTrue);
    });

    test('残1〜5 → isLow、残6以上 → 通常', () async {
      await addCustomer(available: 10);
      final today = DateTime(2026, 10, 20);
      // 実績 5 日 → 残 5 → isLow
      for (final d in [1, 2, 3, 4, 5]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.departed);
      }
      var u = await svc.getUsage('c1', today, today: today);
      expect(u.remainingActual, 5);
      expect(u.isLow, isTrue);
      expect(u.isExhausted, isFalse);

      // 実績 4 日に減らす → 残 6 → 通常
      await AttendanceService.instance
          .deleteRecord('c1', DateTime(2026, 10, 5));
      u = await svc.getUsage('c1', today, today: today);
      expect(u.remainingActual, 6);
      expect(u.isLow, isFalse);
    });

    test('ちょうど使い切り（残0）は超過ではない', () async {
      await addCustomer(available: 3);
      final today = DateTime(2026, 10, 15);
      for (final d in [1, 2, 3]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.departed);
      }
      final u = await svc.getUsage('c1', today, today: today);
      expect(u.remainingActual, 0);
      expect(u.remainingProjected, 0);
      expect(u.isOverProjected, isFalse);
      expect(u.isExhausted, isTrue, reason: '残0 は赤表示対象');
    });

    test('checkOverageAfterCheckIn: 超過時のみ MonthlyUsage を返す', () async {
      await addCustomer(available: 2, name: '田中 健太');
      final today = DateTime(2026, 10, 15);
      // 実績 1 日 → 超過なし
      await putRecord('c1', DateTime(2026, 10, 1), AttendanceStatus.departed);
      expect(await svc.checkOverageAfterCheckIn('c1', today: today), isNull);

      // 実績 3 日 → 超過
      await putRecord('c1', DateTime(2026, 10, 2), AttendanceStatus.departed);
      await putRecord('c1', today, AttendanceStatus.present);
      final warn = await svc.checkOverageAfterCheckIn('c1', today: today);
      expect(warn, isNotNull);
      expect(warn!.projectedTotal, 3);
      expect(warn.available, 2);
      expect(warn.customerName, '田中 健太');
    });
  });

  // ════════════════════════════════════════════════════════════════
  // キャッシュ（currentMonthUsedDays）の差異検出・補正
  // ════════════════════════════════════════════════════════════════

  group('currentMonthUsedDays キャッシュ整合', () {
    test('差異があれば動的計算を正としてキャッシュを補正する', () async {
      await addCustomer(available: 23, cachedUsed: 99); // 明らかに不整合
      final today = DateTime(2026, 10, 15);
      await putRecord('c1', DateTime(2026, 10, 1), AttendanceStatus.departed);
      await putRecord('c1', DateTime(2026, 10, 2), AttendanceStatus.departed);

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.usedActual, 2, reason: '動的計算が正');
      // キャッシュが補正されている
      expect(CustomerService.instance.getCustomerById('c1')!.currentMonthUsedDays, 2);
    });

    test('一致していればキャッシュを書き換えない（updatedAt を温存）', () async {
      await addCustomer(available: 23, cachedUsed: 1);
      final today = DateTime(2026, 10, 15);
      await putRecord('c1', DateTime(2026, 10, 1), AttendanceStatus.departed);
      final before =
          CustomerService.instance.getCustomerById('c1')!.updatedAt;
      await Future.delayed(const Duration(milliseconds: 5));

      await svc.getUsage('c1', today, today: today);
      final after = CustomerService.instance.getCustomerById('c1')!;
      expect(after.currentMonthUsedDays, 1);
      expect(after.updatedAt, before, reason: '不要な更新を行わない');
    });

    test('過去月の集計では当月キャッシュを壊さない', () async {
      await addCustomer(available: 23, cachedUsed: 7);
      final today = DateTime(2026, 10, 15);
      await putRecord('c1', DateTime(2026, 9, 1), AttendanceStatus.departed);

      // 9 月を集計（実績 1 日）しても 10 月のキャッシュ 7 は変更されない
      final sep = await svc.getUsage('c1', DateTime(2026, 9, 1), today: today);
      expect(sep.usedActual, 1);
      expect(CustomerService.instance.getCustomerById('c1')!.currentMonthUsedDays, 7);
    });

    test('reconcileCache=false なら補正しない', () async {
      await addCustomer(available: 23, cachedUsed: 42);
      final today = DateTime(2026, 10, 15);
      await putRecord('c1', DateTime(2026, 10, 1), AttendanceStatus.departed);

      await svc.getUsage('c1', today, today: today, reconcileCache: false);
      expect(CustomerService.instance.getCustomerById('c1')!.currentMonthUsedDays, 42);
    });
  });

  // ════════════════════════════════════════════════════════════════
  // 全件集計
  // ════════════════════════════════════════════════════════════════

  group('getAllUsage / getOverProjected', () {
    test('在籍児童のみ集計し、超過見込みを抽出できる', () async {
      // A: 余裕あり / B: 超過見込み / C: 退所（集計対象外）
      await addCustomer(id: 'a', name: 'A', available: 23);
      await addCustomer(id: 'b', name: 'B', available: 3);
      await addCustomer(id: 'c', name: 'C', available: 1, isActive: false);
      final today = DateTime(2026, 10, 15);

      await putRecord('a', DateTime(2026, 10, 1), AttendanceStatus.departed,
          name: 'A');
      for (final d in [1, 2, 3]) {
        await putRecord('b', DateTime(2026, 10, d), AttendanceStatus.departed,
            name: 'B');
      }
      await putRecord('b', DateTime(2026, 10, 20), AttendanceStatus.scheduled,
          name: 'B');
      await putRecord('c', DateTime(2026, 10, 1), AttendanceStatus.departed,
          name: 'C');

      final all = await svc.getAllUsage(today, today: today);
      expect(all.length, 2, reason: '退所児童は含まない');
      expect(all.map((u) => u.customerId).toSet(), {'a', 'b'});

      final over = await svc.getOverProjected(today, today: today);
      expect(over.length, 1);
      expect(over.single.customerId, 'b');
      expect(over.single.remainingProjected, -1); // 3 - 4

      // activeOnly=false なら退所児童も含む
      final withInactive =
          await svc.getAllUsage(today, today: today, activeOnly: false);
      expect(withInactive.length, 3);
    });

    test('児童 0 件でも例外にならない', () async {
      final all = await svc.getAllUsage(DateTime(2026, 10, 15),
          today: DateTime(2026, 10, 15));
      expect(all, isEmpty);
      final over = await svc.getOverProjected(DateTime(2026, 10, 15),
          today: DateTime(2026, 10, 15));
      expect(over, isEmpty);
    });

    test('getOverProjected は残が少ない順（深刻な順）に並ぶ', () async {
      await addCustomer(id: 'x', name: 'X', available: 2);
      await addCustomer(id: 'y', name: 'Y', available: 1);
      final today = DateTime(2026, 10, 15);
      // X: 実績3 → -1 / Y: 実績4 → -3
      for (final d in [1, 2, 3]) {
        await putRecord('x', DateTime(2026, 10, d), AttendanceStatus.departed,
            name: 'X');
      }
      for (final d in [1, 2, 3, 4]) {
        await putRecord('y', DateTime(2026, 10, d), AttendanceStatus.departed,
            name: 'Y');
      }
      final over = await svc.getOverProjected(today, today: today);
      expect(over.map((u) => u.customerId).toList(), ['y', 'x']);
    });

    test('存在しない customerId でも既定値で返る（クラッシュしない）', () async {
      final u = await svc.getUsage('missing', DateTime(2026, 10, 15),
          today: DateTime(2026, 10, 15));
      expect(u.available, 23);
      expect(u.usedActual, 0);
      expect(u.customerName, '');
    });
  });

  // ════════════════════════════════════════════════════════════════
  // 表示ラベル
  // ════════════════════════════════════════════════════════════════

  group('表示ラベル', () {
    test('usageLabel / chipLabel / monthKey', () async {
      await addCustomer(available: 23);
      final today = DateTime(2026, 10, 20);
      for (final d in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.departed);
      }
      final u = await svc.getUsage('c1', today, today: today);
      expect(u.usageLabel, '12/23日');
      expect(u.chipLabel, '今月 12/23日（残11）');
      expect(u.monthKey, '2026-10');
    });
  });

  // ════════════════════════════════════════════════════════════════
  // 手計算による検証（受け入れ基準4）
  // ════════════════════════════════════════════════════════════════

  group('手計算検証シナリオ', () {
    /// 【シナリオ】田中 健太 / 2026年10月 / 支給量 23 日
    ///
    /// 実績（在室・退室）: 10/1, 2, 5, 6, 7, 8, 9, 12, 13, 14, 15（11日）
    ///   ※ 10/13 は同日 2 レコード upsert → 1 日扱い
    /// 欠席: 10/16（カウントしない）
    /// 今日 = 10/16
    /// 今後の予定:
    ///   出席予定(scheduled): 10/19, 20, 21（3日）
    ///   週間計画のみ: 10/26, 27（2日）
    ///   週間計画 cancelled: 10/28（カウントしない）
    ///   過去日の週間計画: 10/9（カウントしない / 既に実績あり）
    ///
    /// 手計算:
    ///   実績 = 11
    ///   今後予定 = 3 + 2 = 5
    ///   見込み合計 = 11 + 5 = 16
    ///   実績残 = 23 - 11 = 12
    ///   見込み残 = 23 - 16 = 7  → 超過なし
    test('シナリオA: 支給量23・実績11・予定5 → 実績残12 / 見込み残7', () async {
      await addCustomer(available: 23);
      final today = DateTime(2026, 10, 16);

      for (final d in [1, 2, 5, 6, 7, 8, 9, 12, 13, 14, 15]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.departed);
      }
      // 同日 2 回目（1 日扱いの確認）
      await putRecord('c1', DateTime(2026, 10, 13), AttendanceStatus.present);
      await putRecord('c1', DateTime(2026, 10, 16), AttendanceStatus.absent);

      for (final d in [19, 20, 21]) {
        await putRecord('c1', DateTime(2026, 10, d), AttendanceStatus.scheduled);
      }
      await putWeeklyEntry('c1', DateTime(2026, 10, 26), ScheduleStatus.planned);
      await putWeeklyEntry('c1', DateTime(2026, 10, 27), ScheduleStatus.planned);
      await putWeeklyEntry(
          'c1', DateTime(2026, 10, 28), ScheduleStatus.cancelled);
      await putWeeklyEntry('c1', DateTime(2026, 10, 9), ScheduleStatus.planned);

      final u = await svc.getUsage('c1', today, today: today);
      expect(u.available, 23);
      expect(u.usedActual, 11);
      expect(u.plannedRemaining, 5);
      expect(u.projectedTotal, 16);
      expect(u.remainingActual, 12);
      expect(u.remainingProjected, 7);
      expect(u.isOverProjected, isFalse);
      expect(u.usageLabel, '11/23日');
    });

    /// 【シナリオB】佐藤 美咲 / 2026年10月 / 支給量 10 日
    ///   実績: 10/1〜10/9 の平日相当 8 日（1,2,5,6,7,8,9,12）
    ///   今日 = 10/13
    ///   今後予定: 10/13, 14, 15（3日）
    ///   手計算: 実績8 / 予定3 / 合計11 / 実績残2 / 見込み残 -1 → 超過1日
    test('シナリオB: 支給量10・実績8・予定3 → 見込み残 -1（超過1日）', () async {
      await addCustomer(id: 's1', name: '佐藤 美咲', available: 10);
      final today = DateTime(2026, 10, 13);

      for (final d in [1, 2, 5, 6, 7, 8, 9, 12]) {
        await putRecord('s1', DateTime(2026, 10, d), AttendanceStatus.departed,
            name: '佐藤 美咲');
      }
      for (final d in [13, 14, 15]) {
        await putRecord('s1', DateTime(2026, 10, d), AttendanceStatus.scheduled,
            name: '佐藤 美咲');
      }

      final u = await svc.getUsage('s1', today, today: today);
      expect(u.usedActual, 8);
      expect(u.plannedRemaining, 3);
      expect(u.projectedTotal, 11);
      expect(u.remainingActual, 2);
      expect(u.remainingProjected, -1);
      expect(u.isOverProjected, isTrue);
      expect(u.overProjectedDays, 1);
      expect(u.isLow, isTrue, reason: '実績残 2 は橙色表示');
    });

    /// 【シナリオC】月末日（10/31）が今日のケース
    ///   支給量 23 / 実績 22 / 10/31 に予定 1 → 合計 23 → ちょうど使い切り
    test('シナリオC: 月末当日・ちょうど使い切り → 超過なし・残0', () async {
      await addCustomer(id: 'm1', name: '月末', available: 23);
      final today = DateTime(2026, 10, 31);
      // 1〜22 日を実績に
      for (int d = 1; d <= 22; d++) {
        await putRecord('m1', DateTime(2026, 10, d), AttendanceStatus.departed,
            name: '月末');
      }
      await putRecord('m1', DateTime(2026, 10, 31), AttendanceStatus.scheduled,
          name: '月末');

      final u = await svc.getUsage('m1', today, today: today);
      expect(u.usedActual, 22);
      expect(u.plannedRemaining, 1);
      expect(u.projectedTotal, 23);
      expect(u.remainingProjected, 0);
      expect(u.isOverProjected, isFalse);
    });
  });
}
