// ignore_for_file: avoid_web_libraries_in_flutter
/// Google Maps JS Interop ブリッジ — Web 実装
///
/// `dart:js_interop` への依存をこのファイルに閉じ込める。
/// index.html が定義する window.* 関数を呼び出し、結果を
/// プレーンな Dart 型（Map / String）に変換して返す。
library;

import 'dart:js_interop';

// ── JS グローバル関数バインディング ──────────────────────────────
// package:js は使用しない（dart:js_interop に統一）。

@JS('loadGoogleMaps')
external JSPromise _loadGoogleMapsJs(String apiKey);

@JS('geocodeAddress')
external JSPromise _geocodeAddressJs(String address);

@JS('geocodeCandidates')
external JSPromise _geocodeCandidatesJs(String address, int maxResults);

@JS('reverseGeocode')
external JSPromise _reverseGeocodeJs(double lat, double lng);

@JS('getDirectionsRoundTrip')
external JSPromise _getDirectionsRoundTripJs(String requestJson);

/// Maps JS API をロードする
Future<void> loadGoogleMaps(String apiKey) async {
  await _loadGoogleMapsJs(apiKey).toDart;
}

/// 住所 → {lat, lng}
Future<Map<String, dynamic>> geocodeAddress(String address) async {
  final jsResult = await _geocodeAddressJs(address).toDart;
  final dartified = jsResult.dartify();
  if (dartified is Map) {
    return dartified.map((k, v) => MapEntry(k.toString(), v));
  }
  return <String, dynamic>{};
}

/// 住所 → 候補一覧 JSON 文字列
Future<String> geocodeCandidates(String address, int maxResults) async {
  final jsResult = await _geocodeCandidatesJs(address, maxResults).toDart;
  final dartified = jsResult.dartify();
  return (dartified is String) ? dartified : '';
}

/// 緯度経度 → 住所 JSON 文字列
Future<String> reverseGeocode(double lat, double lng) async {
  final jsResult = await _reverseGeocodeJs(lat, lng).toDart;
  final dartified = jsResult.dartify();
  return (dartified is String) ? dartified : '';
}

/// Routes API ラウンドトリップ JSON 文字列
Future<String> getDirectionsRoundTrip(String requestJson) async {
  final jsResult = await _getDirectionsRoundTripJs(requestJson).toDart;
  final dartified = jsResult.dartify();
  if (dartified == null) {
    throw StateError('Routes API: JS から null が返されました');
  }
  return (dartified as String?) ?? '';
}
