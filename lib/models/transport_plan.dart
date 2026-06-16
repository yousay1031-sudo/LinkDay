import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'transport_plan.g.dart';

// ── TransportType ────────────────────────────────────────────
/// 送迎区分
/// Hive Type ID: 10
@HiveType(typeId: 10)
enum TransportType {
  @HiveField(0)
  pickup, // お迎え（利用者宅→事業所）

  @HiveField(1)
  dropoff, // お送り（事業所→利用者宅）
}

// ── TransportStop ────────────────────────────────────────────
/// ルート上の1停留所（利用者1名分）
/// Hive Type ID: 9
@HiveType(typeId: 9)
class TransportStop extends HiveObject {
  @HiveField(0)
  String customerId;

  @HiveField(1)
  String customerName; // スナップショット

  @HiveField(2)
  String address; // 送迎先住所

  @HiveField(3)
  double? lat;

  @HiveField(4)
  double? lng;

  @HiveField(5)
  int orderIndex; // ルート内の順番（0始まり）

  @HiveField(6)
  String? scheduledTime; // "HH:mm" 形式の予定時刻

  @HiveField(7)
  int? distanceFromPrevMeters; // 前停留所からの距離（m）

  @HiveField(8)
  int? durationFromPrevSeconds; // 前停留所からの所要時間（秒）

  @HiveField(9)
  String? note;

  TransportStop({
    required this.customerId,
    required this.customerName,
    required this.address,
    this.lat,
    this.lng,
    this.orderIndex = 0,
    this.scheduledTime,
    this.distanceFromPrevMeters,
    this.durationFromPrevSeconds,
    this.note,
  });

  /// 所要時間の表示ラベル
  String get durationLabel {
    if (durationFromPrevSeconds == null) return '';
    final minutes = durationFromPrevSeconds! ~/ 60;
    return '約$minutes分';
  }

  /// 距離の表示ラベル
  String get distanceLabel {
    if (distanceFromPrevMeters == null) return '';
    if (distanceFromPrevMeters! < 1000) {
      return '${distanceFromPrevMeters}m';
    }
    return '${(distanceFromPrevMeters! / 1000).toStringAsFixed(1)}km';
  }
}

// ── TransportVehicleRoute ─────────────────────────────────────
/// 1台の車のルート
/// Hive Type ID: 8
@HiveType(typeId: 8)
class TransportVehicleRoute extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String vehicleName; // "車両A"

  @HiveField(2)
  int vehicleIndex; // 0始まり

  @HiveField(3)
  TransportType transportType;

  @HiveField(4)
  String dateKey; // "2026-06-16"

  @HiveField(5)
  List<TransportStop> stops; // 順番に並んだ停留所リスト

  @HiveField(6)
  int capacity; // 乗車定員

  @HiveField(7)
  String? googleMapsUrl; // ドライバー用のGoogleマップURL

  @HiveField(8)
  int? totalDistanceMeters; // 総走行距離

  @HiveField(9)
  int? totalDurationSeconds; // 総所要時間

  @HiveField(10)
  DateTime? optimizedAt; // 最適化実行日時

  @HiveField(11)
  String? note;

  TransportVehicleRoute({
    String? id,
    required this.vehicleName,
    required this.vehicleIndex,
    required this.transportType,
    required this.dateKey,
    List<TransportStop>? stops,
    this.capacity = 5,
    this.googleMapsUrl,
    this.totalDistanceMeters,
    this.totalDurationSeconds,
    this.optimizedAt,
    this.note,
  })  : id = id ?? const Uuid().v4(),
        stops = stops ?? [];

  /// 総距離表示
  String get totalDistanceLabel {
    if (totalDistanceMeters == null) return '—';
    if (totalDistanceMeters! < 1000) return '${totalDistanceMeters}m';
    return '${(totalDistanceMeters! / 1000).toStringAsFixed(1)}km';
  }

  /// 総所要時間表示
  String get totalDurationLabel {
    if (totalDurationSeconds == null) return '—';
    final minutes = totalDurationSeconds! ~/ 60;
    if (minutes < 60) return '$minutes分';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '$h時間$m分';
  }

  /// 乗車人数
  int get passengerCount => stops.length;

  /// 満員かどうか
  bool get isFull => passengerCount >= capacity;

  /// 区分ラベル
  String get typeLabel =>
      transportType == TransportType.pickup ? 'お迎え' : 'お送り';
}

// ── LatLng helper ────────────────────────────────────────────
/// Geocoding 結果の LatLng（Hive 非管理の軽量クラス）
class LatLngPoint {
  final double lat;
  final double lng;
  const LatLngPoint(this.lat, this.lng);

  @override
  String toString() => '($lat, $lng)';
}
