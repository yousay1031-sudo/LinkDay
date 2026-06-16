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
  })  : id = id ?? const Uuid().v4(),
        regularDays = regularDays ?? [],
        transportLocations = transportLocations ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

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
    );
  }
}
