import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/customer.dart';
import '../models/transport_plan.dart';
import '../utils/geo_util.dart';
import 'google_maps_service.dart';
import 'maps_js_service.dart';
import 'settings_service.dart';

const String _kBoxName = 'transport_plans';

/// 送迎計画サービス
/// Hive box: 'transport_plans'
/// キー: "${dateKey}_${vehicleIndex}_${type}" 例: "2026-06-16_0_pickup"
class TransportPlanService {
  TransportPlanService._();
  static final TransportPlanService instance = TransportPlanService._();

  late Box<TransportVehicleRoute> _box;

  // ── 初期化 ──────────────────────────────────────────────────

  Future<void> init() async {
    _box = await Hive.openBox<TransportVehicleRoute>(_kBoxName);
    debugPrint(
        '[TransportPlanService] initialized. routes=${_box.length}');
  }

  // ── 基本 CRUD ────────────────────────────────────────────────

  String _makeKey(String dateKey, int vehicleIndex, TransportType type) {
    final typeStr = type == TransportType.pickup ? 'pickup' : 'dropoff';
    return '${dateKey}_${vehicleIndex}_$typeStr';
  }

  /// 指定日の全ルートを取得
  List<TransportVehicleRoute> getRoutesByDate(String dateKey) {
    return _box.values
        .where((r) => r.dateKey == dateKey)
        .toList()
      ..sort((a, b) {
        final typeComp = a.transportType.index.compareTo(b.transportType.index);
        if (typeComp != 0) return typeComp;
        return a.vehicleIndex.compareTo(b.vehicleIndex);
      });
  }

  /// お迎えルート一覧
  List<TransportVehicleRoute> getPickupRoutes(String dateKey) =>
      getRoutesByDate(dateKey)
          .where((r) => r.transportType == TransportType.pickup)
          .toList();

  /// お送りルート一覧
  List<TransportVehicleRoute> getDropoffRoutes(String dateKey) =>
      getRoutesByDate(dateKey)
          .where((r) => r.transportType == TransportType.dropoff)
          .toList();

  /// ルートを保存
  Future<void> saveRoute(TransportVehicleRoute route) async {
    final key = _makeKey(route.dateKey, route.vehicleIndex, route.transportType);
    await _box.put(key, route);
    debugPrint('[TransportPlanService] saved: $key');
  }

  /// ルートを削除
  Future<void> deleteRoute(
      String dateKey, int vehicleIndex, TransportType type) async {
    final key = _makeKey(dateKey, vehicleIndex, type);
    await _box.delete(key);
  }

  /// 指定日のルートを全削除
  Future<void> clearDate(String dateKey) async {
    final keys = _box.keys
        .where((k) => k.toString().startsWith(dateKey))
        .toList();
    for (final key in keys) {
      await _box.delete(key);
    }
  }

  // ── AI グループ分け ──────────────────────────────────────────

