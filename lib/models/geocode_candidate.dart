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

  // ── Day 8 修正: 自動採用の厳格化で使う粒度判定 ────────────────
  //
  // Geocoder は bounds を「バイアス」として扱うだけなので、短名クエリでは
  // 道外・県外や「日本」（国レベル重心）が 1 件目に来ることがある。
  // 自動採用の可否は以下 3 観点で判定する（transport_location_resolver 参照）:
  //   1. bounds 外か（isOutsideObihiroBounds）
  //   2. 国・行政区域レベルの粗い粒度か（isCountryLevel / hasPointGranularity）
  //   3. 部分一致か（partialMatch）

  /// 自動採用を許容する「地点レベル」の types
  ///
  /// 仕様: premise / park / transit_station / school / establishment /
  ///       street_address / route のいずれか（および同等の下位種別）を含むこと。
  static const Set<String> pointGranularityTypes = {
    // 建物・番地・通り
    'premise',
    'subpremise',
    'street_address',
    'route',
    'intersection',
    // 施設系
    'establishment',
    'point_of_interest',
    'park',
    'stadium',
    'hospital',
    'shopping_mall',
    'department_store',
    'store',
    // 駅・停留所
    'transit_station',
    'train_station',
    'bus_station',
    'subway_station',
    // 学校
    'school',
    'primary_school',
    'secondary_school',
    'university',
  };

  /// 行政区域・国レベル（＝粒度不足）の types
  static const Set<String> coarseTypes = {
    'country',
    'administrative_area_level_1',
    'administrative_area_level_2',
    'administrative_area_level_3',
    'locality',
    'sublocality',
    'sublocality_level_1',
    'sublocality_level_2',
    'sublocality_level_3',
    'sublocality_level_4',
    'neighborhood',
    'postal_code',
    'political',
  };

  /// 代表 type（ログ表示用。types が空なら 'unknown'）
  String get primaryType => types.isNotEmpty ? types.first : 'unknown';

  /// 粒度不足の原因となっている代表 type（ログ用: 例 'locality'）
  String get coarseType {
    for (final t in types) {
      if (coarseTypes.contains(t) && t != 'political') return t;
    }
    return primaryType;
  }

  /// 地点（建物・番地・施設・駅・学校・公園）レベルの粒度を持つか
  bool get hasPointGranularity =>
      types.any((t) => pointGranularityTypes.contains(t));

  /// 「日本」だけ等の国レベル結果か（絶対に保存してはいけない粒度）
  bool get isCountryLevel {
    if (types.contains('country')) return true;
    final a = formattedAddress.trim();
    return a == '日本' || a == 'Japan' || a == '日本国';
  }

  /// 行政区域（市町村・県）レベルのみで地点粒度を持たないか
  bool get isAdminAreaOnly => !hasPointGranularity;

  /// 自動採用候補としての優先スコア（大きいほど良い）
  ///
  /// 複数候補を提示する際、帯広市内かつ地点粒度の候補を先頭に並べるために使う。
  int get preferenceScore {
    int s = 0;
    if (!isOutsideObihiroBounds) s += 8;
    if (hasPointGranularity) s += 4;
    if (!isCountryLevel) s += 2;
    if (!partialMatch) s += 1;
    return s;
  }

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

  /// 帯広市内・地点粒度の候補を優先した並び（UI の選択リスト用）
  List<GeocodeCandidate> get sortedByPreference {
    final list = List<GeocodeCandidate>.from(candidates);
    list.sort((a, b) => b.preferenceScore.compareTo(a.preferenceScore));
    return list;
  }
}
