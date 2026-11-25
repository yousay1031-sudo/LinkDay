import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../services/attendance_service.dart';
import '../services/customer_service.dart';
import '../services/settings_service.dart';
import '../services/staff_account_service.dart';
import '../services/staff_service.dart';
import '../services/transport_plan_service.dart';
import '../services/weekly_schedule_service.dart';
import 'account_session.dart';
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

  /// いま使っている所属（ready のとき）
  Membership? _membership;
  FirebaseFirestore? _db;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _membershipSub;
  bool _rechecking = false;

  /// いま使っている所属（ready のとき）
  Membership? get membership => _membership;

  /// Google でログインしたアカウントの所属を作ってもらう処理（[start] に渡す）
  Future<bool> Function()? _claim;

  /// ログイン済みユーザー [uid] で開始する。同じ uid で開始済みなら何もしない。
  ///
  /// [claim] は Google でログインしたアカウントのときに渡す。所属が無ければ一度だけ
  /// 呼び（Cloud Functions が確認済みのメールアドレスから所属を作る）、読み直す。
  Future<void> start(
    String uid, {
    FirebaseFirestore? db,
    Future<bool> Function()? claim,
  }) async {
    if (_uid == uid &&
        (_status == DataSessionStatus.ready ||
            _status == DataSessionStatus.resolving)) {
      return;
    }
    if (_status != DataSessionStatus.idle) await _detachAll();
    _uid = uid;
    _claim = claim;
    _status = DataSessionStatus.resolving;
    _message = null;
    notifyListeners();

    final d = db ?? FirebaseFirestore.instance;
    try {
      var m = await FacilityContext.lookupMembership(d, uid);
      if (_uid != uid) return; // 途中で別ユーザー・ログアウトになった
      if (m == null && claim != null) {
        final ok = await claim();
        if (_uid != uid) return;
        if (ok)
          m = await FacilityContext.lookupMembership(d, uid, fromServer: true);
        if (_uid != uid) return;
      }
      if (m == null) {
        _status = DataSessionStatus.notMember;
        notifyListeners();
        return;
      }
      final fid = m.facilityId;
      FacilityContext.instance.attach(d, fid);
      await StaffService.instance.attach();
      if (m.personal) {
        // 個人アカウント: 本人が在籍中かつログイン許可でなければ入れない
        final me = StaffService.instance.getById(m.staffId!);
        if (me == null || !me.isActive || !me.loginEnabled) {
          await _detachAll();
          if (_uid != uid) return;
          _status = DataSessionStatus.notMember;
          notifyListeners();
          return;
        }
        AccountSession.instance.setPersonal(m.staffId!);
        StaffSession.instance.fixTo(m.staffId);
      } else {
        AccountSession.instance.setShared();
        StaffSession.instance.fixTo(null);
      }
      StaffAccountService.instance.start();
      await StaffSession.instance.restore(fid);
      await SettingsService.instance.attach();
      await CustomerService.instance.attach();
      await WeeklyScheduleService.instance.attach();
      await AttendanceService.instance.attach();
      await TransportPlanService.instance.attach();
      if (_uid != uid) return;
      _membership = m;
      _db = d;
      _watch(d, uid, m);
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
    await start(u, db: db, claim: _claim);
  }

  // ── 所属の見張り（ステップ2）──────────────────────────────────
  //
  // 管理者が職員を在籍終了・ログイン停止にすると、ルールはその時点から読み書きを
  // 拒否する。開いたままの画面も「事業所に登録されていません」へ切り替えるため、
  //   - 自分の所属の文書（消える・変わる）
  //   - 個人アカウントなら自分の職員の文書（在籍終了・ログイン停止）
  //   - 権限がないと断られたこと（DataErrors.onPermissionDenied）
  // のどれかで所属を確かめ直す。

  void _watch(FirebaseFirestore d, String uid, Membership m) {
    _membershipSub =
        d.collection(FsPaths.memberships).doc(uid).snapshots().listen((snap) {
      final now = Membership.fromData(snap.exists ? snap.data() : null);
      if (now != _membership) unawaited(_revoke('所属が変わりました'));
    }, onError: (Object e) => unawaited(recheck()));
    if (m.personal) StaffService.instance.addListener(_onStaffChanged);
    DataErrors.onPermissionDenied = () => unawaited(recheck());
  }

  void _unwatch() {
    unawaited(_membershipSub?.cancel());
    _membershipSub = null;
    StaffService.instance.removeListener(_onStaffChanged);
    DataErrors.onPermissionDenied = null;
  }

  void _onStaffChanged() {
    final m = _membership;
    if (m == null || !m.personal || !isReady) return;
    final me = StaffService.instance.getById(m.staffId!);
    // 購読が権限で止まって一覧が空になった場合も含む
    if (me == null || !me.isActive || !me.loginEnabled) {
      unawaited(_revoke('本人の職員が在籍終了・ログイン停止になりました'));
    }
  }

  /// 所属をサーバーで確かめ直し、無効なら「登録されていません」に切り替える
  Future<void> recheck() async {
    final uid = _uid, m = _membership, d = _db;
    if (!isReady || uid == null || m == null || d == null || _rechecking)
      return;
    _rechecking = true;
    try {
      final now =
          await FacilityContext.lookupMembership(d, uid, fromServer: true);
      if (now != m) {
        await _revoke('所属がありません');
        return;
      }
      if (m.personal) {
        final snap = await d
            .collection(FsPaths.facilities)
            .doc(m.facilityId)
            .collection(FsPaths.staff)
            .doc(m.staffId)
            .get(const GetOptions(source: Source.server));
        final data = snap.data();
        if (data == null ||
            data['isActive'] != true ||
            data['loginEnabled'] != true) {
          await _revoke('本人の職員が在籍終了・ログイン停止です');
        }
      }
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        await _revoke('権限がありません');
      }
      // 通信できないときは何もしない（次の操作で確かめ直す）
    } catch (e) {
      debugPrint('[DataSession] recheck failed: $e');
    } finally {
      _rechecking = false;
    }
  }

  Future<void> _revoke(String why) async {
    if (!isReady) return;
    debugPrint('[DataSession] 事業所に入れなくなりました: $why');
    await _detachAll();
    _status = DataSessionStatus.notMember;
    notifyListeners();
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
    _unwatch();
    _membership = null;
    _db = null;
    await SettingsService.instance.detach();
    await TransportPlanService.instance.detach();
    await AttendanceService.instance.detach();
    await WeeklyScheduleService.instance.detach();
    await CustomerService.instance.detach();
    await StaffAccountService.instance.stop();
    await StaffService.instance.detach();
    StaffSession.instance.reset();
    AccountSession.instance.reset();
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
