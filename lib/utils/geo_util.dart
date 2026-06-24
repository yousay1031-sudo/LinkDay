import 'dart:math' as math;

/// 地理計算ユーティリティ
///
/// Directions API が失敗した場合の直線距離フォールバック等に使用する。
/// Haversine 公式: 球面上の2点間の最短距離（大円距離）を計算する。
///
/// 精度: 地球を完全な球体と仮定するため、実測値と最大 0.3% 程度の誤差がある。
/// 用途: Directions API フォールバック時の概算距離・時間計算
class GeoUtil {
  GeoUtil._();

  /// 地球の平均半径 [m]
  static const double _earthRadiusMeters = 6371000.0;

  /// Haversine 公式で2点間の直線距離を求める [m]
  ///
  /// [lat1] 始点の緯度（度）
  /// [lng1] 始点の経度（度）
  /// [lat2] 終点の緯度（度）
  /// [lng2] 終点の経度（度）
  ///
  /// 戻り値: 2点間の直線距離 [m]（球面距離）
  static double haversineMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return _earthRadiusMeters * c;
  }

  /// 直線距離から走行時間を概算する [秒]
  ///
  /// [distanceMeters] 直線距離 [m]
  /// [speedKmh] 平均速度 [km/h]（デフォルト 30 km/h）
  ///
  /// 概算の考え方:
  ///   - 実際の道路距離は直線距離の 1.3〜1.5 倍程度（迂回係数）
  ///   - 送迎は市街地走行が主体のため 30 km/h を基準に設定
  ///   - 信号待ちや右左折を含む実態に近い係数として 1.4 を乗じる
  ///
  /// 戻り値: 概算走行時間 [秒]
  static int estimateDurationSeconds(
    double distanceMeters, {
    double speedKmh = 30.0,
  }) {
    if (distanceMeters <= 0 || speedKmh <= 0) return 0;

    // 道路迂回係数（直線距離 → 道路距離の補正）
    const double detourFactor = 1.4;
    final roadDistanceMeters = distanceMeters * detourFactor;

    // 速度をm/sに変換: v [m/s] = speedKmh * 1000 / 3600
    final speedMs = speedKmh * 1000.0 / 3600.0;

    return (roadDistanceMeters / speedMs).round();
  }

  /// 停留所リストを事業所起点としてラウンドトリップ計算し、
  /// 各 leg の直線距離 [m] と概算時間 [s] を返す
  ///
  /// legs 構成（transport_plan_service と同じ並び）:
  ///   legs[0]:   事業所 → stops[0]
  ///   legs[i]:   stops[i-1] → stops[i]
  ///   legs[n]:   stops[n-1] → 事業所
  ///
  /// 戻り値: ({distances: List<int>, durations: List<int>})
  ///   distances[i]: legs[i] の直線距離 [m]
  ///   durations[i]: legs[i] の概算時間 [s]
  static ({List<int> distances, List<int> durations}) roundTripFallback({
    required double facilityLat,
    required double facilityLng,
    required List<({double lat, double lng})> stops,
    double speedKmh = 30.0,
  }) {
    if (stops.isEmpty) {
      return (distances: [], durations: []);
    }

    final distances = <int>[];
    final durations = <int>[];

    // legs[0]: 事業所 → stops[0]
    double prevLat = facilityLat;
    double prevLng = facilityLng;

    for (final stop in stops) {
      final dist = haversineMeters(prevLat, prevLng, stop.lat, stop.lng);
      final dur = estimateDurationSeconds(dist, speedKmh: speedKmh);
      distances.add(dist.round());
      durations.add(dur);
      prevLat = stop.lat;
      prevLng = stop.lng;
    }

    // legs[n]: stops[n-1] → 事業所（帰路）
    final returnDist = haversineMeters(prevLat, prevLng, facilityLat, facilityLng);
    final returnDur = estimateDurationSeconds(returnDist, speedKmh: speedKmh);
    distances.add(returnDist.round());
    durations.add(returnDur);

    return (distances: distances, durations: durations);
  }

  // ── 内部ヘルパー ──────────────────────────────────────────────

  static double _toRad(double degree) => degree * math.pi / 180.0;
}
