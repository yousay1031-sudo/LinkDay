import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/customer.dart';
import '../models/transport_plan.dart';
import 'google_maps_service.dart';
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

    // APIキーがある場合は Geocoding してクラスタリング
    List<({double lat, double lng})?> latLngs;
    if (apiKey != null && apiKey.isNotEmpty) {
      try {
        latLngs = await GoogleMapsService.instance.geocodeBatch(
          addresses.where((a) => a.isNotEmpty).toList(),
          apiKey,
        );
        // 住所が空の顧客用に null を補完
        final fullLatLngs = <({double lat, double lng})?>[]; 
        int geocodeIndex = 0;
        for (final addr in addresses) {
          if (addr.isEmpty) {
            fullLatLngs.add(null);
          } else {
            fullLatLngs.add(geocodeIndex < latLngs.length
                ? latLngs[geocodeIndex]
                : null);
            geocodeIndex++;
          }
        }
        latLngs = fullLatLngs;
      } catch (e) {
        debugPrint('[TransportPlanService] geocode batch failed: $e');
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

  /// ルート最適化（Nearest Neighbor TSP + Distance Matrix API）
  ///
  /// 戻り値: 最適化済みルート（停留所の順番が更新される）
  Future<TransportVehicleRoute> optimizeRoute(
    TransportVehicleRoute route,
    String facilityAddress,
    String apiKey,
  ) async {
    if (route.stops.length <= 1) {
      // 停留所が1件以下なら最適化不要
      route.optimizedAt = DateTime.now();
      await saveRoute(route);
      return route;
    }

    // 全拠点（事業所 + 停留所）の LatLng を収集
    final settings = SettingsService.instance.getSettings();
    final facilityLat = settings.facilityLat;
    final facilityLng = settings.facilityLng;

    // すべての停留所が LatLng を持っているか確認
    final allHaveGeocode = route.stops.every(
      (s) => s.lat != null && s.lng != null,
    );

    List<int> optimizedOrder;

    if (allHaveGeocode && facilityLat != null && facilityLng != null) {
      // 距離行列を構築（事業所 + 停留所全員）
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
    final reordered = optimizedOrder
        .map((i) => route.stops[i])
        .toList();

    // orderIndex を更新
    for (int i = 0; i < reordered.length; i++) {
      reordered[i].orderIndex = i;
    }

    // Directions API でセグメントの距離・時間を取得
    if (allHaveGeocode && facilityLat != null && facilityLng != null && apiKey.isNotEmpty) {
      try {
        await _attachDirectionsData(
          route: route,
          reorderedStops: reordered,
          facilityAddress: facilityAddress,
          apiKey: apiKey,
        );
      } catch (e) {
        debugPrint('[TransportPlanService] directions failed: $e');
      }
    }

    route.stops
      ..clear()
      ..addAll(reordered);
    route.optimizedAt = DateTime.now();

    // Google Maps URL を生成
    route.googleMapsUrl = GoogleMapsService.buildGoogleMapsUrlFromStops(
      facilityAddress: facilityAddress,
      stops: reordered,
      type: route.transportType,
    );

    await saveRoute(route);
    debugPrint(
        '[TransportPlanService] optimized: ${route.vehicleName}, stops=${reordered.length}');
    return route;
  }

  /// Directions API でセグメント距離・時間を設定
  Future<void> _attachDirectionsData({
    required TransportVehicleRoute route,
    required List<TransportStop> reorderedStops,
    required String facilityAddress,
    required String apiKey,
  }) async {
    if (reorderedStops.isEmpty) return;

    final stopAddresses = reorderedStops.map((s) => s.address).toList();
    String origin, destination;
    List<String> waypoints;

    if (route.transportType == TransportType.pickup) {
      // お迎え: 事業所を最後に
      origin = stopAddresses.first;
      destination = facilityAddress;
      waypoints = stopAddresses.length > 1 ? stopAddresses.sublist(1) : [];
    } else {
      // お送り: 事業所を最初に
      origin = facilityAddress;
      destination = stopAddresses.last;
      waypoints = stopAddresses.length > 1
          ? stopAddresses.sublist(0, stopAddresses.length - 1)
          : [];
    }

    final result = await GoogleMapsService.instance.getDirections(
      origin: origin,
      destination: destination,
      waypoints: waypoints,
      apiKey: apiKey,
    );

    route.totalDistanceMeters = result.totalDistanceMeters;
    route.totalDurationSeconds = result.totalDurationSeconds;

    // 各停留所に距離・時間を設定
    for (int i = 0; i < reorderedStops.length; i++) {
      if (i < result.legDistanceMeters.length) {
        reorderedStops[i].distanceFromPrevMeters = result.legDistanceMeters[i];
        reorderedStops[i].durationFromPrevSeconds =
            result.legDurationSeconds[i];
      }
    }
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
