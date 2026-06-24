import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import 'maps_js_service.dart';
import 'maps_loader.dart';

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

  // ── REST API キー（後方互換エイリアス）──────────────────────
  // RESTキー方式は廃止。内部的に JS キーに委譲する。

  /// @deprecated JSキー方式に統一。内部的に saveJsApiKey() を呼ぶ
  Future<void> saveRestApiKey(String key) => saveJsApiKey(key);

  /// @deprecated JSキー方式に統一。内部的に loadJsApiKey() を呼ぶ
  Future<String?> loadRestApiKey() => loadJsApiKey();

  /// @deprecated JSキー方式に統一。内部的に clearJsApiKey() を呼ぶ
  Future<void> clearRestApiKey() => clearJsApiKey();

  /// @deprecated JSキー方式に統一。内部的に hasJsApiKey() を呼ぶ
  Future<bool> hasRestApiKey() => hasJsApiKey();

  // ── 後方互換: 旧 loadApiKey / saveApiKey ────────────────────
  // すべて loadJsApiKey / saveJsApiKey に委譲

  /// @deprecated 代わりに loadJsApiKey() を使ってください
  Future<String?> loadApiKey() => loadJsApiKey();

  /// @deprecated 代わりに saveJsApiKey() を使ってください
  Future<void> saveApiKey(String key) => saveJsApiKey(key);

  /// @deprecated 代わりに clearJsApiKey() を使ってください
  Future<void> clearApiKey() => clearJsApiKey();

  /// @deprecated 代わりに hasJsApiKey() を使ってください
  Future<bool> hasApiKey() => hasJsApiKey();

  // ── Geocoding ────────────────────────────────────────────────

  /// Geocoding 用住所の正規化
  ///
  /// - 郵便番号（〒xxx-xxxx または xxx-xxxx）を除去
  /// - 階数情報（x階 / xF / x階部分）を除去（建物全体のマッチング向上）
  /// - 前後空白を除去
  /// - 表示用住所は元の文字列を維持
  static String normalizeAddressForGeocode(String address) {
    var normalized = address.trim();

    // 郵便番号除去: 〒080-0015 / 080-0015
    normalized = normalized.replaceAll(RegExp(r'〒?\d{3}-\d{4}\s*'), '');

    // 階数情報除去: " 2階" / " 2F" / " B1F" など（数字+階 or F）
    // スペースが前に付くパターンを優先除去
    normalized = normalized.replaceAll(
        RegExp(r'\s+[Bb]?\d+[Ff階]\s*$'), '');
    normalized = normalized.replaceAll(
        RegExp(r'\s+[Bb]?\d+[Ff階][^\s]*\s*$'), '');

    // 号室表示除去: " 201号室" / " 101"（末尾の数字のみのパターン）
    normalized = normalized.replaceAll(RegExp(r'\s+\d+号室\s*$'), '');

    // 前後空白除去
    normalized = normalized.trim();

    debugPrint('[SettingsService] normalizeAddress: "$address" → "$normalized"');
    return normalized;
  }

  /// 事業所住所を Geocoding して座標を保存する（JS Interop 版）
  ///
  /// - 住所文字列を正規化してから geocode する
  /// - 成功時は必ず Hive に上書き保存する
  /// - [address] を指定すると Hive の facilityAddress より優先する
  Future<({double lat, double lng})> geocodeFacility({
    String? address,
  }) async {
    final key = await loadJsApiKey();
    if (key == null || key.isEmpty) {
      throw Exception('Google Maps API キーが設定されていません。設定画面で入力してください。');
    }
    final settings = getSettings();
    final rawAddress = address ?? settings.facilityAddress;

    // 住所を正規化（階数・郵便番号除去）
    final geocodeAddress = normalizeAddressForGeocode(rawAddress);
    if (geocodeAddress.isEmpty) {
      throw Exception('住所が空です。設定画面で住所を入力してください。');
    }

    debugPrint('[SettingsService] geocodeFacility: '
        'raw="$rawAddress" → normalized="$geocodeAddress"');

    // JS Interop 経由で Geocoder を呼ぶ
    final result = await MapsJsService.instance.geocodeAddress(geocodeAddress);

    debugPrint('[SettingsService] geocodeFacility result: '
        'lat=${result.lat}, lng=${result.lng} '
        '(address="$geocodeAddress")');

    // 必ず上書き保存（旧座標を確実に更新）
    await saveFacilityGeocode(result.lat, result.lng);

    return (lat: result.lat, lng: result.lng);
  }

  /// 緯度経度を手動で保存する（地図上でマーカーをドラッグ後に呼ぶ）
  Future<void> saveFacilityLatLng(double lat, double lng) async {
    await saveFacilityGeocode(lat, lng);
    debugPrint('[SettingsService] saveFacilityLatLng: '
        'lat=${lat.toStringAsFixed(7)}, lng=${lng.toStringAsFixed(7)}');
  }

  // ── テスト ────────────────────────────────────────────────────

  /// API キーのテスト（MapsLoader でロード → Geocoder で事業所住所を変換）
  Future<ApiKeyStatus> testJsApiKey(String key) async {
    if (key.isEmpty) return ApiKeyStatus.notSet;
    try {
      // 1. Maps JS API をロード
      MapsLoader.reset(); // キー変更を反映するためリセット
      await MapsLoader.ensureLoaded(key);

      // 2. Geocoder で事業所住所を変換して有効性を確認
      final settings = getSettings();
      await MapsJsService.instance.geocodeAddress(settings.facilityAddress);

      debugPrint('[SettingsService] JS API key test succeeded');
      return ApiKeyStatus.valid;
    } catch (e) {
      debugPrint('[SettingsService] JS API key test failed: $e');
      return ApiKeyStatus.invalid;
    }
  }

  /// @deprecated 代わりに testJsApiKey() を使ってください
  Future<ApiKeyStatus> testRestApiKey(String key) => testJsApiKey(key);

  /// @deprecated 代わりに testJsApiKey() を使ってください
  Future<ApiKeyStatus> testApiKey(String key) => testJsApiKey(key);
}

/// API キーの状態
enum ApiKeyStatus {
  notSet,   // 未設定
  valid,    // 有効（または形式OK）
  invalid,  // 無効・エラー
}

