import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/account_session.dart';
import '../data/audit.dart';
import '../data/facility_context.dart';
import 'staff_service.dart';

/// ログイン履歴の 1 件
class LoginEntry {
  const LoginEntry({
    required this.id,
    required this.uid,
    required this.personal,
    required this.at,
    this.staffId,
    this.staffName,
  });

  final String id;
  final String uid;

  /// 個人アカウント（Google）か。false なら共用端末アカウント
  final bool personal;
  final String? staffId;
  final String? staffName;
  final DateTime? at;

  static LoginEntry fromMap(String id, Map<String, dynamic> m) => LoginEntry(
        id: id,
        uid: m['uid'] is String ? m['uid'] as String : '',
        personal: m['kind'] == 'personal',
        staffId: m['staffId'] as String?,
        staffName: m['staffName'] as String?,
        at: readTimestamp(m['at']),
      );
}

/// ログイン履歴（facilities/{facilityId}/loginHistory/{uid}_{auth_time}）。
///
/// - ログインして事業所に入れたときに 1 件記録する（[recordLogin]。DataSession から）。
///   文書の ID に auth_time（実際にログインした時刻）を使うので、ページを再読み込みしても
///   増えない（同じ ID への 2 回目の書き込みはルールで拒否される）。端末にも「記録済み」を
///   残して、無駄な送信をしない。
/// - 追記だけ。書き換え・削除はルールで拒否。
/// - 読めるのは管理者だけ。管理者のときだけ購読する。
class LoginHistoryService extends ChangeNotifier {
  LoginHistoryService._();
  static final LoginHistoryService instance = LoginHistoryService._();

  /// 一覧に出す件数（新しい順）
  static const int recentLimit = 100;

  /// いまのログインの auth_time（秒）を返す処理（main.dart が Firebase の認証から設定する。
  /// 未設定なら記録しない）
  Future<int?> Function()? authTimeProvider;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  final List<LoginEntry> _recent = [];
  final Map<String, DateTime?> _lastByStaff = {};
  bool _started = false;
  bool _loaded = false;

  bool get isLoaded => _loaded;
  List<LoginEntry> get recent => List.unmodifiable(_recent);

  CollectionReference<Map<String, dynamic>> get _col =>
      FacilityContext.instance.col(FsPaths.loginHistory);

  static String prefsKey(String docId) => 'linkday.loginRecorded.$docId';

  /// ログインして事業所に入れたときに呼ぶ。同じログインでは 1 回だけ記録する。
  /// 記録できなくても（通信できない・すでに記録済みなど）画面の操作は止めない。
  Future<void> recordLogin(String uid) async {
    final p = authTimeProvider;
    if (p == null || !FacilityContext.instance.isAttached) return;
    try {
      final authTime = await p();
      if (authTime == null) return;
      final docId = '${uid}_$authTime';
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(prefsKey(docId)) == true) return;
      final acc = AccountSession.instance;
      final me = acc.staff;
      await _col.doc(docId).set({
        'uid': uid,
        'kind': acc.isPersonal ? 'personal' : 'shared',
        'staffId': acc.isPersonal ? acc.staffId : null,
        'staffName': acc.isPersonal ? me?.name : null,
        'at': FieldValue.serverTimestamp(),
        'authTime': authTime,
      });
      await prefs.setBool(prefsKey(docId), true);
      debugPrint('[LoginHistory] ログインを記録しました');
    } catch (e) {
      // 同じログインの 2 回目（端末の「記録済み」が消えていた場合など）はルールで
      // 拒否される。記録の失敗で利用者の操作を止めない。
      debugPrint('[LoginHistory] 記録しませんでした: $e');
    }
  }

  // ── 管理者の表示用 ───────────────────────────────────────────

  /// ログイン後に呼ぶ。管理者かどうかに合わせて購読を始める・止める。
  void start() {
    if (_started) return;
    _started = true;
    AccountSession.instance.addListener(_sync);
    _sync();
  }

  Future<void> stop() async {
    if (_started) AccountSession.instance.removeListener(_sync);
    _started = false;
    await _cancel();
  }

  Future<void> _cancel() async {
    await _sub?.cancel();
    _sub = null;
    _recent.clear();
    _lastByStaff.clear();
    _loaded = false;
  }

  void _sync() {
    final admin =
        AccountSession.instance.isAdmin && FacilityContext.instance.isAttached;
    if (admin && _sub == null) {
      _sub = _col
          .orderBy('at', descending: true)
          .limit(recentLimit)
          .snapshots()
          .listen((snap) {
        _recent
          ..clear()
          ..addAll(snap.docs.map((d) => LoginEntry.fromMap(d.id, d.data())));
        for (final e in _recent) {
          final sid = e.staffId;
          if (sid == null || e.at == null) continue;
          final cur = _lastByStaff[sid];
          if (cur == null || e.at!.isAfter(cur)) _lastByStaff[sid] = e.at;
        }
        _loaded = true;
        notifyListeners();
      }, onError: (Object e) {
        debugPrint('[LoginHistory] 一覧を読めませんでした: $e');
      });
      unawaited(loadLastLogins());
    } else if (!admin && _sub != null) {
      unawaited(_cancel().then((_) => notifyListeners()));
    }
  }

  /// 職員ごとの最後のログイン（管理者だけ。読み込んでいなければ null）
  DateTime? lastLoginOf(String staffId) => _lastByStaff[staffId];

  /// 直近の一覧に無い職員の最後のログインも読む（職員ごとに 1 件。索引 staffId+at を使う）
  Future<void> loadLastLogins() async {
    if (!AccountSession.instance.isAdmin) return;
    var changed = false;
    for (final s in StaffService.instance.getActiveStaff()) {
      if (!s.hasGoogleEmail || _lastByStaff.containsKey(s.id)) continue;
      try {
        final snap = await _col
            .where('staffId', isEqualTo: s.id)
            .orderBy('at', descending: true)
            .limit(1)
            .get();
        final at = snap.docs.isEmpty
            ? null
            : readTimestamp(snap.docs.first.data()['at']);
        final cur = _lastByStaff[s.id];
        if (at != null && (cur == null || at.isAfter(cur))) {
          _lastByStaff[s.id] = at;
          changed = true;
        }
      } catch (e) {
        debugPrint('[LoginHistory] 最後のログインを読めませんでした: $e');
      }
    }
    if (changed) notifyListeners();
  }
}
