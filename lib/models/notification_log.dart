import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'notification_log.g.dart';

/// 通知送信ステータス
/// Hive Type ID: 12
///
/// Cloud Functions（sendVacancyNotice）が返す status 文字列と 1:1 対応させる。
@HiveType(typeId: 12)
enum NotificationStatus {
  /// 送信成功（LINE API が 200 を返した）
  @HiveField(0)
  sent,

  /// 送信失敗（LINE API エラー / ネットワーク失敗）
  @HiveField(1)
  failed,

  /// 二重送信としてブロックされた（サーバー側冪等チェック）
  @HiveField(2)
  duplicate,

  /// lineUserId 形式不正で送信されなかった
  @HiveField(3)
  invalidLineUserId,
}

/// 空き枠通知の送信記録（1 児童 1 日 1 レコード）
/// Hive Type ID: 11
/// box: 'notification_logs'
/// キー: ${dateKey}_${customerId}
///
/// 【役割】
/// 1. クライアント側の二重送信ブロック（サーバー冪等の前段ガード）
/// 2. 通知履歴画面の表示元データ
///
/// サーバー（Firestore notification_logs）が正だが、
/// オフライン・通信失敗時でも「送ったかどうか」を職員が確認できるよう
/// 端末内にも必ず残す。
@HiveType(typeId: 11)
class NotificationLog extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String customerId;

  /// 児童名スナップショット（履歴表示用。顧客削除後も残る）
  @HiveField(2)
  String childName;

  /// "2026-10-02" 形式の対象日
  @HiveField(3)
  String dateKey;

  @HiveField(4)
  NotificationStatus status;

  /// 送信を試みた時刻
  @HiveField(5)
  DateTime sentAt;

  /// LINE API の HTTP ステータス（未送信は null）
  @HiveField(6)
  int? httpStatus;

  /// エラー要約（成功時は null）
  @HiveField(7)
  String? error;

  /// 送信した LINE userId の末尾 4 桁のみ（全体は保存しない＝漏洩面積の最小化）
  @HiveField(8)
  String? lineUserIdSuffix;

  /// 送信した文面（履歴で「何を送ったか」を確認できるようにする）
  @HiveField(9)
  String? message;

  NotificationLog({
    String? id,
    required this.customerId,
    required this.childName,
    required this.dateKey,
    required this.status,
    DateTime? sentAt,
    this.httpStatus,
    this.error,
    this.lineUserIdSuffix,
    this.message,
  })  : id = id ?? const Uuid().v4(),
        sentAt = sentAt ?? DateTime.now();

  /// Hive の box キー（dateKey + customerId で一意）
  String get boxKey => makeBoxKey(dateKey, customerId);

  static String makeBoxKey(String dateKey, String customerId) =>
      '${dateKey}_$customerId';

  /// 日付を dateKey 文字列に変換（AttendanceRecord と同じ形式）
  static String makeDateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 「送信済み」として二重送信をブロックすべきステータスか
  ///
  /// failed も含める理由: LINE 側の都合（ブロック済み等）で失敗した宛先に
  /// 自動で何度も投げるのは迷惑行為になりうる。再送は職員が
  /// 履歴を見て明示的に行う（将来の再送機能）運用とする。
  bool get blocksResend =>
      status == NotificationStatus.sent ||
      status == NotificationStatus.failed ||
      status == NotificationStatus.duplicate;

  /// 表示用ラベル
  String get statusLabel {
    switch (status) {
      case NotificationStatus.sent:
        return '成功';
      case NotificationStatus.failed:
        return '失敗';
      case NotificationStatus.duplicate:
        return '送信済み（重複）';
      case NotificationStatus.invalidLineUserId:
        return 'ID不正';
    }
  }

  /// Cloud Functions のレスポンス status 文字列から変換する
  static NotificationStatus statusFromString(String? s) {
    switch (s) {
      case 'sent':
        return NotificationStatus.sent;
      case 'duplicate':
        return NotificationStatus.duplicate;
      case 'invalid_line_user_id':
        return NotificationStatus.invalidLineUserId;
      case 'failed':
      default:
        return NotificationStatus.failed;
    }
  }

  @override
  String toString() =>
      'NotificationLog($childName, $dateKey, ${status.name}'
      '${httpStatus != null ? ', http=$httpStatus' : ''})';
}
