import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/attendance_record.dart';
import '../models/customer.dart';
import '../models/notification_log.dart';
import '../models/transport_plan.dart';
import '../models/weekly_schedule.dart';
import '../services/weekly_schedule_service.dart';
import '../utils/week_util.dart';
import 'verify_config.dart';

/// 検証構成限定のダミーデータ投入（Hive 側）。
///
/// 【Firestore 移行中】顧客（段階3）と週間利用計画（段階4）は Firestore へ移した。
/// それらの投入は tool/verify/seed.mjs（[buildCustomer] / [buildDemoWeeks] と同じ規則・
/// 同じ ID）。ここはまだ Hive にある種類（出席・設定・送迎・通知履歴）だけを投入する。
///
/// 【なぜアプリ内で投入するか】
/// 顧客・出席・週間計画・設定・送迎計画・通知履歴は **ブラウザの IndexedDB（Hive）**
/// に保存され、Firestore には無い（firestore.rules 冒頭の方針）。そのため
/// Node スクリプトからは投入できず、画面が実際に読む Hive へ、検証構成の
/// アプリ自身が書き込む。Firestore 側（slots など）は tool/verify/seed_firestore.mjs。
///
/// 【安全】
///  - `VerifyConfig.enabled` のときだけ呼ばれる（通常ビルドでは到達不能）。
///  - 書き込み先はブラウザのローカル IndexedDB のみ。ネットワークへは出ない。
///  - 実在の個人情報・LINE userId・秘密情報は使わない（全て架空・規則的な値）。
///
/// 【切替】URL クエリ `?verify_data=` :
///  - なし    : 未投入なら normal を投入。投入済みなら何もしない（編集内容を保持）
///  - normal  : 全消去して通常データを再投入（顧客 60 件超）
///  - empty   : 全消去して空にする（空状態の確認用）
class VerifySeed {
  VerifySeed._();

  static const String stateKey = 'verify_seed_state';

  /// ダミー顧客の件数（>50）
  static const int customerCount = 60;

  /// 検証用の ID 接頭辞（スクリプト側と一致）
  static const String idPrefix = 'dummy-c';

  static String customerId(int n) => '$idPrefix${n.toString().padLeft(3, '0')}';

  /// 当日に欠席にする顧客番号（Firestore 側 slots の sourceAbsent と対応）
  static const List<int> todayAbsentNumbers = [3, 7];

  static Future<void> runFromUrl() async {
    assert(VerifyConfig.enabled, 'VerifySeed は検証構成専用です');
    if (!VerifyConfig.enabled) return;
    final mode = Uri.base.queryParameters['verify_data'];
    final prefs = await SharedPreferences.getInstance();
    final state = prefs.getString(stateKey);
    switch (mode) {
      case 'empty':
        await clearAll();
        await prefs.setString(stateKey, 'empty');
        debugPrint('[VerifySeed] cleared (empty)');
      case 'normal':
        await clearAll();
        await seedNormal(DateTime.now());
        await prefs.setString(stateKey, 'normal');
        debugPrint('[VerifySeed] seeded normal');
      default:
        if (state == null) {
          await seedNormal(DateTime.now());
          await prefs.setString(stateKey, 'normal');
          debugPrint('[VerifySeed] first run: seeded normal');
        } else {
          debugPrint('[VerifySeed] keep existing data (state=$state)');
        }
    }
  }

  /// 検証用 Hive ボックスを全消去（設定は既定値に戻る）
  static Future<void> clearAll() async {
    await Hive.box<AttendanceRecord>('attendance_records').clear();
    await Hive.box<TransportVehicleRoute>('transport_plans').clear();
    await Hive.box<NotificationLog>('notification_logs').clear();
    await Hive.box<AppSettings>('app_settings').put('settings', AppSettings());
  }

  // ── 架空データ ──────────────────────────────────────────────

  static const List<String> _surnames = [
    '検証', 'テスト', '見本', '試験', '仮名', '例示',
  ];
  static const List<(String, String)> _given = [
    ('一郎', 'イチロウ'), ('花子', 'ハナコ'), ('次郎', 'ジロウ'), ('桃子', 'モモコ'),
    ('三郎', 'サブロウ'), ('梅子', 'ウメコ'), ('四郎', 'シロウ'), ('菊子', 'キクコ'),
    ('五郎', 'ゴロウ'), ('藤子', 'フジコ'),
  ];
  static const List<String> _surnameKana = [
    'ケンショウ', 'テスト', 'ミホン', 'シケン', 'カメイ', 'レイジ',
  ];

