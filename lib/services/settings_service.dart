import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import 'google_maps_service.dart';

const String _kBoxName = 'app_settings';
const String _kSettingsKey = 'settings';
const String _kApiKeyPref = 'google_maps_api_key';

/// 設定サービス
/// - AppSettings は Hive に保存（box: 'app_settings'）
/// - Google Maps API キーは SharedPreferences に保存（セキュリティ優先）
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

  // ── API キー管理（SharedPreferences） ────────────────────────

  /// APIキーを SharedPreferences に保存する
  Future<void> saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kApiKeyPref, key.trim());
    debugPrint('[SettingsService] API key saved');
  }

  /// APIキーを SharedPreferences から読み出す
  Future<String?> loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_kApiKeyPref);
    return (key != null && key.isNotEmpty) ? key : null;
  }

  /// APIキーをクリアする
  Future<void> clearApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kApiKeyPref);
    debugPrint('[SettingsService] API key cleared');
  }

  /// APIキーが設定済みかどうか
  Future<bool> hasApiKey() async {
    final key = await loadApiKey();
    return key != null && key.isNotEmpty;
  }

  // ── Geocoding ────────────────────────────────────────────────

  /// 事業所住所を Geocoding して座標を保存する
  /// 成功: LatLng を返す
  /// 失敗: 例外を throw
  Future<({double lat, double lng})> geocodeFacility() async {
    final key = await loadApiKey();
    if (key == null || key.isEmpty) {
      throw Exception('Google Maps API キーが設定されていません');
    }
    final settings = getSettings();
    final result = await GoogleMapsService.instance.geocodeAddress(
      settings.facilityAddress,
      key,
    );
    await saveFacilityGeocode(result.lat, result.lng);
    return result;
  }

  /// APIキーのテスト（事業所住所を Geocoding して成功かどうか確認）
  Future<ApiKeyStatus> testApiKey(String key) async {
    if (key.isEmpty) return ApiKeyStatus.notSet;
    try {
      final settings = getSettings();
      await GoogleMapsService.instance.geocodeAddress(
        settings.facilityAddress,
        key,
      );
      return ApiKeyStatus.valid;
    } catch (e) {
      debugPrint('[SettingsService] API key test failed: $e');
      return ApiKeyStatus.invalid;
    }
  }
}

/// API キーの状態
enum ApiKeyStatus {
  notSet,  // 未設定
  valid,   // 有効
  invalid, // 無効・エラー
}
