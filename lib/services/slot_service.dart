import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/notification_log.dart';
import '../models/slot_info.dart';

/// 指定日（dateKey）の slots ドキュメントを流すストリームの型
typedef SlotQueryRunner = Stream<List<Map<String, dynamic>>> Function(
    String dateKey);

/// 空き枠（slots）の読み取り専用サービス（Day 14）
///
/// 【読む範囲を「選択中の日付」だけに絞る】
/// `where('dateKey', isEqualTo: <選択日>)` の単一フィールド等価クエリのみ。
///  - 他日の枠を読まない（読み取り量・個人情報の露出を最小化）
///  - 単一フィールドなので複合インデックス不要
///  - クライアント側でも dateKey を再確認し、他日が混ざっても表示しない
///
/// 書き込みは行わない（firestore.rules で client write は禁止）。
class SlotService {
  SlotService._();
  static final SlotService instance = SlotService._();

  /// Firestore コレクション名（functions/src/config.ts の COLLECTIONS.slots と一致必須）
  static const String colSlots = 'slots';

  /// テストで差し替える。null なら Firestore を使う。
  @visibleForTesting
  SlotQueryRunner? runnerOverride;

  /// リモート取得を無効化（オフライン・テスト）
  bool remoteEnabled = true;

  /// [date] の枠を購読する。日付が変わったら呼び直す（購読は呼び出し側で cancel）。
  ///
  /// エラー時は空リストではなく error を流す（「応募なし」と誤認させない）。
  Stream<List<SlotInfo>> watchByDate(DateTime date) {
    final dateKey = NotificationLog.makeDateKey(date);
    final runner = runnerOverride ?? _firestoreRunner;
    if (runnerOverride == null && !remoteEnabled) {
      return Stream<List<SlotInfo>>.value(const []);
    }
    return runner(dateKey).map((docs) => parse(docs, dateKey));
  }

  /// ドキュメント群を SlotInfo にして、[dateKey] 以外を取り除く。
  @visibleForTesting
  static List<SlotInfo> parse(
      List<Map<String, dynamic>> docs, String dateKey) {
    final out = <SlotInfo>[];
    for (final d in docs) {
      final id = d['__id'] is String ? d['__id'] as String : '';
      final info = SlotInfo.fromMap(id, d);
      if (info.dateKey != dateKey) continue; // 他日は表示しない
      out.add(info);
    }
    return out;
  }

  Stream<List<Map<String, dynamic>>> _firestoreRunner(String dateKey) {
    return FirebaseFirestore.instance
        .collection(colSlots)
        .where('dateKey', isEqualTo: dateKey)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => <String, dynamic>{...d.data(), '__id': d.id})
            .toList());
  }
}
