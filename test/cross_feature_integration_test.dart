import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_import_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/monthly_usage_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/utils/week_util.dart';

/// Day 10: 機能間の相互作用（クロス機能）統合テスト
///
/// Day 1〜9 の機能は個別にはテスト済みだが、「インポート → 位置解決 →
/// 送迎計画 → 月間支給量」のように複数機能をまたぐ経路は未検証だった。
/// 本テストはその結合部分の不整合を検出する。
///
/// 【ウィジェットテストを使わない理由】
/// 出席画面には repeat() による無限アニメーション（在室バッジの
/// パルス表示）があり pumpAndSettle が収束しないため、画面経由ではなく
/// サービス層の公開 API でデータ整合性を検証する。
void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('linkday_cross_');
    Hive.init(tmp.path);
    Hive.registerAdapter(CustomerAdapter());
    Hive.registerAdapter(AttendanceRecordAdapter());
    Hive.registerAdapter(AttendanceStatusAdapter());
    Hive.registerAdapter(WeeklyScheduleAdapter());
    Hive.registerAdapter(DailySlotAdapter());
    Hive.registerAdapter(ScheduleStatusAdapter());
    Hive.registerAdapter(ScheduleEntryAdapter());
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
  });

  Future<void> putRecord(
    String customerId,
    String name,
    DateTime date,
    AttendanceStatus status, {
    String? reason,
  }) async {
    await AttendanceService.instance.upsertRecord(AttendanceRecord(
      customerId: customerId,
      customerName: name,
      dateKey: AttendanceRecord.makeDateKey(date),
      status: status,
      checkInTime: (status == AttendanceStatus.present ||
              status == AttendanceStatus.departed)
          ? date
          : null,
      absenceReason: reason,
    ));
  }


  /// 週間利用計画に 1 件のエントリを設定する
  ///
  /// regularDays からの自動生成を避けるため顧客リストは空で週を作り、
  /// 明示的に追加したエントリのみを検証対象にする。
  Future<void> putPlan(
    String customerId,
    String name,
    DateTime date,
    ScheduleStatus status,
  ) async {
    final weekStart = WeekUtil.weekStartFromDate(date);
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
  }

  // ════════════════════════════════════════════════════════════
  // シナリオ1: インポート → 位置解決 → 出席 → 月間支給量
  // ════════════════════════════════════════════════════════════
  group('シナリオ1: インポート→位置解決→出席→支給量の一連フロー', () {
    test('xlsx 取り込み後、座標解決・出席登録が支給量集計に正しく反映される', () async {
      // 1) 新規インポート（fixture = 正本 10 名）
      final bytes =
          File('test/fixtures/linkday_customer_sample.xlsx').readAsBytesSync();
      final preview =
          CustomerImportService.instance.parse(fileName: 's.xlsx', bytes: bytes);
      final result = await CustomerImportService.instance
          .execute(preview, resolveDuplicate: (_) async => null);

      expect(result.imported, greaterThan(0));
      expect(result.errorCount, 0, reason: 'インポートでエラー行が発生している');
      final customers = CustomerService.instance.getAllCustomers();
      expect(customers.length, result.imported);

      // 2) 位置解決（ジオコーディングの結果を手動採用した状態を再現）
      //    API を叩かずに Day 8 の採用ロジック（setTransportCoord）のみ検証
      final target = customers.first;
      expect(target.transportLocations, isNotEmpty);
      target.setTransportCoord(0, 42.9231, 143.1960, Customer.locResolved,
          formatted: '日本、北海道帯広市東1条南3丁目', types: ['premise']);
      await CustomerService.instance.updateCustomer(target);

      final resolved = CustomerService.instance.getCustomerById(target.id)!;
      expect(resolved.isTransportResolved(0), isTrue,
          reason: '解決済み座標が永続化されていない');

      // 3) 出席登録 → 4) 支給量の残日数が減る
      final month = DateTime(2026, 5, 1);
      final before = await MonthlyUsageService.instance.getUsage(
        target.id,
        month,
        today: month.add(const Duration(days: 20)),
        reconcileCache: false,
      );
      expect(before.usedActual, 0);
      final remainBefore = before.remainingActual;

      await putRecord(
          target.id, target.name, month, AttendanceStatus.departed);
      await putRecord(target.id, target.name,
          month.add(const Duration(days: 1)), AttendanceStatus.departed);

      final after = await MonthlyUsageService.instance.getUsage(
        target.id,
        month,
        today: month.add(const Duration(days: 20)),
        reconcileCache: false,
      );
      expect(after.usedActual, 2);
      expect(after.remainingActual, remainBefore - 2,
          reason: '出席登録後に残日数が減っていない');
    });
  });

  // ════════════════════════════════════════════════════════════
  // シナリオ3: 週間計画変更 → 月間見込み残の即時反映
  // ════════════════════════════════════════════════════════════
  group('シナリオ3: 週間計画変更→見込み残の再計算', () {
    test('週間計画の追加・取消が projected（今後予定）に即時反映される', () async {
      final c = Customer(
        id: 'wk1',
        name: '週間 太郎',
        nameKana: 'シュウカン タロウ',
        monthlyAvailableDays: 10,
      );
      await CustomerService.instance.addCustomer(c);

      // 基準日: 月初（以降すべて「未来」になるよう today を月初に固定）
      final month = DateTime(2026, 6, 1);
      final planDate = DateTime(2026, 6, 10);

      var usage = await MonthlyUsageService.instance.getUsage(
        c.id,
        month,
        today: month,
        reconcileCache: false,
      );
      expect(usage.plannedRemaining, 0);

      // 週間計画に 1 日追加 → 見込みが 1 増える
      await putPlan(c.id, c.name, planDate, ScheduleStatus.planned);

      usage = await MonthlyUsageService.instance.getUsage(
        c.id,
        month,
        today: month,
        reconcileCache: false,
      );
      expect(usage.plannedRemaining, 1, reason: '週間計画の追加が見込みに反映されていない');
      expect(usage.projectedTotal, usage.usedActual + 1);

      // 取消（cancelled）にすると見込みから外れる
      await putPlan(c.id, c.name, planDate, ScheduleStatus.cancelled);

      usage = await MonthlyUsageService.instance.getUsage(
        c.id,
        month,
        today: month,
        reconcileCache: false,
      );
      expect(usage.plannedRemaining, 0,
          reason: 'cancelled が見込みから除外されていない');
    });

    test('出席レコードがある日は週間計画と二重計上されない', () async {
      final c = Customer(
        id: 'wk2',
        name: '二重 花子',
        nameKana: 'ニジュウ ハナコ',
        monthlyAvailableDays: 10,
      );
      await CustomerService.instance.addCustomer(c);

      final month = DateTime(2026, 7, 1);
      final day = DateTime(2026, 7, 15);

      // 同じ日に「週間計画あり」＋「出席レコード(scheduled)」の両方を作る
      await putPlan(c.id, c.name, day, ScheduleStatus.planned);
      await putRecord(c.id, c.name, day, AttendanceStatus.scheduled);

      final usage = await MonthlyUsageService.instance.getUsage(
        c.id,
        month,
        today: month,
        reconcileCache: false,
      );
      // 出席レコードを優先するため 1 日分のみ
      expect(usage.plannedRemaining, 1,
          reason: '週間計画と出席レコードが二重計上されている');
    });
  });

  // ════════════════════════════════════════════════════════════
  // シナリオ4: 出席ステータス変更 → 支給量の再計算
  // ════════════════════════════════════════════════════════════
  group('シナリオ4: 在室→欠席で usedActual が減る', () {
    test('欠席化で実績が減り、同日重複カウントも起きない', () async {
      final c = Customer(
        id: 'att1',
        name: '出席 次郎',
        nameKana: 'シュッセキ ジロウ',
        monthlyAvailableDays: 23,
      );
      await CustomerService.instance.addCustomer(c);

      final month = DateTime(2026, 8, 1);
      for (int i = 0; i < 3; i++) {
        await putRecord(c.id, c.name, month.add(Duration(days: i)),
            AttendanceStatus.present);
      }

      var usage = await MonthlyUsageService.instance.getUsage(
        c.id,
        month,
        today: month.add(const Duration(days: 25)),
        reconcileCache: false,
      );
      expect(usage.usedActual, 3);

      // 在室 → 欠席
      await AttendanceService.instance.markAbsent(
        customerId: c.id,
        date: month,
        reason: '体調不良',
      );

      usage = await MonthlyUsageService.instance.getUsage(
        c.id,
        month,
        today: month.add(const Duration(days: 25)),
        reconcileCache: false,
      );
      expect(usage.usedActual, 2, reason: '欠席化で実績が減っていない');

      // 同じ日に再 upsert しても 1 日扱い（重複カウントしない）
      await putRecord(c.id, c.name, month, AttendanceStatus.present);
      usage = await MonthlyUsageService.instance.getUsage(
        c.id,
        month,
        today: month.add(const Duration(days: 25)),
        reconcileCache: false,
      );
      expect(usage.usedActual, 3, reason: '同日複数レコードが重複カウントされている');
    });

    test('欠席は支給量を消費しない（absent は usedActual に入らない）', () async {
      final c = Customer(
        id: 'att2',
        name: '欠席 三郎',
        nameKana: 'ケッセキ サブロウ',
        monthlyAvailableDays: 23,
      );
      await CustomerService.instance.addCustomer(c);

      final month = DateTime(2026, 9, 1);
      await putRecord(c.id, c.name, month, AttendanceStatus.present);
      await putRecord(c.id, c.name, month.add(const Duration(days: 1)),
          AttendanceStatus.absent, reason: '家族旅行');

      final usage = await MonthlyUsageService.instance.getUsage(
        c.id,
        month,
        today: month.add(const Duration(days: 25)),
        reconcileCache: false,
      );
      expect(usage.usedActual, 1);
    });
  });

  // ════════════════════════════════════════════════════════════
  // シナリオ5: 空データ起動（8b522d6 の回帰確認）
  // ════════════════════════════════════════════════════════════
  group('シナリオ5: 空データ（顧客0・計画0・出席0）で例外が出ない', () {
    test('全サービスが空データでクラッシュせず既定値を返す', () async {
      expect(CustomerService.instance.getAllCustomers(), isEmpty);
      expect(
          AttendanceService.instance.getRecordsByDate(DateTime.now()), isEmpty);
      expect(WeeklyScheduleService.instance.getEntriesForDate(DateTime.now()),
          isEmpty);

      // 月間支給量: 顧客0 でも空リストを返し、例外を投げない
      final all = await MonthlyUsageService.instance
          .getAllUsage(DateTime.now(), reconcileCache: false);
      expect(all, isEmpty);

      final over =
          await MonthlyUsageService.instance.getOverProjected(DateTime.now());
      expect(over, isEmpty);

      // 存在しない顧客 ID でも例外にならず既定値で返る
      final usage = await MonthlyUsageService.instance.getUsage(
        'no-such-customer',
        DateTime.now(),
        reconcileCache: false,
      );
      expect(usage.customerName, '');
      expect(usage.usedActual, 0);
      expect(usage.available, MonthlyUsageService.defaultAvailableDays);
      expect(usage.isOverProjected, isFalse);
    });

    test('送迎場所が空の顧客でも座標アクセスが安全（範囲外 null 返し）', () async {
      final c = Customer(id: 'empty1', name: '空 太郎', nameKana: 'カラ タロウ');
      await CustomerService.instance.addCustomer(c);

      // transportLocations が空 → どのインデックスでも null / 未解決
      expect(c.transportCoord(0), isNull);
      expect(c.transportCoord(5), isNull);
      expect(c.transportStatus(0), Customer.locUnresolved);
      expect(c.isTransportResolved(0), isFalse);
      expect(c.transportFormatted(0), isNull);
      expect(c.transportTypes(0), isEmpty);
    });
  });

  // ════════════════════════════════════════════════════════════
  // Hive 後方互換（旧データ = 座標フィールド未保存）
  // ════════════════════════════════════════════════════════════
  group('Hive 後方互換: 旧スキーマ（座標なし）データの読み込み', () {
    test('座標フィールドを持たない顧客を読み込んでも例外にならない', () async {
      // Day 8 以前のデータ相当（座標リストを渡さない）
      final legacy = Customer(
        id: 'legacy1',
        name: '旧 データ',
        nameKana: 'キュウ データ',
        transportLocations: ['北海道帯広市東1条南3丁目', '帯広駅前'],
      );
      await CustomerService.instance.addCustomer(legacy);

      final loaded = CustomerService.instance.getCustomerById('legacy1')!;
      // 長さが transportLocations に揃えられ、全て未解決になる
      expect(loaded.transportLocationLats.length, 2);
      expect(loaded.transportLocationStatus,
          [Customer.locUnresolved, Customer.locUnresolved]);
      expect(loaded.isTransportResolved(0), isFalse);
      expect(loaded.hasTransportMeta(0), isFalse);
    });
  });
}
