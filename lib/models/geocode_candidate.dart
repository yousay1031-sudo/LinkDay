/// Geocoding 候補（Day 8）
///
/// JS Interop 層（web/index.html の geocodeCandidates）から返される
/// 1 件分の結果。platform 非依存（テストで利用可能）。
class GeocodeCandidate {
  final String formattedAddress;
  final double lat;
  final double lng;
  final String? placeId;
  final List<String> types; // premise / park / transit_station 等
  final bool partialMatch;

  const GeocodeCandidate({
    required this.formattedAddress,
    required this.lat,
    required this.lng,
    this.placeId,
    this.types = const [],
    this.partialMatch = false,
  });

  /// 帯広エリア bounds（web/index.html の OBIHIRO_BOUNDS と同値）
  static const double boundsSouth = 42.61;
  static const double boundsWest = 142.90;
  static const double boundsNorth = 43.21;
  static const double boundsEast = 143.50;

  /// 帯広エリア矩形の外か（道外・遠方ヒットの警告用）
  bool get isOutsideObihiroBounds =>
      lat < boundsSouth || lat > boundsNorth || lng < boundsWest || lng > boundsEast;

  /// 種別の日本語ラベル（主要なもののみ。該当なしは先頭 type をそのまま）
  String get typeLabel {
    const map = <String, String>{
      'premise': '建物',
      'subpremise': '建物内',
      'street_address': '番地',
      'route': '通り',
      'intersection': '交差点',
      'park': '公園',
      'transit_station': '駅・停留所',
      'train_station': '駅',
      'bus_station': 'バス停',
      'school': '学校',
      'primary_school': '小学校',
      'secondary_school': '中学校',
      'shopping_mall': '商業施設',
      'department_store': '百貨店',
      'store': '店舗',
      'point_of_interest': '施設',
      'establishment': '施設',
      'locality': '市町村',
      'sublocality': '地区',
      'sublocality_level_1': '地区',
      'sublocality_level_2': '地区',
      'sublocality_level_3': '地区',
      'sublocality_level_4': '地区',
      'political': '行政区域',
      'postal_code': '郵便番号',
      'neighborhood': '地区',
      'natural_feature': '自然地形',
      'stadium': '運動施設',
      'hospital': '病院',
    };
    for (final t in types) {
      final l = map[t];
      if (l != null) return l;
    }
    return types.isNotEmpty ? types.first : '不明';
  }

  /// 地点（建物・番地・施設）レベルの精度か（行政区域レベルより細かい）
  bool get isPointLevel => types.any((t) => const {
        'premise',
        'subpremise',
        'street_address',
        'establishment',
        'point_of_interest',
        'park',
        'transit_station',
        'train_station',
        'bus_station',
        'school',
        'intersection',
      }.contains(t));

  factory GeocodeCandidate.fromJson(Map<String, dynamic> j) {
    return GeocodeCandidate(
      formattedAddress: (j['formattedAddress'] as String?) ?? '',
      lat: ((j['lat'] as num?) ?? 0).toDouble(),
      lng: ((j['lng'] as num?) ?? 0).toDouble(),
      placeId: j['placeId'] as String?,
      types: (j['types'] is List)
          ? (j['types'] as List).map((e) => e.toString()).toList()
          : const [],
      partialMatch: j['partialMatch'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'formattedAddress': formattedAddress,
        'lat': lat,
        'lng': lng,
        'placeId': placeId,
        'types': types,
        'partialMatch': partialMatch,
      };

  @override
  String toString() =>
      'GeocodeCandidate($formattedAddress, ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}, $typeLabel)';
}

/// 候補取得の結果まとめ
class GeocodeCandidatesResult {
  final String address;
  final List<GeocodeCandidate> candidates;

  const GeocodeCandidatesResult({required this.address, required this.candidates});

  bool get isEmpty => candidates.isEmpty;
  bool get isSingle => candidates.length == 1;
  bool get isMultiple => candidates.length > 1;
}
