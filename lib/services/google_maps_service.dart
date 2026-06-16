import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/transport_plan.dart';

/// Google Maps API レスポンス
class GeocodingResult {
  final double lat;
  final double lng;
  final String formattedAddress;
  const GeocodingResult({
    required this.lat,
    required this.lng,
    required this.formattedAddress,
  });
}

/// 2点間の距離・時間情報
class DistanceInfo {
  final int distanceMeters;
  final int durationSeconds;
  final String distanceText;
  final String durationText;
  const DistanceInfo({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.distanceText,
    required this.durationText,
  });
}

/// Google Maps API クライアント
/// Geocoding / Directions / Distance Matrix をラップする
class GoogleMapsService {
  GoogleMapsService._();
  static final GoogleMapsService instance = GoogleMapsService._();

  static const String _geocodingBase =
      'https://maps.googleapis.com/maps/api/geocode/json';
  static const String _directionsBase =
      'https://maps.googleapis.com/maps/api/directions/json';
  static const String _distanceMatrixBase =
      'https://maps.googleapis.com/maps/api/distancematrix/json';

  // ── Geocoding ────────────────────────────────────────────────

  /// 住所文字列 → LatLng
  Future<({double lat, double lng})> geocodeAddress(
    String address,
    String apiKey,
  ) async {
    final uri = Uri.parse(_geocodingBase).replace(queryParameters: {
      'address': address,
      'language': 'ja',
      'region': 'jp',
      'key': apiKey,
    });

    final response = await http.get(uri).timeout(const Duration(seconds: 10));
    _checkHttpStatus(response);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    _checkApiStatus(body);

    final location =
        body['results'][0]['geometry']['location'] as Map<String, dynamic>;
    return (
      lat: (location['lat'] as num).toDouble(),
      lng: (location['lng'] as num).toDouble(),
    );
  }

  /// 複数住所を一括 Geocoding（失敗した住所は null を返す）
  Future<List<({double lat, double lng})?>> geocodeBatch(
    List<String> addresses,
    String apiKey,
  ) async {
    final results = <({double lat, double lng})?>[];
    for (final address in addresses) {
      try {
        final r = await geocodeAddress(address, apiKey);
        results.add(r);
        // API レート制限回避
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        debugPrint('[GoogleMapsService] geocode failed for "$address": $e');
        results.add(null);
      }
    }
    return results;
  }

  // ── Distance Matrix ──────────────────────────────────────────

  /// n×n の距離行列を取得する（最大10×10）
  /// origins と destinations は "lat,lng" 形式の文字列リスト
  Future<List<List<DistanceInfo?>>> getDistanceMatrix(
    List<String> origins,
    List<String> destinations,
    String apiKey,
  ) async {
    final uri = Uri.parse(_distanceMatrixBase).replace(queryParameters: {
      'origins': origins.join('|'),
      'destinations': destinations.join('|'),
      'language': 'ja',
      'region': 'jp',
      'units': 'metric',
      'key': apiKey,
    });

    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    _checkHttpStatus(response);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    _checkApiStatus(body);

    final rows = body['rows'] as List<dynamic>;
    return rows.map<List<DistanceInfo?>>((row) {
      final elements = row['elements'] as List<dynamic>;
      return elements.map<DistanceInfo?>((element) {
        if (element['status'] != 'OK') return null;
        return DistanceInfo(
          distanceMeters: element['distance']['value'] as int,
          durationSeconds: element['duration']['value'] as int,
          distanceText: element['distance']['text'] as String,
          durationText: element['duration']['text'] as String,
        );
      }).toList();
    }).toList();
  }

  // ── Directions ───────────────────────────────────────────────

  /// 経由地付きのルートを取得する
  /// origin/destination: "lat,lng" or 住所文字列
  /// waypoints: 経由地リスト（"lat,lng" or 住所）
  /// 戻り値: (polylinePoints, legDistances, legDurations, totalDistance, totalDuration)
  Future<DirectionsResult> getDirections({
    required String origin,
    required String destination,
    List<String> waypoints = const [],
    required String apiKey,
  }) async {
    final params = <String, String>{
      'origin': origin,
      'destination': destination,
      'language': 'ja',
      'region': 'jp',
      'units': 'metric',
      'key': apiKey,
    };
    if (waypoints.isNotEmpty) {
      params['waypoints'] = 'optimize:false|${waypoints.join('|')}';
    }

    final uri = Uri.parse(_directionsBase).replace(queryParameters: params);
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    _checkHttpStatus(response);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    _checkApiStatus(body);

    final route = body['routes'][0] as Map<String, dynamic>;
    final legs = route['legs'] as List<dynamic>;

    int totalDistance = 0;
    int totalDuration = 0;
    final legDistances = <int>[];
    final legDurations = <int>[];

    for (final leg in legs) {
      final dist = leg['distance']['value'] as int;
      final dur = leg['duration']['value'] as int;
      totalDistance += dist;
      totalDuration += dur;
      legDistances.add(dist);
      legDurations.add(dur);
    }

    final encodedPolyline =
        route['overview_polyline']['points'] as String;
    final polylinePoints = _decodePolyline(encodedPolyline);

    return DirectionsResult(
      polylinePoints: polylinePoints,
      legDistanceMeters: legDistances,
      legDurationSeconds: legDurations,
      totalDistanceMeters: totalDistance,
      totalDurationSeconds: totalDuration,
    );
  }

