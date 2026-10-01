import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'customer.g.dart';

/// 顧客（児童）モデル
/// Hive Type ID: 0
/// 将来 Firestore 同期する際は tenantId フィールドを追加してください
@HiveType(typeId: 0)
class Customer extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String name; // 氏名（必須）

  @HiveField(2)
  String nameKana; // ふりがな（カタカナで保存・必須）

  @HiveField(3)
  DateTime? birthday; // 生年月日

  @HiveField(4)
  String? gender; // 性別: '男児' / '女児'

  @HiveField(5)
  String? phone; // 電話番号

  @HiveField(6)
  String? lineUserId; // LINE通知用ID

  @HiveField(7)
  String? guardianName; // 保護者氏名

  @HiveField(8)
  String? guardianPhone; // 保護者電話番号

  @HiveField(9)
  String? recipientCertNumber; // 受給者証番号

  @HiveField(10)
  DateTime? recipientCertExpiry; // 受給者証有効期限

  @HiveField(11)
  int monthlyAvailableDays; // 月間支給量（デフォルト23）

  @HiveField(12)
  int currentMonthUsedDays; // 当月利用日数（デフォルト0）

  @HiveField(13)
  List<int> regularDays; // 定期利用曜日: 1=月, 2=火, 3=水, 4=木, 5=金, 6=土

  @HiveField(14)
  List<String> transportLocations; // 送迎場所（最大3箇所）

  @HiveField(15)
  String? notes; // 備考

  @HiveField(16)
  DateTime createdAt;

  @HiveField(17)
  DateTime updatedAt;

  @HiveField(18)
  bool isActive; // 在籍中フラグ（デフォルト true）

  // ── Day 8: 送迎場所ジオコーディング ─────────────────────────────
  // transportLocations[i] に対応。長さは transportLocations と同期させる。
  // Hive には primitive のみ保存（record 型はシリアライズ不可のため分割）。

  @HiveField(19)
  List<double?> transportLocationLats; // 採用済み緯度（未解決は null）

  @HiveField(20)
  List<double?> transportLocationLngs; // 採用済み経度（未解決は null）

  @HiveField(21)
  List<String> transportLocationStatus; // 'unresolved' / 'resolved' / 'manual' / 'failed'

  // ── Day 8 修正: 採用根拠メタデータ ───────────────────────────────
  // 誤ジオコード（「日本」・市全域重心・県外ヒット）の検出と一括解除のため、
  // 採用した候補の formattedAddress と types を保持する。
  // 旧データ（未保存）は null → 「根拠不明の自動採用」として扱う。

  @HiveField(22)
  List<String?> transportLocationFormatted; // 採用候補の formattedAddress

  @HiveField(23)
  List<String?> transportLocationTypes; // 採用候補の types（カンマ区切り）

  Customer({
    String? id,
    required this.name,
    required this.nameKana,
    this.birthday,
    this.gender,
    this.phone,
    this.lineUserId,
    this.guardianName,
    this.guardianPhone,
    this.recipientCertNumber,
    this.recipientCertExpiry,
    this.monthlyAvailableDays = 23,
    this.currentMonthUsedDays = 0,
    List<int>? regularDays,
    List<String>? transportLocations,
    this.notes,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isActive = true,
    List<double?>? transportLocationLats,
    List<double?>? transportLocationLngs,
    List<String>? transportLocationStatus,
    List<String?>? transportLocationFormatted,
    List<String?>? transportLocationTypes,
  })  : id = id ?? const Uuid().v4(),
        regularDays = regularDays ?? [],
        transportLocations = transportLocations ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        transportLocationLats = _alignNullable(
            transportLocationLats, (transportLocations ?? []).length),
        transportLocationLngs = _alignNullable(
            transportLocationLngs, (transportLocations ?? []).length),
        transportLocationStatus = _alignStatus(
            transportLocationStatus, (transportLocations ?? []).length),
        transportLocationFormatted = _alignStrings(
            transportLocationFormatted, (transportLocations ?? []).length),
        transportLocationTypes = _alignStrings(
            transportLocationTypes, (transportLocations ?? []).length);

  // ── Day 8: 座標ステータス定数 ──
  static const String locUnresolved = 'unresolved';
  static const String locResolved = 'resolved'; // 自動採用（候補1件）
  static const String locManual = 'manual'; // ユーザー選択/微調整
  static const String locFailed = 'failed';

  /// 長さを transportLocations に合わせる（旧データは null 埋め）
  static List<double?> _alignNullable(List<double?>? src, int n) {
    final out = List<double?>.filled(n, null, growable: true);
    if (src != null) {
      for (int i = 0; i < n && i < src.length; i++) {
        out[i] = src[i];
      }
    }
    return out;
  }

  static List<String?> _alignStrings(List<String?>? src, int n) {
    final out = List<String?>.filled(n, null, growable: true);
    if (src != null) {
      for (int i = 0; i < n && i < src.length; i++) {
        out[i] = src[i];
      }
    }
    return out;
  }

  static List<String> _alignStatus(List<String>? src, int n) {
    final out = List<String>.filled(n, locUnresolved, growable: true);
    if (src != null) {
      for (int i = 0; i < n && i < src.length; i++) {
        out[i] = src[i];
      }
    }
    return out;
  }

  /// 送迎場所 i の採用済み座標（未解決なら null）
  ({double lat, double lng})? transportCoord(int i) {
    if (i < 0 || i >= transportLocationLats.length || i >= transportLocationLngs.length) {
      return null;
    }
    final lat = transportLocationLats[i];
    final lng = transportLocationLngs[i];
    if (lat == null || lng == null) return null;
    return (lat: lat, lng: lng);
  }

  /// 送迎場所 i の解決状態
  String transportStatus(int i) =>
      (i >= 0 && i < transportLocationStatus.length)
          ? transportLocationStatus[i]
          : locUnresolved;

  /// 送迎場所 i が座標解決済み（resolved / manual かつ座標あり）か
  bool isTransportResolved(int i) {
    final st = transportStatus(i);
    return (st == locResolved || st == locManual) && transportCoord(i) != null;
  }

  /// 送迎場所 i の採用根拠（formattedAddress）。未記録なら null
  String? transportFormatted(int i) =>
      (i >= 0 && i < transportLocationFormatted.length)
          ? transportLocationFormatted[i]
          : null;

  /// 送迎場所 i の採用根拠 types（未記録なら空）
  List<String> transportTypes(int i) {
    final raw = (i >= 0 && i < transportLocationTypes.length)
        ? transportLocationTypes[i]
        : null;
    if (raw == null || raw.trim().isEmpty) return const [];
    return raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// 採用根拠メタデータが記録されているか（旧データは false）
  bool hasTransportMeta(int i) =>
      (transportFormatted(i) ?? '').trim().isNotEmpty || transportTypes(i).isNotEmpty;

  /// 送迎場所 i の座標を設定する（status 付き）
  ///
  /// [formatted] / [types] は採用した候補の根拠。地図微調整や解除では null を渡す。
  void setTransportCoord(
    int i,
    double? lat,
    double? lng,
    String status, {
    String? formatted,
    List<String>? types,
  }) {
    while (transportLocationLats.length <= i) {
      transportLocationLats.add(null);
    }
    while (transportLocationLngs.length <= i) {
      transportLocationLngs.add(null);
    }
    while (transportLocationStatus.length <= i) {
      transportLocationStatus.add(locUnresolved);
    }
    while (transportLocationFormatted.length <= i) {
      transportLocationFormatted.add(null);
    }
    while (transportLocationTypes.length <= i) {
      transportLocationTypes.add(null);
    }
    transportLocationLats[i] = lat;
    transportLocationLngs[i] = lng;
    transportLocationStatus[i] = status;
    transportLocationFormatted[i] = formatted;
    transportLocationTypes[i] = (types == null || types.isEmpty) ? null : types.join(',');
  }

  /// 月間残日数を返す
  int get remainingDays => monthlyAvailableDays - currentMonthUsedDays;

  /// 受給者証の残日数を返す（期限なしの場合 null）
  int? get certExpiryDaysLeft {
    if (recipientCertExpiry == null) return null;
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final expiryDate = DateTime(
      recipientCertExpiry!.year,
      recipientCertExpiry!.month,
      recipientCertExpiry!.day,
    );
    return expiryDate.difference(todayDate).inDays;
  }

  /// 受給者証が期限切れかどうか
  bool get isCertExpired {
    final days = certExpiryDaysLeft;
    return days != null && days < 0;
  }

  /// 定期利用曜日を文字列リストで返す（例: ['月', '水', '金']）
  List<String> get regularDayLabels {
    const labels = {1: '月', 2: '火', 3: '水', 4: '木', 5: '金', 6: '土'};
    return regularDays.map((d) => labels[d] ?? '').where((s) => s.isNotEmpty).toList();
  }

  /// 編集用にコピーを作成（updatedAt を現在時刻に更新）
  Customer copyWith({
    String? name,
    String? nameKana,
    DateTime? birthday,
    String? gender,
    String? phone,
    String? lineUserId,
    String? guardianName,
    String? guardianPhone,
    String? recipientCertNumber,
    DateTime? recipientCertExpiry,
    int? monthlyAvailableDays,
    int? currentMonthUsedDays,
    List<int>? regularDays,
    List<String>? transportLocations,
    String? notes,
    bool? isActive,
    List<double?>? transportLocationLats,
    List<double?>? transportLocationLngs,
    List<String>? transportLocationStatus,
    List<String?>? transportLocationFormatted,
    List<String?>? transportLocationTypes,
  }) {
    return Customer(
      id: id,
      name: name ?? this.name,
      nameKana: nameKana ?? this.nameKana,
      birthday: birthday ?? this.birthday,
      gender: gender ?? this.gender,
      phone: phone ?? this.phone,
      lineUserId: lineUserId ?? this.lineUserId,
      guardianName: guardianName ?? this.guardianName,
      guardianPhone: guardianPhone ?? this.guardianPhone,
      recipientCertNumber: recipientCertNumber ?? this.recipientCertNumber,
      recipientCertExpiry: recipientCertExpiry ?? this.recipientCertExpiry,
      monthlyAvailableDays: monthlyAvailableDays ?? this.monthlyAvailableDays,
      currentMonthUsedDays: currentMonthUsedDays ?? this.currentMonthUsedDays,
      regularDays: regularDays ?? List.from(this.regularDays),
      transportLocations: transportLocations ?? List.from(this.transportLocations),
      notes: notes ?? this.notes,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      isActive: isActive ?? this.isActive,
      transportLocationLats:
          transportLocationLats ?? List<double?>.from(this.transportLocationLats),
      transportLocationLngs:
          transportLocationLngs ?? List<double?>.from(this.transportLocationLngs),
      transportLocationStatus:
          transportLocationStatus ?? List<String>.from(this.transportLocationStatus),
      transportLocationFormatted: transportLocationFormatted ??
          List<String?>.from(this.transportLocationFormatted),
      transportLocationTypes:
          transportLocationTypes ?? List<String?>.from(this.transportLocationTypes),
    );
  }
}
