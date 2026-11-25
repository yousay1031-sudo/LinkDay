import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/account_session.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';

/// 職員の Google メールアドレス（facilities/{facilityId}/staffAccounts/{staffId}）。
///
/// メールアドレスは個人情報のため、管理者だけが読み書きできる（firestore.rules）。
/// 管理者でないときは購読しない（購読すると権限エラーになる）。管理者でなくなったら
/// 端末内の一覧も捨てる。
class StaffAccountService extends ChangeNotifier {
  StaffAccountService._();
  static final StaffAccountService instance = StaffAccountService._();

  static const String fGoogleEmail = 'googleEmail';
  static const String fGoogleEmailLower = 'googleEmailLower';

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  final Map<String, String> _emails = {};
  bool _started = false;
  bool _loaded = false;

  /// 管理者として一覧を読み込み済みか（重複の確認に使う）
  bool get isLoaded => _loaded;

  CollectionReference<Map<String, dynamic>> get _col =>
      FacilityContext.instance.col(FsPaths.staffAccounts);

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
    final had = _emails.isNotEmpty || _loaded;
    _emails.clear();
    _loaded = false;
    if (had) notifyListeners();
  }

  void _sync() {
    final admin =
        AccountSession.instance.isAdmin && FacilityContext.instance.isAttached;
    if (admin && _sub == null) {
      _sub = _col.snapshots().listen((snap) {
        _emails
          ..clear()
          ..addEntries([
            for (final d in snap.docs)
              if (d.data()[fGoogleEmail] is String &&
                  (d.data()[fGoogleEmail] as String).isNotEmpty)
                MapEntry(d.id, d.data()[fGoogleEmail] as String),
          ]);
        _loaded = true;
        notifyListeners();
      }, onError: (Object e) {
        DataErrors.report('メールアドレスの一覧を読み込めませんでした（${DataErrors.describe(e)}）');
      });
    } else if (!admin && _sub != null) {
      unawaited(_cancel());
    }
  }

  /// 職員 [staffId] の Google メールアドレス（管理者でない・未登録なら null）
  String? emailOf(String staffId) => _emails[staffId];

  /// 同じアドレス（大文字・小文字を区別しない）を持つ、[exceptStaffId] 以外の職員
  String? staffIdWithEmail(String email, {String? exceptStaffId}) {
    final lower = normalize(email);
    for (final e in _emails.entries) {
      if (e.key != exceptStaffId && normalize(e.value) == lower) return e.key;
    }
    return null;
  }

  /// 照合に使う形（前後の空白を除き小文字）
  static String normalize(String email) => email.trim().toLowerCase();

  static final RegExp _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// メールアドレスの形として正しいか
  static bool isValidEmail(String email) => _emailRe.hasMatch(email.trim());

  /// 書き込みの直後に端末内の一覧へ反映する（購読の折り返しを待たない）
  void setLocal(String staffId, String? email) {
    if (email == null || email.isEmpty) {
      _emails.remove(staffId);
    } else {
      _emails[staffId] = email;
    }
    notifyListeners();
  }

  @visibleForTesting
  void debugSetEmails(Map<String, String> emails) {
    _emails
      ..clear()
      ..addAll(emails);
    _loaded = true;
    notifyListeners();
  }
}