  /// 住所（架空・帯広市周辺の地名のみ。番地は実在しない値）
  static const List<String> _areas = [
    '帯広市西2条南9丁目（検証用）', '帯広市東3条南5丁目（検証用）',
    '帯広市稲田町西2線（検証用）', '帯広市大空町3丁目（検証用）',
    '帯広市西19条南4丁目（検証用）', '音更町木野大通西（検証用）',
    '帯広市柏林台西町（検証用）', '帯広市自由が丘（検証用）',
  ];

  static Customer buildCustomer(int n, DateTime now) {
    final sur = _surnames[n % _surnames.length];
    final g = _given[(n ~/ 2) % _given.length];
    var name = '$sur ${g.$1}';
    var kana = '${_surnameKana[n % _surnameKana.length]} ${g.$2}';
    // 可読性確認用に長い氏名・数字を混ぜる
    if (n % 15 == 0) {
      name = '検証用ダミーの非常に長い氏名 ${g.$1}ジョセフ';
      kana = 'ケンショウヨウダミー ${g.$2}';
    }
    const dayPatterns = <List<int>>[
      [1, 3, 5],
      [2, 4],
      [1, 2, 3, 4, 5],
      [6],
      [1, 5, 6],
      [3, 4, 5],
    ];
    final days = dayPatterns[n % dayPatterns.length];
    final locCount = n % 4 == 0 ? 2 : 1;
    final area = _areas[n % _areas.length];
    final locations = [
      '$area $n番',
      if (locCount == 2) '帯広市（検証用・祖父母宅）${n + 100}番',
    ];
    // 座標: 解決済み / 手動 / 未解決 / 失敗 を混ぜる（位置確認画面の確認用）
    final lats = <double?>[];
    final lngs = <double?>[];
    final status = <String>[];
    for (var i = 0; i < locations.length; i++) {
      final k = (n + i) % 5;
      if (k == 0 || k == 1) {
        lats.add(42.92 + (n % 9) * 0.004 + i * 0.002);
        lngs.add(143.19 + (n % 7) * 0.005 + i * 0.002);
        status.add(Customer.locResolved);
      } else if (k == 2) {
        lats.add(42.91 + (n % 6) * 0.005);
        lngs.add(143.20 + (n % 5) * 0.004);
        status.add(Customer.locManual);
      } else if (k == 3) {
        lats.add(null);
        lngs.add(null);
        status.add(Customer.locFailed);
      } else {
        lats.add(null);
        lngs.add(null);
        status.add(Customer.locUnresolved);
      }
    }
    // 月間支給量: 一部は少なめ（残日数・超過表示の確認用）
    final available = n % 9 == 0 ? 8 : (n % 11 == 0 ? 12 : 23);
    // 受給者証期限: 一部は 30 日以内（ホームの期限警告の確認用）
    final expiry = n % 10 == 4
        ? now.add(Duration(days: 5 + n % 20))
        : now.add(Duration(days: 200 + n));
    return Customer(
      id: customerId(n),
      name: name,
      nameKana: kana,
      birthday: DateTime(2012 + n % 6, 1 + n % 12, 1 + n % 27),
      gender: n.isEven ? '男児' : '女児',
      phone: null,
      // 架空の規則的な LINE userId（U + 32桁16進。実在しない）。
      // 連携済みの見た目確認用。検証構成では LINE 送信は遮断される。
      lineUserId: n % 3 == 0
          ? 'U${'0' * 24}${n.toRadixString(16).padLeft(8, '0')}'
          : null,
      guardianName: '保護者$n（ダミー）',
      guardianPhone: '090-0000-${n.toString().padLeft(4, '0')}',
      recipientCertNumber: (1000000000 + n).toString(),
      recipientCertExpiry: expiry,
      monthlyAvailableDays: available,
      currentMonthUsedDays: 0,
      regularDays: days,
      transportLocations: locations,
      notes: n % 7 == 0 ? 'ダミー備考: アレルギー確認の表示テスト用' : null,
      createdAt: now.subtract(Duration(days: 400 - n)),
      updatedAt: now,
      transportLocationLats: lats,
      transportLocationLngs: lngs,
      transportLocationStatus: status,
    );
  }

