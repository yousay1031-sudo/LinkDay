import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// 保存処理の失敗を画面へ知らせるための通知口。
///
/// 【なぜ必要か】
/// Web 版 Firestore の `await set()` はサーバーの受領まで終わらないため、
/// 通信が切れていると画面が止まる。そこで通常の書き込みは
/// 「端末内キャッシュへ反映 → 送信は待たずに戻る」とし、
/// 後から失敗した場合はここへ流して SnackBar で知らせる（main.dart で購読）。
class DataErrors {
  DataErrors._();

  static final StreamController<String> _controller =
      StreamController<String>.broadcast();

  /// 画面へ出すメッセージの流れ
  static Stream<String> get messages => _controller.stream;

  static void report(String message) {
    debugPrint('[DataErrors] $message');
    if (!_controller.isClosed) _controller.add(message);
  }

  /// 書き込みを送信し、完了は待たない。失敗したら [what] 付きで知らせる。
  static void send(Future<void> write, {required String what}) {
    unawaited(write.catchError((Object e, StackTrace st) {
      report('$whatを保存できませんでした（${describe(e)}）');
    }));
  }

  /// 通信が切れていることによる失敗か
  static bool isOffline(Object e) =>
      e is FirebaseException &&
      (e.code == 'unavailable' || e.code == 'deadline-exceeded');

  /// 利用者向けの短い説明
  static String describe(Object e) {
    if (e is FirebaseException) {
      switch (e.code) {
        case 'unavailable':
        case 'deadline-exceeded':
          return '通信できません。接続を確かめて再試行してください';
        case 'permission-denied':
          return 'このアカウントには権限がありません';
        case 'aborted':
          return '他の端末の操作と重なりました。再試行してください';
        default:
          return 'エラー: ${e.code}';
      }
    }
    return '$e';
  }
}
