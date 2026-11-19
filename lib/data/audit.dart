import 'package:cloud_firestore/cloud_firestore.dart';

/// 書き込みに残す「誰が・いつ」の記録。
///
/// 全ドキュメント共通で updatedAt / updatedByStaffId / updatedByStaffName を持つ。
/// 名前も持たせるのは、職員が在籍終了になった後も過去の記録に名前を出すため。
class AuditStamp {
  final String? staffId;
  final String staffName;

  const AuditStamp({required this.staffId, required this.staffName});

  /// 画面を開いたときの自動処理（当日予定の生成・週の自動作成・
  /// 利用日数キャッシュの補正）。担当者未選択でも書ける。
  static const AuditStamp auto = AuditStamp(staffId: null, staffName: '自動');

  /// 職員が 1 人もいないときの最初の職員登録（担当者を選びようがないため）
  static const AuditStamp initialSetup =
      AuditStamp(staffId: null, staffName: '初期設定');

  static const String fUpdatedAt = 'updatedAt';
  static const String fUpdatedByStaffId = 'updatedByStaffId';
  static const String fUpdatedByStaffName = 'updatedByStaffName';
  static const String fCreatedAt = 'createdAt';

  /// 更新時に付ける 3 項目（updatedAt はサーバー時刻）
  Map<String, dynamic> toFields() => {
        fUpdatedAt: FieldValue.serverTimestamp(),
        fUpdatedByStaffId: staffId,
        fUpdatedByStaffName: staffName,
      };

  /// 新規作成時に付ける 4 項目
  Map<String, dynamic> toCreateFields() => {
        ...toFields(),
        fCreatedAt: FieldValue.serverTimestamp(),
      };

  @override
  String toString() => 'AuditStamp($staffName${staffId == null ? '' : '/$staffId'})';
}

/// Firestore の値 → DateTime（Timestamp / null / 書込直後の未確定値に対応）
DateTime? readTimestamp(Object? v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  return null;
}
