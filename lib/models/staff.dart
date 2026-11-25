import '../data/audit.dart';
import '../data/fs_values.dart';

/// 職員の役割（Firestore には [code] を保存する）
enum StaffRole {
  childDevManager('childDevManager', '児童発達支援管理責任者'),
  childInstructor('childInstructor', '児童指導員'),
  nurseryTeacher('nurseryTeacher', '保育士'),
  instructor('instructor', '指導員'),
  driver('driver', '運転手'),
  other('other', 'その他');

  const StaffRole(this.code, this.label);
  final String code;
  final String label;

  static StaffRole? fromCode(Object? code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// 一覧に出す「ログインの状態」
enum StaffLoginStatus {
  /// Google メールアドレスが登録されていない
  none('未登録'),

  /// 登録済みでログインを許可
  allowed('許可'),

  /// 登録済みだがログインを停止
  stopped('停止');

  const StaffLoginStatus(this.label);
  final String label;
}

/// 職員
///
/// Firestore: facilities/{facilityId}/staff/{staffId}（事業所に所属する全員が読める）
/// - 氏名・ふりがな・役割・資格・勤務日・送迎の可否: 担当者を選んだ人なら誰でも編集できる
/// - 在籍・管理者・ログインの許可・メールアドレスの有無: 管理者だけが変えられる
///   （firestore.rules で管理者以外からの変更を拒否する）
/// - Google メールアドレスそのものは個人情報のため、管理者だけが読める
///   facilities/{facilityId}/staffAccounts/{staffId} に分けて置く。
class Staff {
  final String id;
  final String name;
  final String kana;
  final StaffRole? role;
  final String qualifications;

  /// 勤務日（1=月 … 7=日、昇順）
  final List<int> workDays;
  final bool canDrive;

  final bool isActive;
  final DateTime? deactivatedAt;

  /// 管理者（アカウントに関わる操作ができる）
  final bool isAdmin;

  /// 個人アカウント（Google）でのログインを許可するか
  final bool loginEnabled;

  /// Google メールアドレスが登録されているか（アドレス本体は staffAccounts）
  final bool hasGoogleEmail;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? updatedByStaffId;
  final String? updatedByStaffName;

  /// 暗証番号（予約のみ。常に null）。
  /// 職員ごとに持つ。平文は保存しない（ハッシュとソルトのみ）。
  final String? pinHash;
  final String? pinSalt;

  const Staff({
    required this.id,
    required this.name,
    this.kana = '',
    this.role,
    this.qualifications = '',
    this.workDays = const [],
    this.canDrive = false,
    this.isActive = true,
    this.deactivatedAt,
    this.isAdmin = false,
    this.loginEnabled = false,
    this.hasGoogleEmail = false,
    this.createdAt,
    this.updatedAt,
    this.updatedByStaffId,
    this.updatedByStaffName,
    this.pinHash,
    this.pinSalt,
  });

  static const String fName = 'name';
  static const String fKana = 'kana';
  static const String fRole = 'role';
  static const String fQualifications = 'qualifications';
  static const String fWorkDays = 'workDays';
  static const String fCanDrive = 'canDrive';
  static const String fIsActive = 'isActive';
  static const String fDeactivatedAt = 'deactivatedAt';
  static const String fIsAdmin = 'isAdmin';
  static const String fLoginEnabled = 'loginEnabled';
  static const String fHasGoogleEmail = 'hasGoogleEmail';
  static const String fPinHash = 'pinHash';
  static const String fPinSalt = 'pinSalt';

  /// 管理者を減らす書き込みに付ける「残る別の管理者」の職員 ID（ルールで確かめる）
  static const String fOtherAdminId = 'otherAdminId';

  /// 管理者だけが変えられる項目（firestore.rules と一致させる）
  static const List<String> protectedFields = [
    fIsActive,
    fDeactivatedAt,
    fIsAdmin,
    fLoginEnabled,
    fHasGoogleEmail,
    fPinHash,
    fPinSalt,
    fOtherAdminId,
  ];

  /// 曜日の表示（1=月 … 7=日）
  static const List<String> weekdayLabels = ['月', '火', '水', '木', '金', '土', '日'];

  bool get hasPin => (pinHash ?? '').isNotEmpty;

  /// 管理者として働ける（在籍中・管理者・ログイン許可）
  bool get isEffectiveAdmin => isActive && isAdmin && loginEnabled;

  StaffLoginStatus get loginStatus => !hasGoogleEmail
      ? StaffLoginStatus.none
      : loginEnabled
          ? StaffLoginStatus.allowed
          : StaffLoginStatus.stopped;

  String get workDaysLabel => [
        for (final d in workDays)
          if (d >= 1 && d <= 7) weekdayLabels[d - 1]
      ].join('・');

  static List<int> normalizeDays(Iterable<int> days) => ({
        for (final d in days)
          if (d >= 1 && d <= 7) d
      }.toList()
        ..sort());

  factory Staff.fromMap(String id, Map<String, dynamic> m) {
    bool b(String k, bool fallback) => m[k] is bool ? m[k] as bool : fallback;
    return Staff(
      id: id,
      name: (m[fName] as String?)?.trim() ?? '',
      kana: readString(m[fKana])?.trim() ?? '',
      role: StaffRole.fromCode(m[fRole]),
      qualifications: readString(m[fQualifications]) ?? '',
      workDays: normalizeDays(readIntList(m[fWorkDays])),
      canDrive: b(fCanDrive, false),
      isActive: b(fIsActive, true),
      deactivatedAt: readTimestamp(m[fDeactivatedAt]),
      isAdmin: b(fIsAdmin, false),
      loginEnabled: b(fLoginEnabled, false),
      hasGoogleEmail: b(fHasGoogleEmail, false),
      createdAt: readTimestamp(m[AuditStamp.fCreatedAt]),
      updatedAt: readTimestamp(m[AuditStamp.fUpdatedAt]),
      updatedByStaffId: m[AuditStamp.fUpdatedByStaffId] as String?,
      updatedByStaffName: m[AuditStamp.fUpdatedByStaffName] as String?,
      pinHash: m[fPinHash] as String?,
      pinSalt: m[fPinSalt] as String?,
    );
  }

  /// 誰でも編集できる項目（氏名・ふりがな・役割・資格・勤務日・送迎の可否）
  Map<String, dynamic> toProfileMap() => {
        fName: name.trim(),
        fKana: kana.trim(),
        fRole: role?.code,
        fQualifications: qualifications.trim(),
        fWorkDays: normalizeDays(workDays),
        fCanDrive: canDrive,
      };

  /// 新規作成用（監査項目は呼び出し側で付ける）
  Map<String, dynamic> toCreateMap() => {
        ...toProfileMap(),
        fIsActive: true,
        fDeactivatedAt: null,
        fIsAdmin: isAdmin,
        fLoginEnabled: loginEnabled,
        fHasGoogleEmail: hasGoogleEmail,
        fPinHash: null,
        fPinSalt: null,
      };

  /// 自分の書き込みの折り返しを見分けるための比較用（時刻・担当者の記録は除く）
  Map<String, dynamic> toComparable() => {
        ...toProfileMap(),
        fIsActive: isActive,
        fIsAdmin: isAdmin,
        fLoginEnabled: loginEnabled,
        fHasGoogleEmail: hasGoogleEmail,
      };

  Staff copyWith({
    String? name,
    String? kana,
    StaffRole? role,
    bool clearRole = false,
    String? qualifications,
    List<int>? workDays,
    bool? canDrive,
    bool? isActive,
    DateTime? deactivatedAt,
    bool clearDeactivatedAt = false,
    bool? isAdmin,
    bool? loginEnabled,
    bool? hasGoogleEmail,
  }) =>
      Staff(
        id: id,
        name: name ?? this.name,
        kana: kana ?? this.kana,
        role: clearRole ? null : (role ?? this.role),
        qualifications: qualifications ?? this.qualifications,
        workDays: workDays ?? this.workDays,
        canDrive: canDrive ?? this.canDrive,
        isActive: isActive ?? this.isActive,
        deactivatedAt:
            clearDeactivatedAt ? null : (deactivatedAt ?? this.deactivatedAt),
        isAdmin: isAdmin ?? this.isAdmin,
        loginEnabled: loginEnabled ?? this.loginEnabled,
        hasGoogleEmail: hasGoogleEmail ?? this.hasGoogleEmail,
        createdAt: createdAt,
        updatedAt: updatedAt,
        updatedByStaffId: updatedByStaffId,
        updatedByStaffName: updatedByStaffName,
        pinHash: pinHash,
        pinSalt: pinSalt,
      );

  @override
  String toString() => 'Staff($name, $id, active=$isActive, admin=$isAdmin)';
}