  // ── Google Maps URL生成 ──────────────────────────────────────

  /// ドライバー用の Google Maps URL を生成する
  /// origin → waypoints → destination の順でナビ開始できる URL
  static String buildGoogleMapsUrl({
    required String origin,
    required String destination,
    List<String> waypoints = const [],
    TravelMode mode = TravelMode.driving,
  }) {
    final buffer = StringBuffer('https://www.google.com/maps/dir/');
    buffer.write(Uri.encodeComponent(origin));
    for (final wp in waypoints) {
      buffer.write('/${Uri.encodeComponent(wp)}');
    }
    buffer.write('/${Uri.encodeComponent(destination)}');
    buffer.write('?travelmode=${mode.name}');
    return buffer.toString();
  }

  /// LatLng リストから Google Maps URL を生成
  static String buildGoogleMapsUrlFromStops({
    required String facilityAddress,
    required List<TransportStop> stops,
    required TransportType type,
  }) {
    final addresses = stops.map((s) => s.address).toList();
    if (type == TransportType.pickup) {
      // お迎え: 利用者宅→事業所
      return buildGoogleMapsUrl(
        origin: addresses.first,
        destination: facilityAddress,
        waypoints: addresses.length > 1 ? addresses.sublist(1) : [],
      );
    } else {
      // お送り: 事業所→利用者宅
      return buildGoogleMapsUrl(
        origin: facilityAddress,
        destination: addresses.last,
        waypoints: addresses.length > 1 ? addresses.sublist(0, addresses.length - 1) : [],
      );
    }
  }

  // ── ルート最適化（TSP近似）────────────────────────────────────

  /// 最近傍法 (Nearest Neighbor) による停留所の訪問順最適化
  /// distanceMatrix[i][j] = i から j までの距離(m)（null=到達不可）
  /// startIndex: 出発点（事業所 = 最初か最後）
  static List<int> optimizeRouteNearestNeighbor(
    List<List<int?>> distanceMatrix,
    int startIndex,
  ) {
    final n = distanceMatrix.length;
    if (n <= 1) return List.generate(n, (i) => i);

    final visited = List<bool>.filled(n, false);
    final route = <int>[];
    int current = startIndex;
    visited[current] = true;
    route.add(current);

    while (route.length < n) {
      int? nearest;
      int minDist = 999999999;

      for (int j = 0; j < n; j++) {
        if (visited[j]) continue;
        final d = distanceMatrix[current][j];
        if (d != null && d < minDist) {
          minDist = d;
          nearest = j;
        }
      }

      if (nearest == null) break; // 到達不可の孤立点があれば終了
      visited[nearest] = true;
      route.add(nearest);
      current = nearest;
    }

    // 未訪問の点を末尾に追加（孤立点対策）
    for (int i = 0; i < n; i++) {
      if (!visited[i]) route.add(i);
    }

    return route;
  }

  // ── プライベートヘルパー ──────────────────────────────────────

  void _checkHttpStatus(http.Response response) {
    if (response.statusCode != 200) {
      throw Exception('HTTP エラー: ${response.statusCode}');
    }
  }

  void _checkApiStatus(Map<String, dynamic> body) {
    final status = body['status'] as String?;
    if (status == null || status == 'OK' || status == 'ZERO_RESULTS') return;
    final message = body['error_message'] as String? ?? status;
    switch (status) {
      case 'REQUEST_DENIED':
        throw Exception('APIキーが無効または権限不足です: $message');
      case 'OVER_DAILY_LIMIT':
      case 'OVER_QUERY_LIMIT':
        throw Exception('APIクォータを超過しました');
      case 'INVALID_REQUEST':
        throw Exception('リクエストが無効です: $message');
      default:
        throw Exception('Google Maps API エラー: $status - $message');
    }
  }

  /// エンコードされたポリラインを LatLng リストにデコードする
  List<({double lat, double lng})> _decodePolyline(String encoded) {
    final List<({double lat, double lng})> result = [];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int shift = 0, b = 0, result0 = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result0 |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = (result0 & 1) != 0 ? ~(result0 >> 1) : (result0 >> 1);
      lat += dlat;

      shift = 0;
      result0 = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result0 |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = (result0 & 1) != 0 ? ~(result0 >> 1) : (result0 >> 1);
      lng += dlng;

      result.add((lat: lat / 1e5, lng: lng / 1e5));
    }
    return result;
  }

  // ── ユークリッド距離近似（APIなし、グループ分け用） ──────────

  /// Haversine 公式による2点間の距離（メートル）
  static double haversineDistance(
    double lat1, double lng1,
    double lat2, double lng2,
  ) {
    const r = 6371000.0; // 地球半径(m)
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static double _toRad(double deg) => deg * math.pi / 180;
}

// ── 移動手段 ─────────────────────────────────────────────────
enum TravelMode { driving, walking, bicycling, transit }

// ── DirectionsResult ─────────────────────────────────────────
class DirectionsResult {
  final List<({double lat, double lng})> polylinePoints;
  final List<int> legDistanceMeters;
  final List<int> legDurationSeconds;
  final int totalDistanceMeters;
  final int totalDurationSeconds;

  const DirectionsResult({
    required this.polylinePoints,
    required this.legDistanceMeters,
    required this.legDurationSeconds,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
  });
}
