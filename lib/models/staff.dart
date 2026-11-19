import '../data/audit.dart';

/// 職員（担当者選択用）
///
/// Firestore: facilities/{facilityId}/staff/{staffId}
/// 職員の登録・編集画面はステップ5（職員管理）で作る。ここでは名前と在籍のみ扱う。
class Staff {
  final String id;
  final String name;
  final bool isActive;
  final DateTime? deactivatedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? updatedByStaffId;
  final String? updatedByStaffName;

  /// 暗証番号（予約のみ。このステップでは常に null）。
  /// 職員ごとに持つ。平文は保存しない（ハッシュとソルトのみ）。
  final String? pinHash;
  final String? pinSalt;

  const Staff({
    required this.id,
    required this.name,
    this.isActive = true,
    this.deactivatedAt,
    this.createdAt,
    this.updatedAt,
    this.updatedByStaffId,
    this.updatedByStaffName,
    this.pinHash,
    this.pinSalt,
  });

  static const String fName = 'name';
  static const String fIsActive = 'isActive';
  static const String fDeactivatedAt = 'deactivatedAt';
  static const String fPinHash = 'pinHash';
  static const String fPinSalt = 'pinSalt';

  bool get hasPin => (pinHash ?? '').isNotEmpty;

  factory Staff.fromMap(String id, Map<String, dynamic> m) {
    return Staff(
      id: id,
      name: (m[fName] as String?)?.trim() ?? '',
      isActive: m[fIsActive] is bool ? m[fIsActive] as bool : true,
      deactivatedAt: readTimestamp(m[fDeactivatedAt]),
      createdAt: readTimestamp(m[AuditStamp.fCreatedAt]),
      updatedAt: readTimestamp(m[AuditStamp.fUpdatedAt]),
      updatedByStaffId: m[AuditStamp.fUpdatedByStaffId] as String?,
      updatedByStaffName: m[AuditStamp.fUpdatedByStaffName] as String?,
      pinHash: m[fPinHash] as String?,
      pinSalt: m[fPinSalt] as String?,
    );
  }

  /// 新規作成用（監査項目は呼び出し側で付ける）
  Map<String, dynamic> toCreateMap() => {
        fName: name,
        fIsActive: true,
        fDeactivatedAt: null,
        fPinHash: null,
        fPinSalt: null,
      };

  Staff copyWith({bool? isActive, DateTime? deactivatedAt}) => Staff(
        id: id,
        name: name,
        isActive: isActive ?? this.isActive,
        deactivatedAt: deactivatedAt ?? this.deactivatedAt,
        createdAt: createdAt,
        updatedAt: updatedAt,
        updatedByStaffId: updatedByStaffId,
        updatedByStaffName: updatedByStaffName,
        pinHash: pinHash,
        pinSalt: pinSalt,
      );

  @override
  String toString() => 'Staff($name, $id, active=$isActive)';
}
