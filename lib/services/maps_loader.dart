import 'package:flutter/foundation.dart';

import 'maps_bridge.dart' as bridge;

/// Google Maps JavaScript API ローダー
///
/// [ensureLoaded] を呼ぶと window.loadGoogleMaps(apiKey) を呼び出し、
/// Maps JS API が利用可能な状態にする。
/// 同じキーで複数回呼んでも重複ロードしない。
class MapsLoader {
  MapsLoader._();

  static bool _loaded = false;
  static String? _loadedKey;

  /// Google Maps JS API をロードする（冪等）
  ///
  /// 既に同じキーでロード済みなら即 return。
  /// [apiKey] が空の場合は例外をスロー。
  static Future<void> ensureLoaded(String apiKey) async {
    if (_loaded && _loadedKey == apiKey) return;
    if (apiKey.isEmpty) {
      throw Exception(
          'Google Maps API キーが設定されていません。設定画面で入力してください。');
    }
    try {
      debugPrint('[MapsLoader] Loading Google Maps JS API...');
      await bridge.loadGoogleMaps(apiKey);
      _loaded = true;
      _loadedKey = apiKey;
      debugPrint('[MapsLoader] Google Maps JS API loaded successfully');
    } catch (e) {
      _loaded = false;
      _loadedKey = null;
      debugPrint('[MapsLoader] Failed to load Google Maps JS API: $e');
      rethrow;
    }
  }

  /// ロード済みかどうか
  static bool get isLoaded => _loaded;

  /// ロード済みのキー
  static String? get loadedKey => _loadedKey;

  /// ロード状態をリセット（テスト用・キー変更時）
  static void reset() {
    _loaded = false;
    _loadedKey = null;
    debugPrint('[MapsLoader] reset');
  }
}
