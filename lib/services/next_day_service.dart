import '../models/attendance_record.dart';
import '../models/customer.dart';
import '../models/transport_plan.dart';
import '../models/weekly_schedule.dart';
import '../utils/week_util.dart';
import 'customer_service.dart';
import 'weekly_schedule_service.dart';

/// 翌日予約選択の人数（利用する・お休み・定員・空き／超過）
class NextDayCounts {
  final int using;
  final int absent;
  final int capacity;

  const NextDayCounts(
      {required this.using, required this.absent, required this.capacity});

  factory NextDayCounts.of(Iterable<ScheduleEntry> entries, int capacity) {
    var u = 0, a = 0;
    for (final e in entries) {
      if (e.status == ScheduleStatus.cancelled) {
        a++;
      } else {
        u++;
      }
    }
    return NextDayCounts(using: u, absent: a, capacity: capacity);
  }

  /// 出席の記録から数える（今日と過ぎた日で、出席の記録があるとき）。
  /// 出席管理の人数の帯と同じ数え方: 利用する = 予定 + 在室中 + 退室済、お休み = 欠席
  factory NextDayCounts.ofAttendance(
      Iterable<AttendanceRecord> records, int capacity) {
    var u = 0, a = 0;
    for (final r in records) {
      if (r.status == AttendanceStatus.absent) {
        a++;
      } else {
        u++;
      }
    }
    return NextDayCounts(using: u, absent: a, capacity: capacity);
  }

  /// 空き（超えていれば 0）
  int get free => using >= capacity ? 0 : capacity - using;

  /// 定員を超えている人数（超えていなければ 0）
  int get over => using > capacity ? using - capacity : 0;
}

/// 翌日予約選択の 1 行（予定と、出席管理で欠席になっているかどうか）
class NextDayRow {
  final ScheduleEntry entry;

  /// 出席管理で欠席（週間利用計画はそのまま。表示はお休みと同じ扱い）
  final bool attendanceAbsent;

  const NextDayRow(this.entry, {this.attendanceAbsent = false});
}

/// 今日と過ぎた日は、出席の記録があれば出席の記録から一覧と人数を作る
/// （出席管理と数を揃える。週間利用計画は書き換えない）
class NextDayAttendanceView {
  NextDayAttendanceView._();

  /// 出席の記録から一覧を作る日か（明日以降は今までどおり週間利用計画から）
  static bool applies(
          DateTime date, DateTime today, Iterable<AttendanceRecord> records) =>
      !DateTime(date.year, date.month, date.day)
          .isAfter(DateTime(today.year, today.month, today.day)) &&
      records.isNotEmpty;

  /// 出席の記録 1 件につき 1 行。予定（時間・通常／追加・送迎の場所）は週間利用計画の
  /// 行があればそれを使い、無ければ出席の記録の予定時刻から作る。
  /// 出席管理で欠席の児童はお休みと同じ扱いで出し、印を付ける。
  /// 週間利用計画にだけある児童（出席の記録が無い）は出さない（出席管理と同じ）。
  static List<NextDayRow> rows(
      Iterable<AttendanceRecord> records, Iterable<ScheduleEntry> planEntries) {
    final plan = {for (final e in planEntries) e.customerId: e};
    String? hm(DateTime? t) => t == null
        ? null
        : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return [
      for (final r in records)
        () {
          final absent = r.status == AttendanceStatus.absent;
          final p = plan[r.customerId];
          final base = p ??
              ScheduleEntry(
                customerId: r.customerId,
                customerName: r.customerName,
                plannedStartTime: hm(r.plannedStartTime),
                plannedEndTime: hm(r.plannedEndTime),
              );
          final ScheduleStatus status;
          if (absent) {
            status = ScheduleStatus.cancelled;
          } else if (base.status == ScheduleStatus.cancelled) {
            // 計画ではお休みでも、出席の記録では利用している
            status = ScheduleStatus.planned;
          } else {
            status = base.status;
          }
          return NextDayRow(base.copyWith(status: status),
              attendanceAbsent: absent);
        }(),
    ];
  }
}

/// 翌日予約選択の 1 行の送迎の表示（表示だけ。変更は顧客管理と送迎計画で行う）
class NextDayTransport {
  NextDayTransport._();

  /// 「送迎なし」／「送迎：場所」。場所は予定の送迎場所の番号の場所（無ければ 1 つ目）
  static String placeText(Customer? c, ScheduleEntry e) {
    final locs = c?.transportLocations ?? const <String>[];
    if (locs.isEmpty) return '送迎なし';
    final i = e.transportLocationIndex;
    final idx = (i == null || i < 0 || i >= locs.length) ? 0 : i;
    return '送迎：${locs[idx]}';
  }

  /// その日の送迎ルートでの車両（「お迎え 車両A・お送り 車両B」。ルートに無ければ null）
  static String? routeText(
      String customerId, Iterable<TransportVehicleRoute> routes) {
    final parts = routeParts(customerId, routes);
    return parts.isEmpty ? null : parts.join('・');
  }

  /// 行きと帰りの車を別々に（[「お迎え 車両A」, 「お送り 車両B」]。ルートに無ければ空）。
  /// 画面では、幅が足りなければ帰りを次の行に送り、どちらも切らずに出す
  static List<String> routeParts(
      String customerId, Iterable<TransportVehicleRoute> routes) {
    String? pick, drop;
    for (final r in routes) {
      if (!r.stops.any((s) => s.customerId == customerId)) continue;
      if (r.transportType == TransportType.pickup) {
        pick ??= r.vehicleName;
      } else {
        drop ??= r.vehicleName;
      }
    }
    return [
      if (pick != null) 'お迎え $pick',
      if (drop != null) 'お送り $drop',
    ];
  }
}

/// 翌日予約選択の対象の日を決める（承認済みの判断点1 A）。
class NextDayService {
  NextDayService._();

  /// 何日先まで探すか
  static const int maxLookAheadDays = 7;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 開く日: 明日から [maxLookAheadDays] 日先までで、予定（お休みを含む）が 1 件以上ある
  /// 最初の日。見つからなければ明日。
  ///
  /// [createWeeks] が true（画面）なら、週間利用計画がまだ無い週は週間利用計画と同じ処理で
  /// 作ってから見る（通信できなければ [WeekUnavailableException]）。false（ホームの印）なら
  /// 作らずに、利用曜日から作られるはずの予定で判断する（ホームを開いただけで書き込まない）。
  static Future<DateTime> findTargetDate(DateTime today,
      {bool createWeeks = true}) async {
    final t = _day(today);
    for (var i = 1; i <= maxLookAheadDays; i++) {
      final d = DateTime(t.year, t.month, t.day + i);
      if (await hasAnyEntry(d, createWeeks: createWeeks)) return d;
    }
    return DateTime(t.year, t.month, t.day + 1);
  }

  /// [date] に予定（お休みを含む）が 1 件以上あるか
  static Future<bool> hasAnyEntry(DateTime date,
      {required bool createWeeks}) async {
    final w = WeeklyScheduleService.instance;
    await w.ensureRange(date, date);
    if (!w.hasWeekFor(date)) {
      final customers = CustomerService.instance.getAllCustomers();
      if (!createWeeks) {
        return customers
            .any((c) => c.isActive && c.regularDays.contains(date.weekday));
      }
      await w.getOrCreateSchedule(WeekUtil.weekStartFromDate(date), customers);
    }
    return w.getAllEntriesForDate(date).isNotEmpty;
  }
}