  /// 利用者を車両に自動グループ分けする
  ///
  /// アルゴリズム:
  /// 1. 利用者の住所を Geocoding して LatLng を取得
  /// 2. 事業所を中心に、k-means 的クラスタリング（Haversine 距離）
  /// 3. 定員超過の場合は近隣クラスタに移動
  ///
  /// APIキーがない場合 → 均等分割（フォールバック）
  Future<List<TransportVehicleRoute>> autoGroupCustomers({
    required String dateKey,
    required List<Customer> customers,
    required TransportType type,
    String? apiKey,
  }) async {
    final settings = SettingsService.instance.getSettings();
    final vehicleCount = settings.vehicleCount;
    final vehicleNames = settings.vehicleNames;
    final vehicleCapacities = settings.vehicleCapacities;

    if (customers.isEmpty) {
      return List.generate(vehicleCount, (i) => TransportVehicleRoute(
        vehicleName: vehicleNames[i],
        vehicleIndex: i,
        transportType: type,
        dateKey: dateKey,
        capacity: i < vehicleCapacities.length ? vehicleCapacities[i] : 5,
      ));
    }

    // 住所リストを収集（transportLocations の先頭を使用）
    final addresses = customers.map((c) {
      if (c.transportLocations.isNotEmpty) {
        return c.transportLocations.first;
      }
      return '';
    }).toList();

    // APIキーがある場合は JS Interop 経由で Geocoding してクラスタリング
    List<({double lat, double lng})?> latLngs;
    if (apiKey != null && apiKey.isNotEmpty) {
      try {
        final jsResults = await MapsJsService.instance.geocodeBatch(
          addresses.where((a) => a.isNotEmpty).toList(),
        );
        // GeoResult → record 型に変換、住所が空の顧客用に null を補完
        final fullLatLngs = <({double lat, double lng})?>[];
        int geocodeIndex = 0;
        for (final addr in addresses) {
          if (addr.isEmpty) {
            fullLatLngs.add(null);
          } else {
            final r = geocodeIndex < jsResults.length ? jsResults[geocodeIndex] : null;
            fullLatLngs.add(r != null ? (lat: r.lat, lng: r.lng) : null);
            geocodeIndex++;
          }
        }
        latLngs = fullLatLngs;
      } catch (e) {
        debugPrint('[TransportPlanService] geocode batch (JS) failed: $e');
        latLngs = List.filled(customers.length, null);
      }
    } else {
      latLngs = List.filled(customers.length, null);
    }

    // 事業所座標
    final facilityLat = settings.facilityLat ?? 42.924;
    final facilityLng = settings.facilityLng ?? 143.196;

    // クラスタリング（Haversine 距離ベース）
    final clusters = _clusterCustomers(
      customers,
      latLngs,
      facilityLat,
      facilityLng,
      vehicleCount,
      vehicleCapacities,
    );

    // ルートを生成
    final routes = <TransportVehicleRoute>[];
    for (int i = 0; i < vehicleCount; i++) {
      final clusterCustomers = clusters[i];
      final stops = <TransportStop>[];

      for (int j = 0; j < clusterCustomers.length; j++) {
        final customer = clusterCustomers[j];
        final customerIndex = customers.indexOf(customer);
        final ll = customerIndex < latLngs.length ? latLngs[customerIndex] : null;
        final addr = customerIndex < addresses.length ? addresses[customerIndex] : '';

        stops.add(TransportStop(
          customerId: customer.id,
          customerName: customer.name,
          address: addr,
          lat: ll?.lat,
          lng: ll?.lng,
          orderIndex: j,
        ));
      }

      final route = TransportVehicleRoute(
        vehicleName: i < vehicleNames.length ? vehicleNames[i] : '車両${i + 1}',
        vehicleIndex: i,
        transportType: type,
        dateKey: dateKey,
        stops: stops,
        capacity: i < vehicleCapacities.length ? vehicleCapacities[i] : 5,
      );
      routes.add(route);
    }

    return routes;
  }

