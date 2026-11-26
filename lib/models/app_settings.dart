
import '../data/audit.dart' show readTimestamp;
import '../data/fs_values.dart';

/// アプリ設定モデル
/// box: 'app_settings'  key: 'settings'
class AppSettings {
  String facilityName;

  String facilityAddress;

  double? facilityLat; // Geocoding 結果キャッシュ

  double? facilityLng;

  int vehicleCount; // 1〜5

  List<String> vehicleNames; // ["車両A", "車両B", ...]

  List<int> vehicleCapacities; // [5, 5, ...]（人数）

  int maxStudentsPerDay; // 1日最大利用者数

  String defaultPickupStart; // "08:30"

  String defaultDropoffEnd; // "16:30"

  DateTime updatedAt;

  // ── Day 6 patch: 2キー方式 ───────────────────────────────────
  // field 11/12 はオプション追加なので既存データには影響しない（null 扱い）

  /// Maps JavaScript API 用キー（リファラー制限 OK）
  /// Hive には保存せず SharedPreferences に移動したため、
  /// このフィールドは互換のみ保持（常に null）
  String? jsApiKeyLegacy; // reserved / unused

  /// REST API 用キー legacy storage（SharedPreferences に移行済み）
  String? restApiKeyLegacy; // reserved / unused

  // ── Day 11: 空き枠 LINE 通知 ─────────────────────────────────
  // fieldId 13/14 の追加のみ（既存データは null → 既定値で動作）。
  // 後方互換: 旧データ読み込み時は Hive が null を渡すため
  // コンストラクタのデフォルト引数が適用される。

  /// 空き枠通知の回答期限時刻（"HH:mm"）
  /// 文面に「○○時までにご連絡ください」として差し込む。
  String vacancyReplyDeadline;

  /// 空き枠通知の文面テンプレート
  /// プレースホルダ: {facility} {date} {deadline} {child}
  String vacancyMessageTemplate;

  // ── Day 14: 空き枠の応募受付時間 ─────────────────────────────
  // fieldId 15 の追加のみ（既存データは null → 既定 6 時間で動作）。

  /// 空き枠の応募受付時間（時間）。通知送信時から何時間で締め切るか。
  /// サーバー側でも 1〜24 に丸められる（Functions clampSlotTtlHours）。
  int slotTtlHours;

  // ── Day 15: 管理者 LINE userId ───────────────────────────────
  // fieldId 16 の追加のみ（既存データは null → 未設定として動作）。

  /// 管理者（事業所代表者）の LINE userId。
  /// 設定されていれば、応募の確定・取り消し時に管理者へ LINE 通知する。
  /// null = 未設定（通知しない。確定処理には影響しない）。
  /// 形式は 'U' + 32桁 16進（[isValidLineUserId]）。
  String? adminLineUserId;

  /// 業務日誌「その日の内容」の選択肢（ステップ3。設定で増減できる）。
  /// 日誌には選んだ名前をそのまま写して残すので、ここから消しても過去の日誌には残る。
  List<String> journalActivityOptions;

