/// Google Maps JS Interop ブリッジ（プラットフォーム条件付きインポート）
///
/// Web では maps_bridge_web.dart（dart:js_interop 実装）、
/// VM / Android では maps_bridge_stub.dart（UnsupportedError）が選ばれる。
///
/// 【設計意図】
/// `dart:js_interop` は VM では利用できないため、直接インポートすると
/// `package:linkday_app` を参照するすべてのユニットテストが
/// 「Dart library 'dart:js_interop' is not available on this platform」で
/// 起動不能になる。JS 依存をこのブリッジ層に隔離することで、
/// サービス層・モデル層を `flutter test`（VM）で検証できるようにしている。
/// 同じ設計は lib/utils/file_saver.dart でも採用している。
library;

import 'maps_bridge_stub.dart'
    if (dart.library.js_interop) 'maps_bridge_web.dart' as impl;

/// Maps JS API をロードする（非 Web では UnsupportedError）
Future<void> loadGoogleMaps(String apiKey) => impl.loadGoogleMaps(apiKey);

/// 住所 → {lat, lng}
Future<Map<String, dynamic>> geocodeAddress(String address) =>
    impl.geocodeAddress(address);

/// 住所 → 候補一覧 JSON 文字列
Future<String> geocodeCandidates(String address, int maxResults) =>
    impl.geocodeCandidates(address, maxResults);

/// 緯度経度 → 住所 JSON 文字列
Future<String> reverseGeocode(double lat, double lng) =>
    impl.reverseGeocode(lat, lng);

/// Routes API ラウンドトリップ JSON 文字列
Future<String> getDirectionsRoundTrip(String requestJson) =>
    impl.getDirectionsRoundTrip(requestJson);