  /// ルート最適化（Nearest Neighbor TSP + Directions API）
  ///
  /// 構成: 事業所 → 停留所1 → ... → 停留所N → 事業所 （ラウンドトリップ）
  /// お迎え・お送り両方とも同じ構成
  ///
  /// 時刻算出ロジック:
  ///   お迎え: 事業所帰着時刻(利用開始) から逆算で各停留所のお迎え時刻を算出
  ///   お送り: 事業所出発時刻(利用終了) から順算で各停留所の到着時刻を算出
  Future<TransportVehicleRoute> optimizeRoute(
    TransportVehicleRoute route,
    String facilityAddress, [
    String? apiKey, // deprecated: 互換性維持のため残す。内部では MapsJsService を使用
  ]) async {
    // 毎回最新の設定を取得（キャッシュを使わない）
    final settings = SettingsService.instance.getSettings();
    final facilityLat = settings.facilityLat;
    final facilityLng = settings.facilityLng;

    debugPrint('[TransportPlanService] optimizeRoute: '
        '${route.vehicleName} ${route.typeLabel}, '
        'stops=${route.stops.length}');
    debugPrint('[TransportPlanService] using latest facilityLatLng='
        '${facilityLat != null ? "${facilityLat.toStringAsFixed(7)},${facilityLng!.toStringAsFixed(7)}" : "null (未設定)"}');

    if (route.stops.isEmpty) {
      route.optimizedAt = DateTime.now();
      await saveRoute(route);
      return route;
    }

    if (route.stops.length == 1) {
      // 停留所が1件なら並び替え不要、時刻・距離計算のみ
      route.stops[0].orderIndex = 0;
      if (facilityLat != null && facilityLng != null) {
        try {
          await _attachDirectionsDataRoundTrip(
            route: route,
            reorderedStops: route.stops,
            facilityLat: facilityLat,
            facilityLng: facilityLng,
            facilityAddress: facilityAddress,
          );
        } catch (e) {
          debugPrint('[TransportPlanService] directions (1 stop) failed: $e');
        }
      }
      route.optimizedAt = DateTime.now();
      route.googleMapsUrl = GoogleMapsService.buildGoogleMapsUrlRoundTrip(
        facilityLatLng: facilityLat != null ? '$facilityLat,$facilityLng' : null,
        facilityAddress: facilityAddress,
        stops: route.stops,
      );
      await saveRoute(route);
      return route;
    }

    // すべての停留所が LatLng を持っているか確認
    final allHaveGeocode = route.stops.every(
      (s) => s.lat != null && s.lng != null,
    );

    List<int> optimizedOrder;

    if (allHaveGeocode && facilityLat != null && facilityLng != null) {
      // Haversine 距離行列を構築（事業所 + 停留所全員）
      // index 0 = 事業所、1〜n = 停留所
      final n = route.stops.length + 1;
      final allLats = [facilityLat, ...route.stops.map((s) => s.lat!)];
      final allLngs = [facilityLng, ...route.stops.map((s) => s.lng!)];

      final matrix = List.generate(n, (i) {
        return List.generate(n, (j) {
          if (i == j) return 0;
          return GoogleMapsService.haversineDistance(
            allLats[i], allLngs[i],
            allLats[j], allLngs[j],
          ).round();
        });
      });

      // TSP 最近傍法（事業所=index0 から出発）
      final rawOrder = GoogleMapsService.optimizeRouteNearestNeighbor(
        matrix,
        0, // 事業所から出発
      );
      // index 0（事業所）を除いた停留所インデックス（0始まり）
      optimizedOrder = rawOrder
          .where((i) => i > 0)
          .map((i) => i - 1)
          .toList();
    } else {
      // LatLng なし → 順番そのまま
      optimizedOrder = List.generate(route.stops.length, (i) => i);
    }

    // 停留所を最適順に並び替え
    final reordered = optimizedOrder.map((i) => route.stops[i]).toList();
    for (int i = 0; i < reordered.length; i++) {
      reordered[i].orderIndex = i;
    }

    // Directions API でセグメントの距離・時間を取得（ラウンドトリップ）
    if (allHaveGeocode && facilityLat != null && facilityLng != null) {
      try {
        await _attachDirectionsDataRoundTrip(
          route: route,
          reorderedStops: reordered,
          facilityLat: facilityLat,
          facilityLng: facilityLng,
          facilityAddress: facilityAddress,
        );
      } catch (e) {
        debugPrint('[TransportPlanService] directions failed: $e');
        // ── Haversine 直線距離フォールバック ──
        // Directions API が失敗してもアプリを落とさず、
        // 直線距離（Haversine）+ 30km/h 概算で時間を補完する。
        _attachHaversineFallback(
          route: route,
          reorderedStops: reordered,
          facilityLat: facilityLat,
          facilityLng: facilityLng,
        );
        // 呼び出し元（TransportScreen）へ通知するため例外を再スロー
        // → UI 側で SnackBar を表示できる
        throw DirectionsFallbackException(
          '経路計算に失敗しました。直線距離で概算を表示しています。',
          cause: e,
        );
      }
    }

    route.stops
      ..clear()
      ..addAll(reordered);
    route.optimizedAt = DateTime.now();

    // 事業所往復 Google Maps URL を生成
    route.googleMapsUrl = GoogleMapsService.buildGoogleMapsUrlRoundTrip(
      facilityLatLng: facilityLat != null ? '$facilityLat,$facilityLng' : null,
      facilityAddress: facilityAddress,
      stops: reordered,
    );

    await saveRoute(route);
    debugPrint('[TransportPlanService] optimized: ${route.vehicleName}, '
        'stops=${reordered.length}, '
        'totalDist=${route.totalDistanceLabel}, '
        'totalDur=${route.totalDurationLabel}');
    return route;
  }

