import 'package:hive/hive.dart';

part 'app_settings.g.dart';

/// アプリ設定モデル
/// Hive Type ID: 7
/// box: 'app_settings'  key: 'settings'
@HiveType(typeId: 7)
class AppSettings extends HiveObject {
  @HiveField(0)
  String facilityName;

  @HiveField(1)
  String facilityAddress;

  @HiveField(2)
  double? facilityLat; // Geocoding 結果キャッシュ

  @HiveField(3)
  double? facilityLng;

  @HiveField(4)
  int vehicleCount; // 1〜5

  @HiveField(5)
  List<String> vehicleNames; // ["車両A", "車両B", ...]

  @HiveField(6)
  List<int> vehicleCapacities; // [5, 5, ...]（人数）

  @HiveField(7)
  int maxStudentsPerDay; // 1日最大利用者数

  @HiveField(8)
  String defaultPickupStart; // "08:30"

  @HiveField(9)
  String defaultDropoffEnd; // "16:30"

  @HiveField(10)
  DateTime updatedAt;

  // ── Day 6 patch: 2キー方式 ───────────────────────────────────
  // field 11/12 はオプション追加なので既存データには影響しない（null 扱い）

  /// Maps JavaScript API 用キー（リファラー制限 OK）
  /// Hive には保存せず SharedPreferences に移動したため、
  /// このフィールドは互換のみ保持（常に null）
  @HiveField(11)
  String? jsApiKeyLegacy; // reserved / unused

  /// REST API 用キー legacy storage（SharedPreferences に移行済み）
  @HiveField(12)
  String? restApiKeyLegacy; // reserved / unused

  AppSettings({
    this.facilityName = 'ココスタディ',
    this.facilityAddress = '北海道帯広市西5条南21丁目8 2階',
    this.facilityLat,
    this.facilityLng,
    this.vehicleCount = 2,
    List<String>? vehicleNames,
    List<int>? vehicleCapacities,
    this.maxStudentsPerDay = 10,
    this.defaultPickupStart = '08:30',
    this.defaultDropoffEnd = '16:30',
    DateTime? updatedAt,
    this.jsApiKeyLegacy,
    this.restApiKeyLegacy,
  })  : vehicleNames = vehicleNames ?? ['車両A', '車両B'],
        vehicleCapacities = vehicleCapacities ?? [5, 5],
        updatedAt = updatedAt ?? DateTime.now();

  /// 車両台数に合わせてリストの長さを調整したコピーを返す
  AppSettings adjustedForVehicleCount(int count) {
    final names = List<String>.generate(count, (i) {
      if (i < vehicleNames.length) return vehicleNames[i];
      return '車両${String.fromCharCode(65 + i)}'; // A, B, C...
    });
    final caps = List<int>.generate(count, (i) {
      if (i < vehicleCapacities.length) return vehicleCapacities[i];
      return 5;
    });
    return AppSettings(
      facilityName: facilityName,
      facilityAddress: facilityAddress,
      facilityLat: facilityLat,
      facilityLng: facilityLng,
      vehicleCount: count,
      vehicleNames: names,
      vehicleCapacities: caps,
      maxStudentsPerDay: maxStudentsPerDay,
      defaultPickupStart: defaultPickupStart,
      defaultDropoffEnd: defaultDropoffEnd,
    );
  }


  /// 事業所の緯度経度が取得済みかどうか
  bool get hasGeocode => facilityLat != null && facilityLng != null;

  /// 座標文字列（デバッグ・表示用）
  String get geocodeLabel {
    if (!hasGeocode) return '未取得';
    return '${facilityLat!.toStringAsFixed(6)}, ${facilityLng!.toStringAsFixed(6)}';
  }
}
