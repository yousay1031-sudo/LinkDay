/// Google Maps JS Interop ブリッジ — 非 Web プラットフォーム用スタブ
///
/// VM（flutter test）/ Android では `dart:js_interop` が利用できないため、
/// 条件付きインポート（maps_bridge.dart）経由でこの実装が選ばれる。
///
/// 【なぜこの分割が必要か】
/// 以前は maps_js_service.dart / maps_loader.dart が `dart:js_interop` を
/// 直接インポートしていたため、`package:linkday_app` を import する
/// すべてのユニットテストが VM 上で以下のエラーで起動不能になっていた:
///   Error: Dart library 'dart:js_interop' is not available on this platform.
/// JS 依存をこのブリッジ層に閉じ込めることで、サービス層・モデル層を
/// VM テストから検証できるようにしている（file_saver.dart と同じ設計）。
library;

const String _msg = 'Google Maps JS Interop は Web プラットフォームでのみ利用できます';

/// Maps JS API をロードする（Web 専用）
Future<void> loadGoogleMaps(String apiKey) async {
  throw UnsupportedError(_msg);
}

/// 住所 → {lat, lng}（Web 専用）
Future<Map<String, dynamic>> geocodeAddress(String address) async {
  throw UnsupportedError(_msg);
}

/// 住所 → 候補一覧 JSON 文字列（Web 専用）
Future<String> geocodeCandidates(String address, int maxResults) async {
  throw UnsupportedError(_msg);
}

/// 緯度経度 → 住所 JSON 文字列（Web 専用）
Future<String> reverseGeocode(double lat, double lng) async {
  throw UnsupportedError(_msg);
}

/// Routes API ラウンドトリップ JSON 文字列（Web 専用）
Future<String> getDirectionsRoundTrip(String requestJson) async {
  throw UnsupportedError(_msg);
}
