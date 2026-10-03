import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/notification_log.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/vacancy_notification_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';

/// Day 11: 空き枠 LINE 通知 — 候補抽出・二重送信ブロックの単体テスト
///
/// 【Hive.init（hive パッケージ）を使う理由】
/// Hive.initFlutter（hive_flutter）は path_provider に依存し VM テストで
/// MissingPluginException になるため、一時ディレクトリを明示指定する。
///
/// 【Firestore / Functions を呼ばない】
/// setRemoteEnabled(false) によりリモート呼び出しを完全に無効化し、
/// 候補抽出とクライアント側ガードのみを検証する。
void main() {
  late Directory tmp;
  final svc = VacancyNotificationService.instance;

  /// U + 32桁の有効な LINE userId を作る
  String lineId(String seed) =>
      'U${seed.padRight(32, '0').substring(0, 32)}';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // SettingsService.init() が SharedPreferences を使うため、
    // VM テスト用のインメモリ実装を差し込む（MissingPluginException 回避）。
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_day11_');
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
    if (!Hive.isAdapterRegistered(7)) {
      Hive.registerAdapter(AppSettingsAdapter());
    }
    if (!Hive.isAdapterRegistered(11)) {
      Hive.registerAdapter(NotificationLogAdapter());
    }
    if (!Hive.isAdapterRegistered(12)) {
      Hive.registerAdapter(NotificationStatusAdapter());
    }
    await CustomerService.instance.init();
    await AttendanceService.instance.init();
    await WeeklyScheduleService.instance.init();
    await SettingsService.instance.init();
    await svc.init(remoteEnabled: false);
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  setUp(() async {
    await Hive.box<Customer>('customers').clear();
    await Hive.box<AttendanceRecord>('attendance_records').clear();
    await Hive.box<WeeklySchedule>('weekly_schedules').clear();
    await Hive.box<NotificationLog>('notification_logs').clear();
    svc.setRemoteEnabled(false);
  });

  // 対象日: 2026-10-02（金）
  final date = DateTime(2026, 10, 2);

  Future<Customer> addCustomer(
    String id,
    String name, {
    String? lineUserId,
    int monthlyAvailableDays = 23,
    List<int>? regularDays,
  }) async {
    final c = Customer(
      id: id,
      name: name,
      nameKana: 'テスト',
      lineUserId: lineUserId,
      monthlyAvailableDays: monthlyAvailableDays,
      regularDays: regularDays ?? [1, 3, 5],
    );
    await CustomerService.instance.addCustomer(c);
    return c;
  }

  Future<void> putRecord(
    String customerId,
    String name,
    AttendanceStatus status, {
    DateTime? on,
  }) async {
    final d = on ?? date;
    await AttendanceService.instance.upsertRecord(AttendanceRecord(
      customerId: customerId,
      customerName: name,
      dateKey: AttendanceRecord.makeDateKey(d),
      status: status,
      checkInTime: (status == AttendanceStatus.present ||
              status == AttendanceStatus.departed)
          ? DateTime(d.year, d.month, d.day, 9)
          : null,
      checkOutTime: status == AttendanceStatus.departed
          ? DateTime(d.year, d.month, d.day, 16)
          : null,
      absenceReason: status == AttendanceStatus.absent ? '体調不良' : null,
    ));
  }

  // ══════════════════════════════════════════════════════════════
  // 候補抽出条件
  // ══════════════════════════════════════════════════════════════

  group('候補抽出: 基本条件', () {
    test('当日の出席レコードがない・残あり・LINE連携済み → 候補になる', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('cand1', '候補 花子', lineUserId: lineId('b'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      final r = await svc.findCandidates(date: date, today: date);

      expect(r.linked.map((c) => c.customerId), ['cand1']);
      expect(r.notifiable.length, 1);
      expect(r.unlinked, isEmpty);
    });

    test('当日「在室」の児童は候補に含まれない', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('present1', '在室 次郎', lineUserId: lineId('c'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);
      await putRecord('present1', '在室 次郎', AttendanceStatus.present);

      final r = await svc.findCandidates(date: date, today: date);

      expect(r.linked.map((c) => c.customerId), isNot(contains('present1')));
      expect(r.unlinked.map((c) => c.customerId),
          isNot(contains('present1')));
      expect(r.totalCount, 0);
    });

    test('当日「退室済み」の児童も候補に含まれない', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('dep1', '退室 三郎', lineUserId: lineId('d'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);
      await putRecord('dep1', '退室 三郎', AttendanceStatus.departed);

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.totalCount, 0);
    });

    test('当日「予定」のみの児童は候補に含めない（その日来る予定があるため）',
        () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('sched1', '予定 四郎', lineUserId: lineId('e'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);
      await putRecord('sched1', '予定 四郎', AttendanceStatus.scheduled);

      final r = await svc.findCandidates(date: date, today: date);

      expect(r.linked.map((c) => c.customerId), isNot(contains('sched1')));
      expect(r.totalCount, 0);
    });

    test('欠席者本人は候補から除外される', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      final r = await svc.findCandidates(
        date: date,
        absentCustomerIds: ['absent1'],
        today: date,
      );

      expect(r.absentCustomerIds, contains('absent1'));
      expect(r.linked.map((c) => c.customerId), isNot(contains('absent1')));
      expect(r.totalCount, 0);
    });

    test('複数の欠席者がいても全員除外される', () async {
      await addCustomer('a1', '欠席A', lineUserId: lineId('a'));
      await addCustomer('a2', '欠席B', lineUserId: lineId('b'));
      await addCustomer('c1', '候補C', lineUserId: lineId('c'));
      await putRecord('a1', '欠席A', AttendanceStatus.absent);
      await putRecord('a2', '欠席B', AttendanceStatus.absent);

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.linked.map((c) => c.customerId), ['c1']);
    });

    test('退所済み（isActive=false）の児童は候補に含まれない', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      final left = await addCustomer('left1', '退所 五郎',
          lineUserId: lineId('f'));
      left.isActive = false;
      await CustomerService.instance.updateCustomer(left);
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.totalCount, 0);
    });
  });

  group('候補抽出: 支給量（Day 9 remainingProjected）', () {
    test('remainingProjected = 0 の児童は除外される', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      // 支給量 2 日・実績 2 日 → 残 0
      await addCustomer('full1', '満枠 六郎',
          lineUserId: lineId('g'), monthlyAvailableDays: 2);
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);
      await putRecord('full1', '満枠 六郎', AttendanceStatus.departed,
          on: DateTime(2026, 10, 1));
      // 当日はレコードなし。別日（9/30 ではなく 10/5）に実績をもう1日
      await putRecord('full1', '満枠 六郎', AttendanceStatus.departed,
          on: DateTime(2026, 10, 5));

      final r = await svc.findCandidates(date: date, today: date);

      expect(r.linked.map((c) => c.customerId), isNot(contains('full1')));
      expect(r.unlinked.map((c) => c.customerId), isNot(contains('full1')));
    });

    test('remainingProjected が負（超過見込み）の児童も除外される', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('over1', '超過 七郎',
          lineUserId: lineId('h'), monthlyAvailableDays: 1);
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);
      await putRecord('over1', '超過 七郎', AttendanceStatus.departed,
          on: DateTime(2026, 10, 1));
      await putRecord('over1', '超過 七郎', AttendanceStatus.departed,
          on: DateTime(2026, 10, 6));

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.totalCount, 0);
    });

    test('remainingProjected > 0 なら候補になり、残日数が結果に入る', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('ok1', '余裕 八郎',
          lineUserId: lineId('i'), monthlyAvailableDays: 10);
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);
      await putRecord('ok1', '余裕 八郎', AttendanceStatus.departed,
          on: DateTime(2026, 10, 1));

      final r = await svc.findCandidates(date: date, today: date);
      final c = r.linked.firstWhere((x) => x.customerId == 'ok1');
      expect(c.remainingProjected, greaterThan(0));
      expect(c.remainingProjected, 9); // 10 - 実績1
    });

    test('候補は見込み残が多い順に並ぶ', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('few', '少 一郎',
          lineUserId: lineId('b'), monthlyAvailableDays: 3);
      await addCustomer('many', '多 二郎',
          lineUserId: lineId('c'), monthlyAvailableDays: 20);
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.linked.first.customerId, 'many');
      expect(r.linked.last.customerId, 'few');
    });
  });

  group('候補抽出: LINE 連携状態の分離', () {
    test('lineUserId 未登録は「未連携」枠に分離される', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('linked1', '連携済 花子', lineUserId: lineId('b'));
      await addCustomer('nolink1', '未連携 桃子'); // lineUserId なし
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      final r = await svc.findCandidates(date: date, today: date);

      expect(r.linked.map((c) => c.customerId), ['linked1']);
      expect(r.unlinked.map((c) => c.customerId), ['nolink1']);
      expect(r.notifiable.map((c) => c.customerId), ['linked1']);
      // 未連携は送信対象外
      expect(r.unlinked.first.canNotify, isFalse);
      expect(r.unlinked.first.isLinked, isFalse);
    });

    test('lineUserId が空文字列でも「未連携」として扱う', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('empty1', '空 文子', lineUserId: '   ');
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.unlinked.map((c) => c.customerId), ['empty1']);
      expect(r.linked, isEmpty);
    });

    test('定期曜日ラベルが生成される', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('cand1', '候補 花子',
          lineUserId: lineId('b'), regularDays: [5, 1, 3]);
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.linked.first.regularDaysLabel, '月・水・金');
    });

    test('定期曜日なしは「定期なし」と表示される', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('cand1', '候補 花子',
          lineUserId: lineId('b'), regularDays: []);
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.linked.first.regularDaysLabel, '定期なし');
    });
  });

  // ══════════════════════════════════════════════════════════════
  // 二重送信ブロック（クライアント側）
  // ══════════════════════════════════════════════════════════════

  group('二重送信ブロック（クライアント側）', () {
    test('送信済み記録のある児童は alreadyNotified になり送信対象外', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('cand1', '候補 花子', lineUserId: lineId('b'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      await svc.saveLogForTest(NotificationLog(
        customerId: 'cand1',
        childName: '候補 花子',
        dateKey: NotificationLog.makeDateKey(date),
        status: NotificationStatus.sent,
      ));

      final r = await svc.findCandidates(date: date, today: date);

      expect(r.linked.length, 1);
      expect(r.linked.first.alreadyNotified, isTrue);
      expect(r.linked.first.canNotify, isFalse);
      expect(r.notifiable, isEmpty);
      expect(r.alreadyNotified.map((c) => c.customerId), ['cand1']);
    });

    test('送信失敗の記録も再送をブロックする（迷惑送信の予防）', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('cand1', '候補 花子', lineUserId: lineId('b'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      await svc.saveLogForTest(NotificationLog(
        customerId: 'cand1',
        childName: '候補 花子',
        dateKey: NotificationLog.makeDateKey(date),
        status: NotificationStatus.failed,
        httpStatus: 400,
        error: 'not a friend',
      ));

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.notifiable, isEmpty);
      expect(r.linked.first.alreadyNotified, isTrue);
    });

    test('ID不正の記録は再送をブロックしない（修正後に送れるべき）', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('cand1', '候補 花子', lineUserId: lineId('b'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      await svc.saveLogForTest(NotificationLog(
        customerId: 'cand1',
        childName: '候補 花子',
        dateKey: NotificationLog.makeDateKey(date),
        status: NotificationStatus.invalidLineUserId,
      ));

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.notifiable.map((c) => c.customerId), ['cand1']);
    });

    test('別日の送信記録は当日の送信をブロックしない', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('cand1', '候補 花子', lineUserId: lineId('b'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      await svc.saveLogForTest(NotificationLog(
        customerId: 'cand1',
        childName: '候補 花子',
        dateKey: NotificationLog.makeDateKey(DateTime(2026, 10, 1)),
        status: NotificationStatus.sent,
      ));

      final r = await svc.findCandidates(date: date, today: date);
      expect(r.notifiable.map((c) => c.customerId), ['cand1']);
    });

    test('sendNotices は送信済み宛先をリモート呼び出し前に duplicate で弾く',
        () async {
      await addCustomer('cand1', '候補 花子', lineUserId: lineId('b'));
      await svc.saveLogForTest(NotificationLog(
        customerId: 'cand1',
        childName: '候補 花子',
        dateKey: NotificationLog.makeDateKey(date),
        status: NotificationStatus.sent,
      ));

      final candidate = VacancyCandidate(
        customerId: 'cand1',
        childName: '候補 花子',
        lineUserId: lineId('b'),
        remainingProjected: 5,
        regularDays: const [1, 3, 5],
      );

      final result =
          await svc.sendNotices(date: date, candidates: [candidate]);

      // リモート無効でも fatalError にならない = 呼び出し前に弾けている
      expect(result.hasFatalError, isFalse);
      expect(result.duplicateCount, 1);
      expect(result.sentCount, 0);
    });

    test('sendNotices は未連携宛先を invalid として弾く', () async {
      const candidate = VacancyCandidate(
        customerId: 'nolink1',
        childName: '未連携 桃子',
        lineUserId: null,
        remainingProjected: 5,
        regularDays: [2, 4],
      );

      final result =
          await svc.sendNotices(date: date, candidates: [candidate]);

      expect(result.hasFatalError, isFalse);
      expect(result.invalidCount, 1);
      expect(result.sentCount, 0);
    });

    test('sendNotices は形式不正な lineUserId を invalid として弾く', () async {
      const candidate = VacancyCandidate(
        customerId: 'bad1',
        childName: '不正 ID 子',
        lineUserId: 'U123', // 32桁でない
        remainingProjected: 5,
        regularDays: [2],
      );

      final result =
          await svc.sendNotices(date: date, candidates: [candidate]);
      expect(result.invalidCount, 1);
      expect(result.sentCount, 0);
    });

    test('isAlreadyNotified が送信済み判定を返す', () async {
      expect(svc.isAlreadyNotified(date, 'cand1'), isFalse);
      await svc.saveLogForTest(NotificationLog(
        customerId: 'cand1',
        childName: '候補 花子',
        dateKey: NotificationLog.makeDateKey(date),
        status: NotificationStatus.sent,
      ));
      expect(svc.isAlreadyNotified(date, 'cand1'), isTrue);
      expect(svc.isAlreadyNotified(DateTime(2026, 10, 3), 'cand1'), isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // 文面生成・ユーティリティ
  // ══════════════════════════════════════════════════════════════

  group('通知文面', () {
    test('事業所名・日付・期限時刻が差し込まれる', () async {
      await SettingsService.instance.updateFacility('ココスタディ', '北海道帯広市');
      await SettingsService.instance.updateVacancyNotice(
        deadline: '13:00',
        template: AppSettings.defaultVacancyMessageTemplate,
      );

      final msg = svc.buildMessage(date);
      expect(msg, contains('ココスタディ'));
      expect(msg, contains('10/2'));
      expect(msg, contains('13:00'));
    });

    test('不正な期限時刻は既定値にフォールバックする', () async {
      await SettingsService.instance.updateVacancyNotice(
        deadline: '99:99',
        template: AppSettings.defaultVacancyMessageTemplate,
      );
      final s = SettingsService.instance.getSettings();
      expect(s.vacancyReplyDeadline, AppSettings.defaultVacancyReplyDeadline);
    });

    test('事業所設定の更新で通知設定が消えない（Day 10 の教訓）', () async {
      await SettingsService.instance.updateVacancyNotice(
        deadline: '15:30',
        template: 'カスタム文面 {facility} {date} {deadline}',
      );
      // 別設定を更新しても通知設定は保持されること
      await SettingsService.instance.updateFacility('新名称', '新住所');
      await SettingsService.instance
          .updateOperatingHours('08:00', '17:00', 12);

      final s = SettingsService.instance.getSettings();
      expect(s.vacancyReplyDeadline, '15:30');
      expect(s.vacancyMessageTemplate, contains('カスタム文面'));
    });
  });

  group('ユーティリティ', () {
    test('lineUserId の形式判定', () {
      expect(
          VacancyNotificationService.isValidLineUserId(lineId('a')), isTrue);
      expect(VacancyNotificationService.isValidLineUserId('U123'), isFalse);
      expect(VacancyNotificationService.isValidLineUserId(null), isFalse);
      expect(VacancyNotificationService.isValidLineUserId(''), isFalse);
      // 'U' で始まらない
      expect(
          VacancyNotificationService.isValidLineUserId('X${'a' * 32}'),
          isFalse);
    });

    test('連携コードは6桁で紛らわしい文字を含まない', () {
      for (int i = 0; i < 50; i++) {
        final code = VacancyNotificationService.generateCode();
        expect(code.length, 6);
        expect(RegExp(r'^[0-9A-Z]{6}$').hasMatch(code), isTrue);
        // 0/O/1/I/L は除外されている
        expect(code.contains('0'), isFalse);
        expect(code.contains('O'), isFalse);
        expect(code.contains('1'), isFalse);
        expect(code.contains('I'), isFalse);
        expect(code.contains('L'), isFalse);
      }
    });

    test('maskLineUserId は末尾4桁のみ表示する', () {
      final id = 'U${'a' * 28}3f2a';
      expect(VacancyNotificationService.maskLineUserId(id), 'U...3f2a');
      expect(VacancyNotificationService.maskLineUserId(null), '未連携');
    });

    test('送信記録は日付降順でグルーピングされる', () async {
      await svc.saveLogForTest(NotificationLog(
        customerId: 'c1',
        childName: 'A',
        dateKey: '2026-10-01',
        status: NotificationStatus.sent,
      ));
      await svc.saveLogForTest(NotificationLog(
        customerId: 'c2',
        childName: 'B',
        dateKey: '2026-10-03',
        status: NotificationStatus.sent,
      ));
      await svc.saveLogForTest(NotificationLog(
        customerId: 'c3',
        childName: 'C',
        dateKey: '2026-10-02',
        status: NotificationStatus.failed,
      ));

      final grouped = svc.getLogsGroupedByDate();
      expect(grouped.keys.toList(), ['2026-10-03', '2026-10-02', '2026-10-01']);
      expect(svc.getLogsByDate(DateTime(2026, 10, 2)).length, 1);
    });

    test('送信記録の削除ができる', () async {
      await svc.saveLogForTest(NotificationLog(
        customerId: 'c1',
        childName: 'A',
        dateKey: NotificationLog.makeDateKey(date),
        status: NotificationStatus.sent,
      ));
      expect(svc.getLog(date, 'c1'), isNotNull);
      await svc.deleteLog(date, 'c1');
      expect(svc.getLog(date, 'c1'), isNull);
    });

    test('NotificationLog.statusFromString が Functions の文字列を変換する', () {
      expect(NotificationLog.statusFromString('sent'),
          NotificationStatus.sent);
      expect(NotificationLog.statusFromString('failed'),
          NotificationStatus.failed);
      expect(NotificationLog.statusFromString('duplicate'),
          NotificationStatus.duplicate);
      expect(NotificationLog.statusFromString('invalid_line_user_id'),
          NotificationStatus.invalidLineUserId);
      // 未知の値は failed に倒す（成功と誤認しない）
      expect(NotificationLog.statusFromString('unknown'),
          NotificationStatus.failed);
      expect(NotificationLog.statusFromString(null),
          NotificationStatus.failed);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // 保護領域への非干渉
  // ══════════════════════════════════════════════════════════════

  group('既存機能への非干渉', () {
    test('候補抽出は出席レコードを一切変更しない', () async {
      await addCustomer('absent1', '欠席 太郎', lineUserId: lineId('a'));
      await addCustomer('cand1', '候補 花子', lineUserId: lineId('b'));
      await putRecord('absent1', '欠席 太郎', AttendanceStatus.absent);

      final before = AttendanceService.instance.getRecordsByDate(date);
      final beforeSnapshot = before
          .map((r) => '${r.customerId}:${r.status}:${r.absenceReason}')
          .toList();

      await svc.findCandidates(date: date, today: date);

      final after = AttendanceService.instance.getRecordsByDate(date);
      final afterSnapshot = after
          .map((r) => '${r.customerId}:${r.status}:${r.absenceReason}')
          .toList();

      expect(afterSnapshot, beforeSnapshot);
      expect(after.length, before.length);
    });

    test('候補抽出は Customer.currentMonthUsedDays を書き換えない', () async {
      final c = await addCustomer('cand1', '候補 花子',
          lineUserId: lineId('b'), monthlyAvailableDays: 20);
      c.currentMonthUsedDays = 99; // 意図的にズレた値
      await CustomerService.instance.updateCustomer(c);

      await svc.findCandidates(date: date, today: date);

      final after = CustomerService.instance.getCustomerById('cand1');
      // reconcileCache: false なので副作用なし
      expect(after!.currentMonthUsedDays, 99);
    });

    test('候補抽出は送迎座標フィールドに触れない', () async {
      final c = Customer(
        id: 'cand1',
        name: '候補 花子',
        nameKana: 'コウホ ハナコ',
        lineUserId: lineId('b'),
        transportLocations: ['帯広市西5条南21丁目'],
        transportLocationLats: [42.918],
        transportLocationLngs: [143.196],
        transportLocationStatus: [Customer.locManual],
      );
      await CustomerService.instance.addCustomer(c);

      await svc.findCandidates(date: date, today: date);

      final after = CustomerService.instance.getCustomerById('cand1')!;
      expect(after.transportCoord(0)?.lat, 42.918);
      expect(after.transportCoord(0)?.lng, 143.196);
      expect(after.transportStatus(0), Customer.locManual);
      expect(after.isTransportResolved(0), isTrue);
    });
  });

  _mainErrorMessages();
}

/// Day 11 追加: 送信失敗時のエラー文言が原因別に分かれているか
///
/// 一律「通信状況を確認して」だと、プラグイン未登録や未デプロイといった
/// 現場では解決できない原因まで「ネットワークのせい」と誤診されるため、
/// 原因ごとに次の行動が変わる文言になっていることを検証する。
void _mainErrorMessages() {
  group('localizeSendError（原因別の文言）', () {
    test('MissingPluginException は再読み込みを促し、通信のせいにしない', () {
      final msg = VacancyNotificationService.localizeSendError(
        MissingPluginException(
          'No implementation found for method FirebaseFunctions#call',
        ),
      );
      expect(msg, contains('再読み込み'));
      expect(msg, isNot(contains('ネットワークを確認')));
    });

    test('unauthenticated は再サインインを促す', () {
      final msg = VacancyNotificationService.localizeSendError(
        FirebaseFunctionsException(
          code: 'unauthenticated',
          message: 'unauthenticated',
        ),
      );
      expect(msg, contains('サインイン'));
    });

    test('not-found は未デプロイとして管理者連絡を促す', () {
      final msg = VacancyNotificationService.localizeSendError(
        FirebaseFunctionsException(code: 'not-found', message: 'not found'),
      );
      expect(msg, contains('未デプロイ'));
      expect(msg, contains('管理者'));
    });

    test('unavailable のみネットワーク確認を促す', () {
      final msg = VacancyNotificationService.localizeSendError(
        FirebaseFunctionsException(code: 'unavailable', message: 'unavailable'),
      );
      expect(msg, contains('ネットワークを確認'));
    });

    test('deadline-exceeded は履歴確認を促す（二重送信を防ぐ）', () {
      final msg = VacancyNotificationService.localizeSendError(
        FirebaseFunctionsException(
          code: 'deadline-exceeded',
          message: 'timeout',
        ),
      );
      expect(msg, contains('履歴'));
    });

    test('想定外の例外は通信のせいにしない', () {
      final msg = VacancyNotificationService.localizeSendError(
        StateError('boom'),
      );
      expect(msg, isNot(contains('ネットワーク')));
      expect(msg, contains('管理者'));
    });
  });
}
