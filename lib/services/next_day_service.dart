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

  /// 空き（超えていれば 0）
  int get free => using >= capacity ? 0 : capacity - using;

  /// 定員を超えている人数（超えていなければ 0）
  int get over => using > capacity ? using - capacity : 0;
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
