import 'package:flutter/foundation.dart';

/// 空き枠の状態（functions/src/slots.ts の SlotStatus と一致）
enum SlotState {
  /// 募集中（応募受付中）
  open,

  /// 応募が確定した
  filled,

  /// 応募者がキャンセルして再募集中
  released,

  /// 受付期限を過ぎた（Firestore 上は open/released のまま。表示時に判定）
  expired,

  /// 想定外の値（表示は「不明」。誤って確定扱いにしない）
  unknown,
}

/// 応募確定者
@immutable
class SlotClaim {
  final String customerId;
  final DateTime? claimedAt;

  const SlotClaim({required this.customerId, required this.claimedAt});
}

/// Firestore `slots/{dateKey}_{欠席児童のcustomerId}` の読み取り専用ビュー
///
/// 書き込みは Cloud Functions のみ（firestore.rules で client write 禁止）。
/// このクラスは「職員が画面で状況を確認する」ためだけに存在する。
@immutable
class SlotInfo {
  final String id;

  /// 対象日 "YYYY-MM-DD"
  final String dateKey;

  /// 欠席した児童の customerId（枠の出所）
  final String sourceAbsent;

  /// Firestore 上の status（生の値）
  final String rawStatus;

  /// 受付期限
  final DateTime? expiresAt;

  /// 確定者（status=filled のときのみ）
  final SlotClaim? claimedBy;

  /// 通知を送った人数
  final int notifiedCount;

  const SlotInfo({
    required this.id,
    required this.dateKey,
    required this.sourceAbsent,
    required this.rawStatus,
    required this.expiresAt,
    required this.claimedBy,
    required this.notifiedCount,
  });

  /// Firestore のドキュメント data から組み立てる。
  /// 型が崩れていても例外を投げず、安全側（unknown）に倒す。
  factory SlotInfo.fromMap(String id, Map<String, dynamic> data) {
    final claimedRaw = data['claimedBy'];
    SlotClaim? claim;
    if (claimedRaw is Map) {
      final cid = claimedRaw['customerId'];
      if (cid is String && cid.isNotEmpty) {
        claim = SlotClaim(
          customerId: cid,
          claimedAt: _toDate(claimedRaw['claimedAt']),
        );
      }
    }
    final notified = data['notifiedList'];
    return SlotInfo(
      id: id,
      dateKey: data['dateKey'] is String ? data['dateKey'] as String : '',
      sourceAbsent:
          data['sourceAbsent'] is String ? data['sourceAbsent'] as String : '',
      rawStatus: data['status'] is String ? data['status'] as String : '',
      expiresAt: _toDate(data['expiresAt']),
      claimedBy: claim,
      notifiedCount: notified is List ? notified.length : 0,
    );
  }

  /// 表示用の状態。期限切れは読み出し時に判定する
  /// （サーバーも status を書き換えない設計: functions/src/config.ts 参照）。
  ///
  /// 確定済み(filled)は期限を過ぎても filled のまま。
  SlotState stateAt(DateTime now) {
    switch (rawStatus) {
      case 'filled':
        // 確定者情報が欠けた filled は「確定」と断定しない
        return claimedBy == null ? SlotState.unknown : SlotState.filled;
      case 'open':
      case 'released':
        final ex = expiresAt;
        if (ex != null && !ex.isAfter(now)) return SlotState.expired;
        return rawStatus == 'open' ? SlotState.open : SlotState.released;
      case 'expired':
        return SlotState.expired;
      default:
        return SlotState.unknown;
    }
  }

  static DateTime? _toDate(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    // Firestore Timestamp（cloud_firestore への依存をモデルに持ち込まない）
    try {
      final dynamic d = v;
      final converted = d.toDate();
      if (converted is DateTime) return converted;
    } catch (_) {}
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  @override
  String toString() => 'SlotInfo($id, $rawStatus, claimed=${claimedBy?.customerId})';
}