  /// 先週・今週・来週の週間利用計画（tool/verify/dummy_schedule.mjs と同じ規則）。
  ///
  /// 定期利用曜日から作り、見た目確認用の時刻を入れ、今日のスロットに最低 14 件
  /// （日曜など定期利用が無い日も画面を埋める）を「追加」で足し、最後の 1 件を
  /// 「キャンセル」にする。
  static List<WeeklySchedule> buildDemoWeeks(
    DateTime today,
    List<Customer> active,
  ) {
    final monday = WeekUtil.weekStartFromDate(today);
    final weeks = <WeeklySchedule>[];
    for (final off in [-7, 0, 7]) {
      final ws = DateTime(monday.year, monday.month, monday.day + off);
      final sched = WeeklyScheduleService.buildFromRegularDays(
          ws, WeekUtil.weekKeyFromDate(ws), active);
      // 見た目確認用の時刻・追加・キャンセルを混ぜる
      for (final slot in sched.dailySlots) {
        var i = 0;
        for (final e in slot.entries) {
          e.plannedStartTime ??= i.isEven ? '10:00' : '13:30';
          e.plannedEndTime ??= i.isEven ? '16:00' : '17:30';
          i++;
        }
      }
      weeks.add(sched);
    }
    final slot = weeks[1].slotForDate(today)!;
    final have = slot.entries.map((e) => e.customerId).toSet();
    final mustHave = <String>{
      for (final n in todayAbsentNumbers) customerId(n),
    };
    var added = 0;
    for (final c in active) {
      if (slot.entries.length >= 14 && mustHave.every(have.contains)) break;
      if (have.contains(c.id)) continue;
      if (slot.entries.length >= 14 && !mustHave.contains(c.id)) continue;
      slot.entries.add(ScheduleEntry(
        customerId: c.id,
        customerName: c.name,
        status: ScheduleStatus.additional,
        plannedStartTime: added.isEven ? '10:00' : '13:30',
        plannedEndTime: added.isEven ? '16:00' : '17:30',
      ));
      have.add(c.id);
      added++;
    }
    if (slot.entries.length > 3) {
      slot.entries[slot.entries.length - 1].status = ScheduleStatus.cancelled;
    }
    return weeks;
  }

