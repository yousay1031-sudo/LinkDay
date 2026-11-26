import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Firestore 上のコレクション名（firestore.rules・tool/verify/seed.mjs と一致させる）
class FsPaths {
  FsPaths._();

  /// 最上位: アカウント → 事業所の所属（クライアントは自分の分の read のみ）
  static const String memberships = 'memberships';

  /// 最上位: 事業所。業務データはすべてこの下に置く。
  static const String facilities = 'facilities';

  // ── facilities/{facilityId}/ の下 ──
  static const String customers = 'customers';
  static const String scheduleEntries = 'scheduleEntries';
  static const String scheduleWeeks = 'scheduleWeeks';
  static const String attendance = 'attendance';
  static const String transportRoutes = 'transportRoutes';
  static const String settings = 'settings';
  static const String staff = 'staff';

  /// 職員の Google メールアドレス（個人情報のため管理者だけが読み書きできる）
  static const String staffAccounts = 'staffAccounts';

  /// ログイン履歴（追記だけ。読めるのは管理者だけ）
  static const String loginHistory = 'loginHistory';

  /// 業務日誌（ステップ3）: facilities/{facilityId}/dailyJournals/{YYYY-MM-DD}
  static const String dailyJournals = 'dailyJournals';

  /// 個別支援計画（ステップ3）: facilities/{facilityId}/supportPlans/{planId}
  static const String supportPlans = 'supportPlans';

  /// 翌日予約選択の確認の記録（ステップ4）: facilities/{facilityId}/dayConfirmations/{YYYY-MM-DD}
  static const String dayConfirmations = 'dayConfirmations';

  /// settings コレクション内の唯一のドキュメント ID
  static const String settingsDocId = 'app';
}

/// 「いまどの保存先・どの事業所を見ているか」を一か所で持つ。
///
/// 【保存先の差し替え】
/// 本番は FirebaseFirestore.instance、テストは FakeFirebaseFirestore を
/// [attach] で渡す。各サービスはここから参照を取り、Firestore の実体を
/// 直接 new しない。
class FacilityContext {
  FacilityContext._();
  static final FacilityContext instance = FacilityContext._();

  FirebaseFirestore? _db;
  String? _facilityId;

  bool get isAttached => _db != null && _facilityId != null;

  FirebaseFirestore get db {
    final d = _db;
    if (d == null) {
      throw StateError('FacilityContext が未接続です（ログイン後に attach されます）');
    }
    return d;
  }

  String get facilityId {
    final f = _facilityId;
    if (f == null) {
      throw StateError('FacilityContext が未接続です（ログイン後に attach されます）');
    }
    return f;
  }

  /// 事業所が確定していれば ID、なければ null
  String? get facilityIdOrNull => _facilityId;

  DocumentReference<Map<String, dynamic>> get facilityRef =>
      db.collection(FsPaths.facilities).doc(facilityId);

  /// facilities/{facilityId}/{name}
  CollectionReference<Map<String, dynamic>> col(String name) =>
      facilityRef.collection(name);

  void attach(FirebaseFirestore db, String facilityId) {
    _db = db;
    _facilityId = facilityId;
    debugPrint('[FacilityContext] attached facility=$facilityId');
  }

  void detach() {
    _db = null;
    _facilityId = null;
    debugPrint('[FacilityContext] detached');
  }

  /// memberships/{uid} から所属事業所 ID を読む。所属がなければ null。
  ///
  /// 例外（通信不可・権限なし）はそのまま投げる（呼び出し側で再試行を出す）。
  static Future<String?> lookupFacilityId(
    FirebaseFirestore db,
    String uid,
  ) async =>
      (await lookupMembership(db, uid))?.facilityId;

  /// memberships/{uid} を読む。所属がなければ null。
  static Future<Membership?> lookupMembership(
    FirebaseFirestore db,
    String uid, {
    bool fromServer = false,
  }) async {
    final snap = await db
        .collection(FsPaths.memberships)
        .doc(uid)
        .get(fromServer ? const GetOptions(source: Source.server) : null);
    return Membership.fromData(snap.exists ? snap.data() : null);
  }
}

/// 所属（memberships/{uid}）。作る・消すのは Cloud Functions だけ。
class Membership {
  const Membership(
      {required this.facilityId, required this.personal, this.staffId});

  final String facilityId;

  /// 個人アカウント（Google）か。kind が無い所属は共用端末アカウント。
  final bool personal;

  /// 個人アカウントにひも付く職員 ID
  final String? staffId;

  static Membership? fromData(Map<String, dynamic>? d) {
    if (d == null) return null;
    final fid = d['facilityId'];
    if (fid is! String || fid.trim().isEmpty) return null;
    final personal = d['kind'] == 'personal';
    final sid = d['staffId'];
    if (personal && (sid is! String || sid.isEmpty)) return null;
    return Membership(
      facilityId: fid.trim(),
      personal: personal,
      staffId: personal ? sid as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Membership &&
      other.facilityId == facilityId &&
      other.personal == personal &&
      other.staffId == staffId;

  @override
  int get hashCode => Object.hash(facilityId, personal, staffId);
}