  /// 担当者の切り替えに 4 桁の暗証番号を求めるか（予約。このステップでは常に false。
  /// 職員ごとの暗証番号は staff/{id} の pinHash / pinSalt。Firestore のみ）
  bool staffPinEnabled;

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
    String? vacancyReplyDeadline,
    String? vacancyMessageTemplate,
    int? slotTtlHours,
    String? adminLineUserId,
    this.staffPinEnabled = false,
    List<String>? journalActivityOptions,
  })  : journalActivityOptions = journalActivityOptions == null
            ? List<String>.from(defaultJournalActivityOptions)
            : normalizeJournalActivityOptions(journalActivityOptions),
        slotTtlHours = clampSlotTtlHours(slotTtlHours),
        adminLineUserId = normalizeAdminLineUserId(adminLineUserId),
        vacancyReplyDeadline =
            (vacancyReplyDeadline == null || vacancyReplyDeadline.isEmpty)
                ? defaultVacancyReplyDeadline
                : vacancyReplyDeadline,
        vacancyMessageTemplate =
            (vacancyMessageTemplate == null || vacancyMessageTemplate.isEmpty)
                ? defaultVacancyMessageTemplate
                : vacancyMessageTemplate,
        vehicleNames = vehicleNames ?? ['車両A', '車両B'],
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
      vacancyReplyDeadline: vacancyReplyDeadline,
      vacancyMessageTemplate: vacancyMessageTemplate,
      slotTtlHours: slotTtlHours,
      adminLineUserId: adminLineUserId,
      staffPinEnabled: staffPinEnabled,
      journalActivityOptions: journalActivityOptions,
    );
  }

  /// 画面の上のバーと PDF に出す事業所名。設定の事業所名が空（空白だけを含む）なら
  /// 「事業所名 未設定」
  String get facilityLabel {
    final name = facilityName.trim();
    return name.isEmpty ? '事業所名 未設定' : name;
  }

  // ── ステップ3: 業務日誌「その日の内容」の選択肢 ─────────────────

  /// 選択肢の初期値
  static const List<String> defaultJournalActivityOptions = [
    '外遊び',
    '室内遊び',
    '工作',
    '宿題・学習',
    'おやつ',
    '調理',
    '散歩',
    '音楽・リズム',
    '運動',
    '行事・イベント',
    '個別の活動',
  ];

  /// 1 つの選択肢の長さの上限・選択肢の数の上限
  static const int maxJournalActivityLength = 30;
  static const int maxJournalActivityCount = 50;

  /// 前後の空白を除き、空・重複・長すぎるものを除いて、上限までに切る（並びは保つ）
  static List<String> normalizeJournalActivityOptions(Iterable<String> src) {
    final out = <String>[];
    for (final raw in src) {
      final v = raw.trim();
      if (v.isEmpty || v.length > maxJournalActivityLength || out.contains(v)) {
        continue;
      }
      out.add(v);
      if (out.length >= maxJournalActivityCount) break;
    }
    return out;
  }

  // ── Day 15: 管理者 LINE userId の形式 ────────────────────────

  static final RegExp _lineUserIdRe = RegExp(r'^U[0-9a-fA-F]{32}$');

  /// LINE userId の形式か（'U' + 32桁 16進。functions の isValidLineUserId と一致）
  static bool isValidLineUserId(String? v) =>
      v != null && _lineUserIdRe.hasMatch(v.trim());

  /// 保存用に正規化する。前後空白を除き、空は null。
  /// 形式の検証は行わない（形式不正の拒否は SettingsService 側）。
  static String? normalizeAdminLineUserId(String? v) {
    if (v == null) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  /// 管理者通知が有効か（設定済みかつ形式 OK）
  bool get hasAdminLineUserId => isValidLineUserId(adminLineUserId);

  // ── Day 14: 応募受付時間の既定値・範囲 ───────────────────────

  /// 既定の受付時間（functions/src/config.ts の SLOT_TTL_HOURS と一致必須）
  static const int defaultSlotTtlHours = 6;

  /// 許可範囲（functions/src/config.ts の SLOT_TTL_MIN/MAX_HOURS と一致必須）
  static const int minSlotTtlHours = 1;
  static const int maxSlotTtlHours = 24;

  /// 受付時間を許可範囲に丸める。null・範囲外は既定値/境界へ。
  static int clampSlotTtlHours(int? v) {
    if (v == null) return defaultSlotTtlHours;
    if (v < minSlotTtlHours) return minSlotTtlHours;
    if (v > maxSlotTtlHours) return maxSlotTtlHours;
    return v;
  }

  // ── Day 11: 空き枠通知の既定値 ────────────────────────────────

  /// 回答期限の既定（当日 13:00 までに連絡をもらう運用を想定）
  static const String defaultVacancyReplyDeadline = '13:00';

  /// 通知文面の既定テンプレート
  static const String defaultVacancyMessageTemplate =
      '【{facility}】\n'
      '本日（{date}）、急なキャンセルにより空き枠が出ました。\n'
      'ご利用を希望される場合は {deadline} までにお電話でご連絡ください。\n'
      '※先着順となりますのでご了承ください。';

  /// テンプレートに値を差し込んだ通知文面を生成する
  ///
  /// [dateLabel] は「10/2」等の表示用日付。
  /// [childName] は児童名（テンプレートに {child} があれば差し込む）。
  String buildVacancyMessage({
    required String dateLabel,
    String childName = '',
  }) {
    return vacancyMessageTemplate
        .replaceAll('{facility}', facilityName)
        .replaceAll('{date}', dateLabel)
        .replaceAll('{deadline}', vacancyReplyDeadline)
        .replaceAll('{child}', childName);
  }

  /// 事業所の緯度経度が取得済みかどうか
  bool get hasGeocode => facilityLat != null && facilityLng != null;

  /// 座標文字列（デバッグ・表示用）
  String get geocodeLabel {
    if (!hasGeocode) return '未取得';
    return '${facilityLat!.toStringAsFixed(6)}, ${facilityLng!.toStringAsFixed(6)}';
  }

  // ── Firestore（facilities/{facilityId}/settings/app）──────────────
  // Maps の API キー（jsApiKeyLegacy / restApiKeyLegacy）は保存しない。
  // キーは SharedPreferences（端末ごと）に置く。

  /// 業務データの項目（記録欄・作成日時を除く）
  Map<String, dynamic> toFirestoreData() => {
        'facilityName': facilityName,
        'facilityAddress': facilityAddress,
        'facilityLat': facilityLat,
        'facilityLng': facilityLng,
        'vehicleCount': vehicleCount,
        'vehicleNames': List<String>.from(vehicleNames),
        'vehicleCapacities': List<int>.from(vehicleCapacities),
        'maxStudentsPerDay': maxStudentsPerDay,
        'defaultPickupStart': defaultPickupStart,
        'defaultDropoffEnd': defaultDropoffEnd,
        'vacancyReplyDeadline': vacancyReplyDeadline,
        'vacancyMessageTemplate': vacancyMessageTemplate,
        'slotTtlHours': slotTtlHours,
        'adminLineUserId': adminLineUserId,
        'staffPinEnabled': staffPinEnabled,
        'journalActivityOptions': List<String>.from(journalActivityOptions),
      };

  factory AppSettings.fromFirestore(Map<String, dynamic> d) {
    final defaults = AppSettings();
    return AppSettings(
      facilityName: readString(d['facilityName']) ?? defaults.facilityName,
      facilityAddress: readString(d['facilityAddress']) ?? defaults.facilityAddress,
      facilityLat: readDouble(d['facilityLat']),
      facilityLng: readDouble(d['facilityLng']),
      vehicleCount: readInt(d['vehicleCount'], defaults.vehicleCount),
      vehicleNames: d['vehicleNames'] is List
          ? readStringList(d['vehicleNames'])
          : null,
      vehicleCapacities: d['vehicleCapacities'] is List
          ? readIntList(d['vehicleCapacities'])
          : null,
      maxStudentsPerDay: readInt(d['maxStudentsPerDay'], defaults.maxStudentsPerDay),
      defaultPickupStart: readString(d['defaultPickupStart']) ?? defaults.defaultPickupStart,
      defaultDropoffEnd: readString(d['defaultDropoffEnd']) ?? defaults.defaultDropoffEnd,
      updatedAt: readTimestamp(d['updatedAt']),
      vacancyReplyDeadline: readString(d['vacancyReplyDeadline']),
      vacancyMessageTemplate: readString(d['vacancyMessageTemplate']),
      slotTtlHours: d['slotTtlHours'] is num ? (d['slotTtlHours'] as num).toInt() : null,
      adminLineUserId: readString(d['adminLineUserId']),
      staffPinEnabled: d['staffPinEnabled'] == true,
      // 未保存（項目なし）なら初期値。空のリストは「すべて消した」として空のまま
      journalActivityOptions: d['journalActivityOptions'] is List
          ? readStringList(d['journalActivityOptions'])
          : null,
    );
  }
}