  /// Directions API（ラウンドトリップ、JS Interop版）でセグメント距離・時間を設定し、時刻も算出
  ///
  /// legs 構成:
  ///   legs[0]: 事業所 → stops[0]
  ///   legs[1]: stops[0] → stops[1]
  ///   ...
  ///   legs[n]: stops[n-1] → 事業所
  ///
  /// 時刻計算:
  ///   お迎え: 事業所帰着時刻(利用開始)から逆算
  ///   お送り: 事業所出発時刻(利用終了)から順算
  Future<void> _attachDirectionsDataRoundTrip({
    required TransportVehicleRoute route,
    required List<TransportStop> reorderedStops,
    required double facilityLat,
    required double facilityLng,
    required String facilityAddress,
  }) async {
    if (reorderedStops.isEmpty) return;

    // LatLng を持つ停留所のみ waypoint として使用
    final validStops = reorderedStops
        .where((s) => s.lat != null && s.lng != null)
        .toList();
    if (validStops.isEmpty) return;

    final facilityLatLng = LatLng(facilityLat, facilityLng);
    final waypointLatLngs = validStops
        .map((s) => LatLng(s.lat!, s.lng!))
        .toList();

    debugPrint('[TransportPlanService] _attachDirectionsDataRoundTrip: '
        'facility=$facilityLat,$facilityLng, '
        'waypoints=${waypointLatLngs.length}件');

    // JS Interop 経由で Directions API を呼ぶ
    final result = await MapsJsService.instance.getDirectionsRoundTrip(
      facilityLatLng: facilityLatLng,
      waypointLatLngs: waypointLatLngs,
      optimize: false,
    );

    route.totalDistanceMeters = result.totalDistanceMeters;
    route.totalDurationSeconds = result.totalDurationSeconds;

    // JsDirectionsResult: legDistances / legDurations
    // legs[0] = 事業所→stops[0]、legs[i] = stops[i-1]→stops[i]、legs[n] = stops[n-1]→事業所
    for (int i = 0; i < reorderedStops.length; i++) {
      if (i < result.legDistances.length) {
        reorderedStops[i].distanceFromPrevMeters = result.legDistances[i];
        reorderedStops[i].durationFromPrevSeconds = result.legDurations[i];
      }
    }

    // 時刻算出
    _assignScheduledTimes(
      route: route,
      reorderedStops: reorderedStops,
      legDurationSeconds: result.legDurations,
    );
  }

  /// Haversine 直線距離フォールバック
  ///
  /// Directions API が失敗した場合に呼ばれる。
  /// 直線距離（Haversine 公式）と 30km/h 概算速度で
  /// route および各停留所の距離・時間を設定する。
  ///
  /// 注意:
  ///   - 実際の道路距離より短い場合がある（直線距離のため）
  ///   - 迂回係数 1.4 を GeoUtil.estimateDurationSeconds 内で補正済み
  ///   - 設定された値は「概算」であることをUIで明示すること
  void _attachHaversineFallback({
    required TransportVehicleRoute route,
    required List<TransportStop> reorderedStops,
    required double facilityLat,
    required double facilityLng,
  }) {
    final validStops = reorderedStops
        .where((s) => s.lat != null && s.lng != null)
        .toList();
    if (validStops.isEmpty) return;

    final stopPoints = validStops
        .map((s) => (lat: s.lat!, lng: s.lng!))
        .toList();

    final fallback = GeoUtil.roundTripFallback(
      facilityLat: facilityLat,
      facilityLng: facilityLng,
      stops: stopPoints,
    );

    // 停留所に距離・時間を設定（legs[0]〜legs[n-1]、帰路 legs[n] は除く）
    for (int i = 0; i < reorderedStops.length; i++) {
      if (i < fallback.distances.length) {
        reorderedStops[i].distanceFromPrevMeters  = fallback.distances[i];
        reorderedStops[i].durationFromPrevSeconds = fallback.durations[i];
      }
    }

    // 合計距離・時間（帰路を含む全 legs の合算）
    final totalDist = fallback.distances.fold(0, (a, b) => a + b);
    final totalDur  = fallback.durations.fold(0,  (a, b) => a + b);
    route.totalDistanceMeters  = totalDist;
    route.totalDurationSeconds = totalDur;

    // 時刻算出（フォールバック値で概算）
    _assignScheduledTimes(
      route: route,
      reorderedStops: reorderedStops,
      legDurationSeconds: fallback.durations,
    );

    debugPrint('[TransportPlanService] Haversine fallback applied: '
        'totalDist=${totalDist}m (概算), totalDur=${totalDur}s (概算), '
        'stops=${reorderedStops.length}件');
  }

