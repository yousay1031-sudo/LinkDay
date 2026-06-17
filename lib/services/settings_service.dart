import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import 'google_maps_service.dart';

const String _kBoxName = 'app_settings';
const String _kSettingsKey = 'settings';

// ── SharedPreferences キー ────────────────────────────────────
/// 旧キー（1キー方式）— マイグレーション用
const String _kLegacyApiKeyPref = 'google_maps_api_key';

/// Maps JavaScript API キー（地図表示用、リファラー制限 OK）
const String _kJsApiKeyPref = 'gmaps_js_key';

/// Maps REST API キー（Geocoding/Directions/DistanceMatrix 用、制限なし or IP制限）
const String _kRestApiKeyPref = 'gmaps_rest_key';

/// 設定サービス
/// - AppSettings は Hive に保存（box: 'app_settings'）
/// - Google Maps API キーは SharedPreferences に保存（セキュリティ優先）
///
/// 【2キー方式】
/// - JS API キー  : Maps JavaScript API（地図表示） → リファラー制限 OK
/// - REST API キー: Geocoding / Directions / Distance Matrix → 制限なし or IP制限
class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  late Box<AppSettings> _box;

  // ── 初期化 ──────────────────────────────────────────────────

  Future<void> init() async {
    _box = await Hive.openBox<AppSettings>(_kBoxName);
    // 初回起動時: デフォルト AppSettings を生成
    if (!_box.containsKey(_kSettingsKey)) {
      await _box.put(_kSettingsKey, AppSettings());
      debugPrint('[SettingsService] initialized with defaults');
    } else {
      debugPrint('[SettingsService] loaded existing settings');
    }
    // 旧キー（1キー方式）からのマイグレーション
    await _migrateLegacyApiKey();
  }

  /// 旧 'google_maps_api_key' が残っている場合、
  /// JS キーと REST キーの両方に複製してから旧キーを削除する
  Future<void> _migrateLegacyApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_kLegacyApiKeyPref);
    if (legacy == null || legacy.isEmpty) return;

    final jsKey = prefs.getString(_kJsApiKeyPref);
    final restKey = prefs.getString(_kRestApiKeyPref);

    // 新キーがまだ未設定の場合だけコピー
    if ((jsKey == null || jsKey.isEmpty)) {
      await prefs.setString(_kJsApiKeyPref, legacy);
      debugPrint('[SettingsService] migrated legacy key → JS key');
    }
    if ((restKey == null || restKey.isEmpty)) {
      await prefs.setString(_kRestApiKeyPref, legacy);
      debugPrint('[SettingsService] migrated legacy key → REST key');
    }

    // 旧キーを削除
    await prefs.remove(_kLegacyApiKeyPref);
    debugPrint('[SettingsService] legacy API key removed');
  }

  // ── 取得 ────────────────────────────────────────────────────

  /// 現在の設定を返す（なければデフォルト）
  AppSettings getSettings() {
    return _box.get(_kSettingsKey) ?? AppSettings();
  }

  // ── 更新メソッド ─────────────────────────────────────────────

  /// 事業所情報を更新する
  /// 住所が変わった場合は緯度経度をクリアする
  Future<void> updateFacility(String name, String address) async {
    final current = getSettings();
    final addressChanged = current.facilityAddress != address;
    final updated = AppSettings(
      facilityName: name,
      facilityAddress: address,
      // 住所変更時は Geocoding キャッシュをクリア
      facilityLat: addressChanged ? null : current.facilityLat,
      facilityLng: addressChanged ? null : current.facilityLng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
    );
    await _box.put(_kSettingsKey, updated);
    debugPrint('[SettingsService] facility updated: $name');
  }

  /// 車両設定を更新する
  Future<void> updateVehicles(
    int count,
    List<String> names,
    List<int> capacities,
  ) async {
    final current = getSettings();
    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: current.facilityLat,
      facilityLng: current.facilityLng,
      vehicleCount: count,
      vehicleNames: names,
      vehicleCapacities: capacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
    );
    await _box.put(_kSettingsKey, updated);
    debugPrint('[SettingsService] vehicles updated: count=$count');
  }

  /// 運営時間・最大利用者数を更新する
  Future<void> updateOperatingHours(
    String pickupStart,
    String dropoffEnd,
    int maxStudents,
  ) async {
    final current = getSettings();
    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: current.facilityLat,
      facilityLng: current.facilityLng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: maxStudents,
      defaultPickupStart: pickupStart,
      defaultDropoffEnd: dropoffEnd,
    );
    await _box.put(_kSettingsKey, updated);
    debugPrint('[SettingsService] operating hours updated');
  }

  /// Geocoding 結果をキャッシュとして保存する
  Future<void> saveFacilityGeocode(double lat, double lng) async {
    final current = getSettings();
    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: lat,
      facilityLng: lng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
    );
    await _box.put(_kSettingsKey, updated);
    debugPrint('[SettingsService] geocode saved: $lat, $lng');
  }

  // ── 2キー方式: JS API キー ───────────────────────────────────

  /// Maps JavaScript API キーを保存（地図表示用）
  Future<void> saveJsApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kJsApiKeyPref, key.trim());
    debugPrint('[SettingsService] JS API key saved');
  }

  /// Maps JavaScript API キーを読み出す
  Future<String?> loadJsApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_kJsApiKeyPref);
    return (key != null && key.isNotEmpty) ? key : null;
  }

  /// Maps JavaScript API キーをクリア
  Future<void> clearJsApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kJsApiKeyPref);
    debugPrint('[SettingsService] JS API key cleared');
  }

  /// Maps JavaScript API キーが設定済みか
  Future<bool> hasJsApiKey() async {
    final key = await loadJsApiKey();
    return key != null && key.isNotEmpty;
  }

  // ── 2キー方式: REST API キー ─────────────────────────────────

  /// REST API キーを保存（Geocoding/Directions/DistanceMatrix 用）
  Future<void> saveRestApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRestApiKeyPref, key.trim());
    debugPrint('[SettingsService] REST API key saved');
  }

  /// REST API キーを読み出す
  Future<String?> loadRestApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_kRestApiKeyPref);
    return (key != null && key.isNotEmpty) ? key : null;
  }

  /// REST API キーをクリア
  Future<void> clearRestApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRestApiKeyPref);
    debugPrint('[SettingsService] REST API key cleared');
  }

  /// REST API キーが設定済みか
  Future<bool> hasRestApiKey() async {
    final key = await loadRestApiKey();
    return key != null && key.isNotEmpty;
  }

  // ── 後方互換: 旧 loadApiKey / saveApiKey ────────────────────
  // transport_screen.dart 等の呼び出し元が使う旧インターフェース。
  // REST キーを返す/保存するように委譲する。

  /// @deprecated 代わりに loadRestApiKey() を使ってください
  Future<String?> loadApiKey() => loadRestApiKey();

  /// @deprecated 代わりに saveRestApiKey() を使ってください
  Future<void> saveApiKey(String key) => saveRestApiKey(key);

  /// @deprecated 代わりに clearRestApiKey() を使ってください
  Future<void> clearApiKey() => clearRestApiKey();

  /// @deprecated 代わりに hasRestApiKey() を使ってください
  Future<bool> hasApiKey() => hasRestApiKey();

  // ── Geocoding ────────────────────────────────────────────────

  /// 事業所住所を Geocoding して座標を保存する（REST API キー使用）
  Future<({double lat, double lng})> geocodeFacility() async {
    final key = await loadRestApiKey();
    if (key == null || key.isEmpty) {
      throw Exception('REST API キー（ルート計算用）が設定されていません');
    }
    final settings = getSettings();
    final result = await GoogleMapsService.instance.geocodeAddress(
      settings.facilityAddress,
      key,
    );
    await saveFacilityGeocode(result.lat, result.lng);
    return result;
  }

  // ── テスト ────────────────────────────────────────────────────

  /// REST API キーのテスト（Geocoding API を呼んで成功か確認）
  Future<ApiKeyStatus> testRestApiKey(String key) async {
    if (key.isEmpty) return ApiKeyStatus.notSet;
    try {
      final settings = getSettings();
      await GoogleMapsService.instance.geocodeAddress(
        settings.facilityAddress,
        key,
      );
      return ApiKeyStatus.valid;
    } catch (e) {
      debugPrint('[SettingsService] REST API key test failed: $e');
      return ApiKeyStatus.invalid;
    }
  }

  /// JS API キーのテスト（Maps JavaScript API のロード URL に疎通確認）
  /// Web では実際のロードで確認するため、ここでは簡易フォーマット確認のみ
  Future<ApiKeyStatus> testJsApiKey(String key) async {
    if (key.isEmpty) return ApiKeyStatus.notSet;
    // JS キーは "AIza" で始まる39文字の形式チェックのみ（REST呼び出し不可）
    if (key.startsWith('AIza') && key.length >= 35) {
      return ApiKeyStatus.valid;
    }
    return ApiKeyStatus.invalid;
  }

  /// @deprecated 代わりに testRestApiKey() を使ってください
  Future<ApiKeyStatus> testApiKey(String key) => testRestApiKey(key);
}

/// API キーの状態
enum ApiKeyStatus {
  notSet,   // 未設定
  valid,    // 有効（または形式OK）
  invalid,  // 無効・エラー
}
