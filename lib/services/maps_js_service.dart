// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/geocode_candidate.dart';
import 'maps_loader.dart';
import 'settings_service.dart';

// ── JS グローバル関数バインディング ──────────────────────────────
// dart:js_interop (@JS アノテーション) で index.html の window.* を呼び出す。
// package:js は使用しない（dart:js_interop に統一）。

@JS('geocodeAddress')
external JSPromise _geocodeAddressJs(String address);

@JS('geocodeCandidates')
external JSPromise _geocodeCandidatesJs(String address, int maxResults);

@JS('reverseGeocode')
external JSPromise _reverseGeocodeJs(double lat, double lng);

@JS('getDirectionsRoundTrip')
external JSPromise _getDirectionsRoundTripJs(String requestJson);

// ── 結果クラス ───────────────────────────────────────────────────

/// Geocoding 結果
class GeoResult {
  final double lat;
  final double lng;
  const GeoResult({required this.lat, required this.lng});
}

/// 逆ジオコーディング結果（Day 8 追加改修）
///
/// 「地図から直接指定」の住所表示用。座標が本体なので
/// 失敗しても例外にせず [ok] = false で返す。
class ReverseGeocodeResult {
  final bool ok;
  final String formattedAddress;
  final List<String> types;
  final String status;

  const ReverseGeocodeResult({
    required this.ok,
    required this.formattedAddress,
    this.types = const [],
    this.status = '',
  });

  /// 失敗時（住所未取得）
  static const ReverseGeocodeResult failed =
      ReverseGeocodeResult(ok: false, formattedAddress: '', status: 'FAILED');
}

/// Routes API (computeRoutes) の各区間結果
///
/// JS側 legs[i] = { distanceMeters, durationSeconds }
class RouteLeg {
  /// 区間距離 [m]
  final int distanceMeters;

  /// 区間所要時間 [s]
  final int durationSeconds;