  /// 時刻計算ロジック
  ///
  /// お迎え: 事業所帰着時刻(利用開始) から逆算して各停留所のお迎え時刻を算出
  ///   時刻[stops[k]] = 時刻[stops[k+1]] − legs[k+1].duration
  ///
  /// お送り: 事業所出発時刻(利用終了) から順算して各停留所の到着時刻を算出
  ///   時刻[stops[0]] = 事業所出発 + legs[0].duration
  ///   時刻[stops[k]] = 時刻[stops[k-1]] + legs[k].duration
  void _assignScheduledTimes({
    required TransportVehicleRoute route,
    required List<TransportStop> reorderedStops,
    required List<int> legDurationSeconds,
  }) {
    if (reorderedStops.isEmpty || legDurationSeconds.isEmpty) return;

    final settings = SettingsService.instance.getSettings();
    final isPickup = route.transportType == TransportType.pickup;

    // ベース時刻を HH:mm 文字列から DateTime に変換
    final baseTimeStr = isPickup
        ? settings.defaultPickupStart // お迎え: 帰着時刻 = 利用開始
        : settings.defaultDropoffEnd; // お送り: 出発時刻 = 利用終了

    DateTime? baseTime;
    try {
      final parts = baseTimeStr.split(':');
      if (parts.length == 2) {
        final now = DateTime.now();
        baseTime = DateTime(
          now.year, now.month, now.day,
          int.parse(parts[0]),
          int.parse(parts[1]),
        );
      }
    } catch (_) {
      return; // 時刻取得失敗: 計算スキップ
    }
    if (baseTime == null) return;

    if (isPickup) {
      // お迎え: 逆算
      // legs: [F→s0, s0→s1, ..., sN-1→F]
      // 帰着時刻 = baseTime
      // sN の時刻 = baseTime - legs[N]  (最後の leg = sN-1→F)
      // s(N-1) の時刻 = sN の時刻 - legs[N-1]
      // ...
      var current = baseTime;
      // 最後の leg (停留所→事業所) の時間を引いた地点が最終停留所の時刻
      if (legDurationSeconds.length > reorderedStops.length) {
        current = current.subtract(
          Duration(seconds: legDurationSeconds.last),
        );
      }
      // 後ろから逆算
      for (int i = reorderedStops.length - 1; i >= 0; i--) {
        reorderedStops[i].scheduledTime =
            '${current.hour.toString().padLeft(2, '0')}:'
            '${current.minute.toString().padLeft(2, '0')}';
        if (i > 0 && i < legDurationSeconds.length) {
          current = current.subtract(
            Duration(seconds: legDurationSeconds[i]),
          );
        }
      }
    } else {
      // お送り: 順算
      // legs: [F→s0, s0→s1, ..., sN-1→F]
      // 出発時刻 = baseTime
      // s0 の時刻 = baseTime + legs[0]
      // s1 の時刻 = s0 の時刻 + legs[1]
      var current = baseTime;
      for (int i = 0; i < reorderedStops.length; i++) {
        if (i < legDurationSeconds.length) {
          current = current.add(Duration(seconds: legDurationSeconds[i]));
        }
        reorderedStops[i].scheduledTime =
            '${current.hour.toString().padLeft(2, '0')}:'
            '${current.minute.toString().padLeft(2, '0')}';
      }
    }

    debugPrint('[TransportPlanService] _assignScheduledTimes: '
        'type=${route.typeLabel}, '
        'stops=${reorderedStops.map((s) => '「${s.customerName}=${s.scheduledTime}」').join(", ")}');
  }

