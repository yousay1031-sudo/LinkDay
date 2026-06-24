// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'maps_loader.dart';
import 'settings_service.dart';

// ── JS グローバル関数バインディング ──────────────────────────────

@JS('geocodeAddress')
external JSPromise _geocodeAddressJs(String address);

@JS('getDirectionsRoundTrip')
external JSPromise _getDirectionsRoundTripJs(String requestJson);

// ── 結果クラス ───────────────────────────────────────────────────

/// Geocoding 結果
class GeoResult {
  final double lat;
  final double lng;
  const GeoResult({required this.lat, required this.lng});
}

/// Directions ラウンドトリップ結果
class JsDirectionsResult {
  /// legs[0]: 事業所→stops[0], legs[n]: stops[n-1]→事業所
  final List<int> legDistances;
  final List<int> legDurations;
  final int totalDistanceMeters;
  final int totalDurationSeconds;

  /// TSP 最適化後の waypoint 順序（optimize=true のとき意味がある）
  final List<int> waypointOrder;

  /// エンコードされたポリライン（デコードは Dart 側で行う）
  final String encodedPolyline;

  /// ポリラインポイント（デコード済み）
  final List<LatLng> polylinePoints;

  const JsDirectionsResult({
    required this.legDistances,
    required this.legDurations,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.waypointOrder,
    required this.encodedPolyline,
    required this.polylinePoints,
  });
}

/// Google Maps JS API（JS Interop版）クライアント
///
/// dart:js_interop 経由で window.google.maps.* を呼ぶ。
/// CORS 問題なし、キーはブラウザ URL に露出しない。
class MapsJsService {
  MapsJsService._();
  static final MapsJsService instance = MapsJsService._();

  // ── 内部ヘルパー: API キー取得 + ロード保証 ──────────────────

  Future<String> _getKeyAndEnsureLoaded() async {
    final key = await SettingsService.instance.loadJsApiKey();
    if (key == null || key.isEmpty) {
      throw Exception(
          'Google Maps API キーが設定されていません。設定画面で入力してください。');
    }
    await MapsLoader.ensureLoaded(key);
    return key;
  }

  // ── Geocoding ────────────────────────────────────────────────

  /// 住所 → 緯度経度（Geocoder JS API）
  Future<GeoResult> geocodeAddress(String address) async {
    await _getKeyAndEnsureLoaded();

    debugPrint('[MapsJsService] geocodeAddress: $address');
    try {
      final jsResult = await _geocodeAddressJs(address).toDart;
      // JSObject → Map 変換
      final map = _jsObjectToMap(jsResult);
      final lat = (map['lat'] as num).toDouble();
      final lng = (map['lng'] as num).toDouble();
      debugPrint('[MapsJsService] geocodeAddress result: lat=$lat, lng=$lng');
      return GeoResult(lat: lat, lng: lng);
    } catch (e) {
      debugPrint('[MapsJsService] geocodeAddress error: $e');
      rethrow;
    }
  }

  /// 複数住所を一括 Geocoding（失敗した住所は null を返す）
  Future<List<GeoResult?>> geocodeBatch(List<String> addresses) async {
    final results = <GeoResult?>[];
    for (final address in addresses) {
      try {
        final r = await geocodeAddress(address);
        results.add(r);
        await Future.delayed(const Duration(milliseconds: 150));
      } catch (e) {
        debugPrint('[MapsJsService] geocodeBatch failed for "$address": $e');
        results.add(null);
      }
    }
    return results;
  }

  // ── Directions（ラウンドトリップ） ──────────────────────────