  const RouteLeg({
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

/// Routes API ラウンドトリップ結果
///
/// 【JS側レスポンス構造（index.html 参照）】
///   totalDistanceMeters: number          合計距離 [m]
///   totalDurationSeconds: number         合計時間 [s]（durationMillis / 1000）
///   polylinePoints: [{lat, lng}, ...]    ルートポリライン座標列
///   optimizedOrder: number[]             optimize=true 時の waypoint 順序（0始まり）
///   legs: [{ distanceMeters, durationSeconds }, ...]  各区間
///
/// 【移行履歴】
///   旧: JsDirectionsResult（DirectionsService 用）→ 廃止
///   新: JsDirectionsResult（Routes API 用、同名で互換レイヤーを維持）
///
/// legDistances / legDurations は旧 DirectionsService 形式との互換ゲッター。
/// transport_plan_service.dart がこれらを参照しているため残す。
class JsDirectionsResult {
  /// 合計距離 [m]
  final int totalDistanceMeters;

  /// 合計時間 [s]
  final int totalDurationSeconds;

  /// ルートポリライン（Routes API の Route.path から変換）
  final List<LatLng> polylinePoints;

  /// TSP 最適化後の waypoint 順序（optimize=true のとき意味がある）
  /// Routes API では optimizedIntermediateWaypointIndices（0始まり）
  final List<int> optimizedOrder;

  /// 各区間の距離・時間リスト
  /// legs[0]: 事業所→stops[0]、legs[n]: stops[n-1]→事業所
  final List<RouteLeg> legs;

  const JsDirectionsResult({
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.polylinePoints,
    required this.optimizedOrder,
    required this.legs,
  });

  // ── 互換ゲッター（旧フィールド名との互換性）──────────────────
  // transport_plan_service.dart が result.legDistances / result.legDurations を
  // 参照しているため、legs から派生させる互換ゲッターを提供する。

  /// 各区間の距離 [m] リスト（旧 legDistances との互換）
  List<int> get legDistances => legs.map((l) => l.distanceMeters).toList();

  /// 各区間の時間 [s] リスト（旧 legDurations との互換）
  List<int> get legDurations => legs.map((l) => l.durationSeconds).toList();

  /// @deprecated: Routes API では encodedPolyline は存在しない
  /// polylinePoints を使ってください。
  String get encodedPolyline => '';
}

/// Google Maps JS API（JS Interop版）クライアント
///
/// dart:js_interop 経由で window.google.maps.routes.Route.computeRoutes を呼ぶ。
/// CORS 問題なし、キーはブラウザ URL に露出しない。
///
/// 【移行済み API】
///   旧: google.maps.DirectionsService.route() → deprecated（2026-02）
///   新: google.maps.routes.Route.computeRoutes() → 本実装
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

  // ── 逆ジオコーディング（Day 8 追加改修） ─────────────────

  /// 緯度経度 → 住所（地図から直接指定したピンの表示用）
  ///
  /// 座標が本体のため、失敗しても throw せず
  /// [ReverseGeocodeResult.failed] を返す（呼び出し側は保存を続行可能）。
  Future<ReverseGeocodeResult> reverseGeocode(double lat, double lng) async {
    try {
      await _getKeyAndEnsureLoaded();
      debugPrint('[MapsJsService] reverseGeocode: '
          '${lat.toStringAsFixed(7)}, ${lng.toStringAsFixed(7)}');
      final jsResult = await _reverseGeocodeJs(lat, lng).toDart;
      final dartified = jsResult.dartify();
      final str = (dartified is String) ? dartified : '';
      if (str.isEmpty) return ReverseGeocodeResult.failed;
      final decoded = jsonDecode(str);
      if (decoded is! Map) return ReverseGeocodeResult.failed;
      final status = (decoded['status'] as String?) ?? 'ERROR';
      final addr = ((decoded['formattedAddress'] as String?) ?? '').trim();
      if (status != 'OK' || addr.isEmpty) {
        debugPrint('[MapsJsService] reverseGeocode failed: status=$status');
        return ReverseGeocodeResult(
            ok: false, formattedAddress: '', status: status);
      }
      final types = (decoded['types'] is List)
          ? (decoded['types'] as List).map((e) => e.toString()).toList()
          : const <String>[];
      debugPrint('[MapsJsService] reverseGeocode result: "$addr" $types');
      return ReverseGeocodeResult(
          ok: true, formattedAddress: addr, types: types, status: status);
    } catch (e) {
      // API キー未設定・ネットワークエラー等。座標保存は妨げない。
      debugPrint('[MapsJsService] reverseGeocode error (座標のみ保存します): $e');
      return ReverseGeocodeResult.failed;
    }
  }

  // ── Geocoding 候補一覧（Day 8） ───────────────────────────────

  /// セッション内キャッシュ（同一文字列の重複 geocode を抑制）
  final Map<String, GeocodeCandidatesResult> _candidateCache = {};

  /// キャッシュをクリア（テスト・明示リトライ用）
  void clearCandidateCache() => _candidateCache.clear();

  /// 住所 → 候補一覧（最大 [maxResults] 件）
  ///
  /// 帯広エリア bounds バイアス + country=JP 制限は JS 側で付与。
  /// 0 件は空リスト（例外にしない）。API エラーのみ throw。
  Future<GeocodeCandidatesResult> geocodeCandidates(
    String address, {
    // Day 8 修正: 誤ヒットが 1 件目に来ても正しい候補を拾えるよう取得数を広げる
    int maxResults = 8,
    bool useCache = true,
  }) async {
    final key = address.trim();
    if (key.isEmpty) {
      return GeocodeCandidatesResult(address: key, candidates: const []);
    }
    final cached = useCache ? _candidateCache[key] : null;
    if (cached != null) {
      debugPrint('[MapsJsService] geocodeCandidates (cache): "$key" → ${cached.candidates.length}件');
      return cached;
    }
    await _getKeyAndEnsureLoaded();
    debugPrint('[MapsJsService] geocodeCandidates: "$key" (max=$maxResults)');
    try {
      final jsResult = await _geocodeCandidatesJs(key, maxResults).toDart;
      final dartified = jsResult.dartify();
      final str = (dartified is String) ? dartified : '';
      if (str.isEmpty) {
        throw StateError('geocodeCandidates: JS から空の応答');
      }
      final decoded = jsonDecode(str);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('geocodeCandidates: 応答が Map ではありません');
      }
      final raw = decoded['candidates'];
      final list = <GeocodeCandidate>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map) {
            list.add(GeocodeCandidate.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
      final result = GeocodeCandidatesResult(address: key, candidates: list);
      _candidateCache[key] = result;
      debugPrint('[MapsJsService] geocodeCandidates result: ${list.length}件'
          '${list.isNotEmpty ? ' first="${list.first.formattedAddress}"' : ''}');
      return result;
    } catch (e) {
      debugPrint('[MapsJsService] geocodeCandidates error: $e');
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

  // ── Routes API（ラウンドトリップ） ───────────────────────────

  /// 事業所を起点・終点とするラウンドトリップルートを取得する
  ///
  /// 【使用API】
  ///   google.maps.routes.Route.computeRoutes()（Routes API）
  ///   旧 DirectionsService は 2026-02 に deprecated のため廃止済み。
  ///
  /// [facilityLatLng] 事業所の緯度経度
  /// [waypointLatLngs] 停留所の緯度経度リスト（intermediates として渡す）
  /// [optimize] TSP最適化を行うか（true=最適化、false=順番固定）
  ///
  /// 構成: 事業所(origin) → 停留所1〜N(intermediates) → 事業所(destination)
  ///
  /// 戻り値の legs 構成:
  ///   legs[0]:   事業所 → stops[0]
  ///   legs[i]:   stops[i-1] → stops[i]
  ///   legs[n]:   stops[n-1] → 事業所
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

    // ── デバッグログ: Routes API リクエスト ──
    debugPrint('[MapsJsService] Routes API request: '
        'facility=${facilityLatLng.latitude},${facilityLatLng.longitude}, '
        'stops=${waypointLatLngs.length}件, optimize=$optimize');

    try {
      final jsResult = await _getDirectionsRoundTripJs(requestJson).toDart;

      // dartify() の戻り値は String（JSON文字列）のはずだが、
      // null や JSObject が返る場合に備えて null 安全にキャスト
      final dartified = jsResult.dartify();
      if (dartified == null) {
        throw StateError('Routes API: JS から null が返されました');
      }
      final resultStr = (dartified as String?) ?? '';
      if (resultStr.isEmpty) {
        throw StateError('Routes API: JS から空文字列が返されました');
      }

      final decoded = jsonDecode(resultStr);
      if (decoded is! Map<String, dynamic>) {
        throw StateError(
            'Routes API: レスポンスが Map ではありません (${decoded.runtimeType})');
      }
      final map = decoded;

      // ── 合計距離・時間（null 安全）──
      final totalDist = (map['totalDistanceMeters'] as num?)?.toInt() ?? 0;
      final totalDur  = (map['totalDurationSeconds'] as num?)?.toInt() ?? 0;

      // ── legs パース（新構造: オブジェクト配列）──
      // JS側: legs = [{distanceMeters, durationSeconds}, ...]
      final legsRaw = map['legs'];
      final legsList = (legsRaw is List) ? legsRaw : <dynamic>[];

      final legs = <RouteLeg>[];
      for (final leg in legsList) {
        if (leg is Map) {
          legs.add(RouteLeg(
            distanceMeters:  (leg['distanceMeters']  as num?)?.toInt() ?? 0,
            durationSeconds: (leg['durationSeconds'] as num?)?.toInt() ?? 0,
          ));
        } else {
          legs.add(const RouteLeg(distanceMeters: 0, durationSeconds: 0));
        }
      }

      // ── optimizedOrder（null / 非List のとき空配列）──
      final orderRaw = map['optimizedOrder'];
      final optimizedOrder = (orderRaw is List)
          ? orderRaw.map((e) => (e as num?)?.toInt() ?? 0).toList()
          : <int>[];

      // ── polylinePoints（Routes API: {lat,lng} 配列 → LatLng 変換）──
      // 旧 encodedPolyline は存在しない。Route.path から座標列を取得する。
      final ptsRaw = map['polylinePoints'];
      final polylinePoints = <LatLng>[];
      if (ptsRaw is List) {
        for (final pt in ptsRaw) {
          if (pt is Map) {
            final lat = (pt['lat'] as num?)?.toDouble();
            final lng = (pt['lng'] as num?)?.toDouble();
            if (lat != null && lng != null) {
              polylinePoints.add(LatLng(lat, lng));
            }
          }
        }
      }

      // ── デバッグログ: Routes API レスポンス ──
      final distKm  = (totalDist / 1000).toStringAsFixed(1);
      final durMin  = (totalDur  / 60  ).toStringAsFixed(0);
      debugPrint('[MapsJsService] Routes API success: '
          'totalDist=${distKm}km, totalDur=${durMin}min, '
          'legs=${legs.length}件, '
          'optimizedOrder=$optimizedOrder, '
          'pathPoints=${polylinePoints.length}');

      return JsDirectionsResult(
        totalDistanceMeters: totalDist,
        totalDurationSeconds: totalDur,
        polylinePoints: polylinePoints,
        optimizedOrder: optimizedOrder,
        legs: legs,
      );
    } catch (e, st) {
      // ── デバッグログ: Routes API 失敗 ──
      debugPrint('[MapsJsService] Routes API failed: $e');
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
}