  // ── クラスタリング ────────────────────────────────────────────

  /// k-means 的な単純クラスタリング（Haversine距離）
  List<List<Customer>> _clusterCustomers(
    List<Customer> customers,
    List<({double lat, double lng})?> latLngs,
    double facilityLat,
    double facilityLng,
    int vehicleCount,
    List<int> capacities,
  ) {
    final clusters = List.generate(vehicleCount, (_) => <Customer>[]);

    // LatLng がある顧客とない顧客を分ける
    final withGeo = <int>[]; // インデックス
    final withoutGeo = <int>[];
    for (int i = 0; i < customers.length; i++) {
      if (i < latLngs.length && latLngs[i] != null) {
        withGeo.add(i);
      } else {
        withoutGeo.add(i);
      }
    }

    // 事業所を中心に最もバランスよく割り当て（角度ベースのセクター分割）
    if (withGeo.isNotEmpty) {
      // 各顧客の事業所からの角度を計算
      final angles = withGeo.map((i) {
        final ll = latLngs[i]!;
        return _mathAtan2(
          ll.lng - facilityLng,
          ll.lat - facilityLat,
        );
      }).toList();

      // 角度でソート
      final sortedIndices = List<int>.generate(withGeo.length, (i) => i)
        ..sort((a, b) => angles[a].compareTo(angles[b]));

      // 均等に車両に割り当て
      for (int si = 0; si < sortedIndices.length; si++) {
        final customerIdx = withGeo[sortedIndices[si]];
        final vehicleIdx = si % vehicleCount;
        // 定員チェック
        int targetVehicle = vehicleIdx;
        for (int v = 0; v < vehicleCount; v++) {
          final candidate = (vehicleIdx + v) % vehicleCount;
          final cap = candidate < capacities.length ? capacities[candidate] : 5;
          if (clusters[candidate].length < cap) {
            targetVehicle = candidate;
            break;
          }
        }
        clusters[targetVehicle].add(customers[customerIdx]);
      }
    }

    // LatLng なし顧客は余裕のある車両に均等配置
    for (final i in withoutGeo) {
      int targetVehicle = 0;
      int minCount = clusters[0].length;
      for (int v = 1; v < vehicleCount; v++) {
        if (clusters[v].length < minCount) {
          minCount = clusters[v].length;
          targetVehicle = v;
        }
      }
      clusters[targetVehicle].add(customers[i]);
    }

    return clusters;
  }

  static double _mathAtan2(double y, double x) {
    return _atan2(y, x);
  }

  static double _atan2(double y, double x) {
    const pi = 3.14159265358979;
    if (x > 0) return _atan(y / x);
    if (x < 0 && y >= 0) return _atan(y / x) + pi;
    if (x < 0 && y < 0) return _atan(y / x) - pi;
    if (x == 0 && y > 0) return pi / 2;
    if (x == 0 && y < 0) return -pi / 2;
    return 0;
  }

  static double _atan(double x) {
    // 近似 arctan
    const pi = 3.14159265358979;
    if (x.abs() > 1) {
      return (x > 0 ? 1 : -1) * pi / 2 - _atan(1 / x);
    }
    return x - x * x * x / 3 + x * x * x * x * x / 5;
  }
}

// ── 例外クラス ────────────────────────────────────────────────────

/// Directions API 失敗時に Haversine フォールバックを適用したことを
/// 呼び出し元（TransportScreen）に通知するための例外。
///
/// catch して SnackBar で「概算表示中」を案内する用途に使う。
/// アプリはクラッシュしない（フォールバック値は設定済み）。
class DirectionsFallbackException implements Exception {
  final String message;
  final Object? cause;

  const DirectionsFallbackException(this.message, {this.cause});

  @override
  String toString() =>
      'DirectionsFallbackException: $message'
      '${cause != null ? '\n  cause: $cause' : ''}';
}
