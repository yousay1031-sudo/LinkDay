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

    debugPrint('[MapsJsService] getDirectionsRoundTrip: '
        'facility=${facilityLatLng.latitude},${facilityLatLng.longitude}, '
        'stops=${waypointLatLngs.length}件, optimize=$optimize');

    try {
      final jsResult = await _getDirectionsRoundTripJs(requestJson).toDart;
      final resultStr = jsResult.dartify() as String;
      final map = jsonDecode(resultStr) as Map<String, dynamic>;

      final legDistances =
          (map['legDistances'] as List).map((e) => (e as num).toInt()).toList();
      final legDurations =
          (map['legDurations'] as List).map((e) => (e as num).toInt()).toList();
      final totalDist = (map['totalDistanceMeters'] as num).toInt();
      final totalDur = (map['totalDurationSeconds'] as num).toInt();
      final waypointOrder =
          (map['waypointOrder'] as List).map((e) => (e as num).toInt()).toList();
      final encodedPolyline = map['encodedPolyline'] as String;
      final polylinePoints = _decodePolyline(encodedPolyline);

      debugPrint('[MapsJsService] getDirectionsRoundTrip result: '
          'totalDist=${totalDist}m, totalDur=${totalDur}s, '
          'legs=${legDistances.length}, waypointOrder=$waypointOrder');

      return JsDirectionsResult(
        legDistances: legDistances,
        legDurations: legDurations,
        totalDistanceMeters: totalDist,
        totalDurationSeconds: totalDur,
        waypointOrder: waypointOrder,
        encodedPolyline: encodedPolyline,
        polylinePoints: polylinePoints,
      );
    } catch (e) {
      debugPrint('[MapsJsService] getDirectionsRoundTrip error: $e');
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