  static Future<void> seedNormal(DateTime now) async {
    final today = DateTime(now.year, now.month, now.day);

    // ── 顧客 ──
    // 顧客は Firestore（tool/verify/seed.mjs が同じ ID・氏名で投入する）。
    // ここでは出席・週間計画など Hive 側のデータを作るために同じ一覧を組み立てるだけ。
    final customers = <Customer>[
      for (var n = 1; n <= customerCount; n++) buildCustomer(n, now),
    ];
    // 退所済み（一覧の「在籍中のみ」確認用）
    customers.add(buildCustomer(customerCount + 1, now)..isActive = false);

    // ── 設定（架空の事業所）──
    await Hive.box<AppSettings>('app_settings').put(
      'settings',
      AppSettings(
        facilityName: '検証用デイサービス（ダミー）',
        facilityAddress: '北海道帯広市（検証用ダミー住所）',
        facilityLat: 42.9236,
        facilityLng: 143.1946,
        vehicleCount: 3,
        vehicleNames: ['車両A', '車両B', '車両C'],
        vehicleCapacities: [6, 6, 4],
        maxStudentsPerDay: 20,
      ),
    );

    // ── 週間利用計画（先週・今週・来週）──
    // 週間利用計画は Firestore（段階4〜）。tool/verify/seed.mjs が同じ規則
    // （[buildDemoWeeks]）でエミュレータへ投入する。ここでは出席・送迎を
    // 作るために同じ週を組み立てるだけ。
    final active = customers.where((c) => c.isActive).toList();
    final weeks = buildDemoWeeks(today, active);
    final slot = weeks[1].slotForDate(today)!;

    // ── 出席: 直近 5 日の実績 + 今日の混在 ──
    final attBox = Hive.box<AttendanceRecord>('attendance_records');
    for (var back = 1; back <= 5; back++) {
      final d = today.subtract(Duration(days: back));
      final key = AttendanceRecord.makeDateKey(d);
      var i = 0;
      for (final c in active) {
        if (!c.regularDays.contains(d.weekday)) continue;
        final absent = i % 9 == 4;
        final r = AttendanceRecord(
          customerId: c.id,
          customerName: c.name,
          dateKey: key,
          status: absent ? AttendanceStatus.absent : AttendanceStatus.departed,
          plannedStartTime: DateTime(d.year, d.month, d.day, 10),
          plannedEndTime: DateTime(d.year, d.month, d.day, 16),
          checkInTime: absent ? null : DateTime(d.year, d.month, d.day, 10, i % 20),
          checkOutTime: absent ? null : DateTime(d.year, d.month, d.day, 16, i % 25),
          absenceReason: absent ? '体調不良' : null,
        );
        await attBox.put(r.boxKey, r);
        i++;
      }
    }
    // 今日: 予定 / 在室 / 退室済 / 欠席 を混在
    final todayKey = AttendanceRecord.makeDateKey(today);
    var k = 0;
    for (final e in slot.entries) {
      if (e.status == ScheduleStatus.cancelled) continue;
      final n = int.tryParse(e.customerId.substring(idPrefix.length)) ?? 0;
      AttendanceStatus st;
      if (todayAbsentNumbers.contains(n)) {
        st = AttendanceStatus.absent;
      } else {
        st = [
          AttendanceStatus.scheduled,
          AttendanceStatus.present,
          AttendanceStatus.departed,
          AttendanceStatus.scheduled,
        ][k % 4];
      }
      k++;
      final inT = DateTime(today.year, today.month, today.day, 10, k % 30);
      final r = AttendanceRecord(
        customerId: e.customerId,
        customerName: e.customerName,
        dateKey: todayKey,
        status: st,
        plannedStartTime: DateTime(today.year, today.month, today.day, 10),
        plannedEndTime: DateTime(today.year, today.month, today.day, 16),
        checkInTime: (st == AttendanceStatus.present ||
                st == AttendanceStatus.departed)
            ? inT
            : null,
        checkOutTime: st == AttendanceStatus.departed
            ? DateTime(today.year, today.month, today.day, 15, 30)
            : null,
        absenceReason: st == AttendanceStatus.absent ? '家庭の都合' : null,
      );
      await attBox.put(r.boxKey, r);
    }

    // ── 送迎計画（今日: お迎え 3 台 / お送り 2 台）──
    final tpBox = Hive.box<TransportVehicleRoute>('transport_plans');
    final todayKey2 = TransportPlanKey.dateKey(today);
    final riders = slot.entries
        .where((e) => e.status != ScheduleStatus.cancelled)
        .map((e) => customers.firstWhere((c) => c.id == e.customerId))
        .toList();
    for (final type in TransportType.values) {
      final vehicles = type == TransportType.pickup ? 3 : 2;
      for (var v = 0; v < vehicles; v++) {
        final mine = [
          for (var i = v; i < riders.length; i += vehicles) riders[i],
        ].take(v == 2 ? 4 : 6).toList();
        final route = TransportVehicleRoute(
          id: 'dummy-route-${type.name}-$v',
          vehicleName: ['車両A', '車両B', '車両C'][v],
          vehicleIndex: v,
          transportType: type,
          dateKey: todayKey2,
          capacity: v == 2 ? 4 : 6,
          stops: [
            for (var i = 0; i < mine.length; i++)
              TransportStop(
                customerId: mine[i].id,
                customerName: mine[i].name,
                address: mine[i].transportLocations.first,
                lat: mine[i].transportLocationLats.first,
                lng: mine[i].transportLocationLngs.first,
                orderIndex: i,
                scheduledTime: _hhmm(9 + i ~/ 2, (i % 2) * 30 + 5 + v),
                distanceFromPrevMeters: 800 + i * 350,
                durationFromPrevSeconds: 240 + i * 60,
              ),
          ],
          totalDistanceMeters: 4200 + v * 900,
          totalDurationSeconds: 1500 + v * 300,
        );
        final key = '${todayKey2}_${v}_${type.name}';
        await tpBox.put(key, route);
      }
    }

    // ── 通知履歴（過去 6 日・成功/失敗/重複/ID不正）──
    final logBox = Hive.box<NotificationLog>('notification_logs');
    const statuses = [
      NotificationStatus.sent,
      NotificationStatus.sent,
      NotificationStatus.failed,
      NotificationStatus.duplicate,
      NotificationStatus.invalidLineUserId,
    ];
    for (var back = 1; back <= 6; back++) {
      final d = today.subtract(Duration(days: back));
      final dk = NotificationLog.makeDateKey(d);
      for (var j = 0; j < 4; j++) {
        final n = back * 5 + j + 1;
        final st = statuses[(back + j) % statuses.length];
        final log = NotificationLog(
          id: 'dummy-log-$back-$j',
          customerId: customerId(n),
          childName: buildCustomer(n, now).name,
          dateKey: dk,
          status: st,
          sentAt: DateTime(d.year, d.month, d.day, 9, 10 + j),
          httpStatus: st == NotificationStatus.failed ? 500 : 200,
          error: st == NotificationStatus.failed ? '検証用ダミーエラー' : null,
          lineUserIdSuffix: '0000${n.toString().padLeft(4, '0')}',
          message: '【ダミー】空き枠のお知らせ（検証用・実送信なし）',
        );
        await logBox.put(log.boxKey, log);
      }
    }
  }
}

String _hhmm(int h, int m) =>
    '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

/// transport_plans のキー用 dateKey（NotificationLog と同じ書式）
class TransportPlanKey {
  TransportPlanKey._();
  static String dateKey(DateTime d) => NotificationLog.makeDateKey(d);
}