  /// 事業所を起点・終点とするラウンドトリップルートを取得する
  ///
  /// [facilityLatLng] 事業所の緯度経度
  /// [waypointLatLngs] 停留所の緯度経度リスト
  /// [optimize] TSP最適化を行うか（true=最適化、false=順番固定）
  ///
  /// 構成: 事業所 → 停留所1 → ... → 停留所N → 事業所
  ///
  /// JS側レスポンス構造（index.html 参照）:
  ///   legs: [{distanceMeters, durationSeconds, distanceText, durationText,
  ///           startAddress, endAddress}]
  ///   totalDistanceMeters: number
  ///   totalDurationSeconds: number
  ///   waypointOrder: number[]   (optimize=false のとき [])
  ///   encodedPolyline: string   (null/undefined のとき '')
  Future<JsDirectionsResult> getDirectionsRoundTrip({
    required LatLng facilityLatLng,
    required List<LatLng> waypointLatLngs,
    bool optimize = false,
  }) async {
    if (waypointLatLngs.isEmpty) {
      throw ArgumentError('waypointLatLngs must not be empty');
    }
    await _getKeyAndEnsureLoaded();

    final requestJson = jsonEncode({
      'facilityLat': facilityLatLng.latitude,
      'facilityLng': facilityLatLng.longitude,
      'waypointLatLngs': waypointLatLngs
          .map((p) => {'lat': p.latitude, 'lng': p.longitude})
          .toList(),
      'optimize': optimize,
    });

    // ── デバッグログ: リクエスト ──
    debugPrint('[MapsJsService] getDirectionsRoundTrip request: '
        'facility=${facilityLatLng.latitude},${facilityLatLng.longitude}, '
        'stops=${waypointLatLngs.length}件, optimize=$optimize');

    try {
      final jsResult = await _getDirectionsRoundTripJs(requestJson).toDart;

      // dartify() の戻り値は String（JSON文字列）のはずだが、
      // null や JSObject が返ってくる場合に備えて null 安全にキャスト
      final dartified = jsResult.dartify();
      if (dartified == null) {
        throw StateError('getDirectionsRoundTrip: JS から null が返されました');
      }
      final resultStr = dartified as String? ?? '';
      if (resultStr.isEmpty) {
        throw StateError('getDirectionsRoundTrip: JS から空文字列が返されました');
      }

      final map = jsonDecode(resultStr);
      if (map is! Map<String, dynamic>) {
        throw StateError(
            'getDirectionsRoundTrip: レスポンスが Map ではありません (${map.runtimeType})');
      }

      // ── legs パース（新構造: オブジェクト配列）──
      // JS側: legs = [{distanceMeters, durationSeconds, ...}, ...]
      final legsRaw = map['legs'];
      final legsList = (legsRaw is List) ? legsRaw : <dynamic>[];

      final legDistances = <int>[];
      final legDurations = <int>[];

      for (final leg in legsList) {
        if (leg is Map) {
          legDistances.add((leg['distanceMeters']  as num?)?.toInt() ?? 0);
          legDurations.add((leg['durationSeconds'] as num?)?.toInt() ?? 0);
        } else {
          legDistances.add(0);
          legDurations.add(0);
        }
      }

      // ── 合計距離・時間（null 安全）──
      final totalDist = (map['totalDistanceMeters'] as num?)?.toInt() ?? 0;
      final totalDur  = (map['totalDurationSeconds'] as num?)?.toInt() ?? 0;

      // ── waypointOrder（null / 非List のとき空配列）──
      final waypointRaw = map['waypointOrder'];
      final waypointOrder = (waypointRaw is List)
          ? waypointRaw.map((e) => (e as num?)?.toInt() ?? 0).toList()
          : <int>[];

      // ── encodedPolyline（null のとき空文字列）──
      final encodedPolyline = (map['encodedPolyline'] as String?) ?? '';
      final polylinePoints =
          encodedPolyline.isNotEmpty ? _decodePolyline(encodedPolyline) : <LatLng>[];

      // ── デバッグログ: レスポンス ──
      debugPrint('[MapsJsService] getDirectionsRoundTrip response: '
          'totalDist=${totalDist}m, totalDur=${totalDur}s, '
          'legs=${legDistances.length}件, '
          'waypointOrder=$waypointOrder, '
          'polylineLen=${encodedPolyline.length}');

      return JsDirectionsResult(
        legDistances: legDistances,
        legDurations: legDurations,
        totalDistanceMeters: totalDist,
        totalDurationSeconds: totalDur,
        waypointOrder: waypointOrder,
        encodedPolyline: encodedPolyline,
        polylinePoints: polylinePoints,
      );
    } catch (e, st) {
      // ── デバッグログ: 失敗詳細 ──
      debugPrint('[MapsJsService] getDirectionsRoundTrip FAILED: $e');
      debugPrint('[MapsJsService]   facility=${facilityLatLng.latitude},'
          '${facilityLatLng.longitude}, stops=${waypointLatLngs.length}件');
      debugPrint('[MapsJsService]   stackTrace: $st');
      rethrow;
    }
  }

  // ── プライベートヘルパー ──────────────────────────────────────

  /// JSObject を Dart Map に変換する
  Map<String, dynamic> _jsObjectToMap(JSAny? jsObj) {
    if (jsObj == null) return {};
    final dartified = jsObj.dartify();
    if (dartified is Map) {
      return dartified.map((k, v) => MapEntry(k.toString(), v));
    }
    return {};
  }

  /// エンコードされたポリラインを LatLng リストにデコードする
  List<LatLng> _decodePolyline(String encoded) {
    final result = <LatLng>[];
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

      result.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return result;
  }
}
