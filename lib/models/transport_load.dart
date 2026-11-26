import 'transport_plan.dart';

/// 1 台の車の乗車状況（表示と印刷のための計算。割り当ての計算は変えない）
class RouteLoad {
  const RouteLoad({
    required this.riding,
    required this.absent,
    required this.capacity,
  });

  /// [absentIds] の児童（その日お休み）は乗る人数に入れない
  factory RouteLoad.of(TransportVehicleRoute route,
      {Set<String> absentIds = const {}}) {
    final absent =
        route.stops.where((s) => absentIds.contains(s.customerId)).length;
    return RouteLoad(
      riding: route.stops.length - absent,
      absent: absent,
      capacity: route.capacity,
    );
  }

  /// 乗る人数（お休みを除く）
  final int riding;

  /// ルートに入っているが、お休みの児童の数
  final int absent;

  final int capacity;

  /// 定員を超えている人数（超えていなければ 0）
  int get over => riding > capacity ? riding - capacity : 0;

  /// ちょうど定員
  bool get full => riding == capacity && capacity > 0;

  /// 「13/6名」
  String get countLabel => '$riding/$capacity名';

  /// 「定員超過 7名」（超えていなければ null）
  String? get overLabel => over > 0 ? '定員超過 $over名' : null;
}

/// 定員を超えている・車が足りないときの注意（画面の上と印刷の上に出す）
class TransportShortage {
  TransportShortage._();

  static String _typeLabel(TransportType t) =>
      t == TransportType.pickup ? 'お迎え' : 'お送り';

  /// お迎え・お送りごとに 1 行。問題がなければ空
  ///
  /// - 全部の車の定員を足しても乗りきれない: 「車が足りません。乗れない人数 N名」
  /// - 足りてはいるが、定員を超えた車がある: 「定員を超えている車があります（N名）」
  static List<String> notes(List<TransportVehicleRoute> routes,
      {Set<String> absentIds = const {}}) {
    final out = <String>[];
    for (final t in TransportType.values) {
      final loads = [
        for (final r in routes)
          if (r.transportType == t) RouteLoad.of(r, absentIds: absentIds)
      ];
      final riding = loads.fold(0, (s, l) => s + l.riding);
      final seats = loads.fold(0, (s, l) => s + l.capacity);
      final over = loads.fold(0, (s, l) => s + l.over);
      if (riding > seats) {
        out.add('${_typeLabel(t)}：車が足りません。乗れない人数 ${riding - seats}名');
      } else if (over > 0) {
        out.add('${_typeLabel(t)}：定員を超えている車があります（$over名）');
      }
    }
    return out;
  }
}
