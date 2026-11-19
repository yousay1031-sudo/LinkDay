import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../services/customer_service.dart';
import '../services/staff_service.dart';
import 'data_errors.dart';
import 'facility_context.dart';
import 'staff_session.dart';

enum DataSessionStatus {
  /// 未ログイン
  idle,

  /// 所属事業所の確認・最初のデータ読み込み中
  resolving,

  /// 使用可能
  ready,

  /// このアカウントは事業所に所属していない
  notMember,

  /// 読み込みに失敗（通信不可など）。再試行できる
  error,
}

enum LogoutOutcome {
  /// ログアウトし、端末内のキャッシュも消した
  done,

  /// 未送信の書き込みが残っているため、ログアウトを止めた（何も消していない）
  pendingWrites,

  /// ログアウトしたが、端末内のキャッシュは消せなかった（他のタブが開いているなど）
  cacheNotCleared,
}

/// ログイン後の「事業所の確認 → 購読開始」と、ログアウト時の後片付けを受け持つ。
///
/// 起動の順番:
///   ログイン → memberships/{uid} から事業所を確認 → 各サービスの購読を開始し
///   最初のデータを待つ → ホーム画面
class DataSession extends ChangeNotifier {
  DataSession._();
  static final DataSession instance = DataSession._();

  DataSessionStatus _status = DataSessionStatus.idle;
  String? _message;
  String? _uid;

  DataSessionStatus get status => _status;
  String? get message => _message;
  String? get uid => _uid;
  bool get isReady => _status == DataSessionStatus.ready;

  /// テスト用: 未送信の書き込みを待つ処理の差し替え
  @visibleForTesting
  Future<void> Function()? debugWaitPendingWrites;

  /// ログイン済みユーザー [uid] で開始する。同じ uid で開始済みなら何もしない。
  Future<void> start(String uid, {FirebaseFirestore? db}) async {
    if (_uid == uid &&
        (_status == DataSessionStatus.ready ||
            _status == DataSessionStatus.resolving)) {
      return;
    }
    if (_status != DataSessionStatus.idle) await _detachAll();
    _uid = uid;
    _status = DataSessionStatus.resolving;
    _message = null;
    notifyListeners();

    final d = db ?? FirebaseFirestore.instance;
    try {
      final fid = await FacilityContext.lookupFacilityId(d, uid);
      if (_uid != uid) return; // 途中で別ユーザー・ログアウトになった
      if (fid == null) {
        _status = DataSessionStatus.notMember;
        notifyListeners();
        return;
      }
      FacilityContext.instance.attach(d, fid);
      await StaffService.instance.attach();
      await StaffSession.instance.restore(fid);
      await CustomerService.instance.attach();
      if (_uid != uid) return;
      _status = DataSessionStatus.ready;
    } catch (e) {
      debugPrint('[DataSession] start failed: $e');
      if (_uid != uid) return;
      await _detachAll();
      _uid = uid;
      _status = DataSessionStatus.error;
      _message = DataErrors.describe(e);
    }
    notifyListeners();
  }

  /// 再試行（エラー画面から）
  Future<void> retry({FirebaseFirestore? db}) async {
    final u = _uid;
    if (u == null) return;
    _status = DataSessionStatus.idle;
    await start(u, db: db);
  }

  /// 購読を止め、メモリ上の状態を捨てる（端末内の Firestore キャッシュは消さない）
  Future<void> stop() async {
    await _detachAll();
    _uid = null;
    _status = DataSessionStatus.idle;
    _message = null;
    notifyListeners();
  }

  Future<void> _detachAll() async {
    await CustomerService.instance.detach();
    await StaffService.instance.detach();
    StaffSession.instance.reset();
    FacilityContext.instance.detach();
  }

  /// 未送信の書き込みがすべて送られるのを [timeout] まで待つ。送れたら true。
  Future<bool> flushPendingWrites({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final waiter = debugWaitPendingWrites ??
        (FacilityContext.instance.isAttached
            ? () => FacilityContext.instance.db.waitForPendingWrites()
            : null);
    if (waiter == null) return true;
    try {
      await waiter().timeout(timeout);
      return true;
    } on TimeoutException {
      debugPrint('[DataSession] pending writes remain after $timeout');
      return false;
    } catch (e) {
      debugPrint('[DataSession] waitForPendingWrites failed: $e');
      return false;
    }
  }

  /// ログアウト（共用端末のため端末内のキャッシュも消す）。
  ///
  /// 【未送信の記録を黙って消さない】
  /// 先に未送信の書き込みの送信完了を待ち、[timeout] 内に終わらなければ
  /// 何も消さずに [LogoutOutcome.pendingWrites] を返す（画面側で警告して止める）。
  Future<LogoutOutcome> logout({
    required Future<void> Function() signOut,
    Duration timeout = const Duration(seconds: 5),
    Future<bool> Function(FirebaseFirestore db)? clearCache,
  }) async {
    final flushed = await flushPendingWrites(timeout: timeout);
    if (!flushed) return LogoutOutcome.pendingWrites;

    final db = FacilityContext.instance.isAttached
        ? FacilityContext.instance.db
        : null;
    // 共用端末: 次にログインする人へ前の担当者を引き継がない（端末の保存も消す）
    await StaffSession.instance.clearSelection();
    await stop();
    var cleared = true;
    if (db != null) {
      cleared = await (clearCache ?? clearLocalCache)(db);
    }
    await signOut();
    return cleared ? LogoutOutcome.done : LogoutOutcome.cacheNotCleared;
  }

  /// Firestore を終了して端末内キャッシュ（IndexedDB）を消す。
  /// 終了後の Firestore は使えないため、Web では呼び出し側でページを再読み込みする。
  static Future<bool> clearLocalCache(FirebaseFirestore db) async {
    try {
      await db.terminate();
      await db.clearPersistence();
      debugPrint('[DataSession] local cache cleared');
      return true;
    } catch (e) {
      // 他のタブで同じアプリが開いていると clearPersistence は失敗する
      debugPrint('[DataSession] clearPersistence failed: $e');
      return false;
    }
  }

  @visibleForTesting
  void debugReset() {
    _uid = null;
    _status = DataSessionStatus.idle;
    _message = null;
    debugWaitPendingWrites = null;
  }
}
