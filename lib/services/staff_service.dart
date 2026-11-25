import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/account_session.dart';
import '../data/audit.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';
import '../data/fs_values.dart';
import '../data/pending_echoes.dart';
import '../data/staff_session.dart';
import '../models/staff.dart';
import 'staff_account_service.dart';

/// 管理者だけができる操作を、管理者でないアカウントで行おうとした
class NotAdminException implements Exception {
  const NotAdminException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 管理者が 1 人もいなくなる操作（最後の管理者の在籍終了・管理者の解除・ログインの停止）
class LastAdminException implements Exception {
  const LastAdminException();
  @override
  String toString() => '管理者が1人もいなくなるため、この操作はできません。'
      '先に別の職員を管理者にしてください。';
}

/// 入力の誤り（画面にそのまま出す）
class StaffInputException implements Exception {
  const StaffInputException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 職員サービス
///
/// Firestore: facilities/{facilityId}/staff/{staffId}
/// - ログイン後に [attach] でコレクション全体を購読し、端末内に一覧を持つ。
/// - 読み取りは同期（キャッシュから）。他端末の変更は購読で届き、
///   [ChangeNotifier] で画面へ知らせる。
/// - 職員は削除しない（在籍終了 = isActive:false）。過去の記録の名前は残る。
/// - 氏名などの編集は担当者を選んだ人なら誰でもできる。登録・在籍終了・在籍に戻す・
///   管理者・ログインの許可・メールアドレスは管理者だけ（[AccountSession.isAdmin]）。
///   画面で止めるだけでなく、firestore.rules でも拒否する。
class StaffService extends ChangeNotifier {
  StaffService._();
  static final StaffService instance = StaffService._();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  final Map<String, Staff> _cache = {};
  final PendingEchoesByDoc _echoes = PendingEchoesByDoc();
  bool _attached = false;

  bool get isAttached => _attached;

  CollectionReference<Map<String, dynamic>> get _col =>
      FacilityContext.instance.col(FsPaths.staff);

  CollectionReference<Map<String, dynamic>> get _accountCol =>
      FacilityContext.instance.col(FsPaths.staffAccounts);

  // ── 接続 ────────────────────────────────────────────────────

  /// 購読を開始し、最初のスナップショット（端末内キャッシュ由来でも可）を待つ。
  Future<void> attach(
      {Duration firstSnapshotTimeout = const Duration(seconds: 10)}) async {
    await detach();
    _attached = true;
    final first = Completer<void>();
    _sub = _col.snapshots().listen((snap) {
      final next = <String, Staff>{};
      for (final d in snap.docs) {
        final s = Staff.fromMap(d.id, d.data());
        final cached = _cache[d.id];
        // 続けて保存したとき、前の保存の折り返しで一時的に古い内容へ戻さない
        if (cached != null && _echoes.isStaleEcho(d.id, s.toComparable())) {
          next[d.id] = cached;
        } else {
          next[d.id] = s;
        }
      }
      _cache
        ..clear()
        ..addAll(next);
      if (!first.isCompleted) first.complete();
      notifyListeners();
    }, onError: (Object e) {
      DataErrors.report('職員一覧を読み込めませんでした（${DataErrors.describe(e)}）');
      if (!first.isCompleted) first.complete();
    });
    await first.future.timeout(firstSnapshotTimeout, onTimeout: () {
      debugPrint('[StaffService] first snapshot timeout（オフラインの可能性）');
    });
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    _cache.clear();
    _echoes.clear();
    _attached = false;
  }

  // ── 読み取り ────────────────────────────────────────────────

  /// 在籍中の職員（登録順）
  List<Staff> getActiveStaff() {
    final list = _cache.values.where((s) => s.isActive).toList()
      ..sort((a, b) {
        final ca = a.createdAt, cb = b.createdAt;
        if (ca != null && cb != null) {
          final c = ca.compareTo(cb);
          if (c != 0) return c;
        }
        return a.name.compareTo(b.name);
      });
    return list;
  }

  /// 在籍終了の職員（在籍終了が新しい順）
  List<Staff> getInactiveStaff() {
    final list = _cache.values.where((s) => !s.isActive).toList()
      ..sort((a, b) {
        final da = a.deactivatedAt, db = b.deactivatedAt;
        if (da != null && db != null) return db.compareTo(da);
        if (da != null) return -1;
        if (db != null) return 1;
        return a.name.compareTo(b.name);
      });
    return list;
  }

  Staff? getById(String id) => _cache[id];

  /// 管理者として働ける職員（在籍中・管理者・ログイン許可）
  List<Staff> getEffectiveAdmins() =>
      _cache.values.where((s) => s.isEffectiveAdmin).toList();

  // ── 書き込み ────────────────────────────────────────────────

  void _requireAdmin() {
    final reason = AccountSession.instance.adminOnlyReason;
    if (reason != null) throw NotAdminException(reason);
  }

  /// 職員 [id] が管理者でなくなる変更のとき、残る別の管理者の ID を返す。
  /// 誰も残らなければ [LastAdminException]。管理者が減らない変更なら null。
  String? _otherAdminIfDemoting(Staff before, Staff after) {
    if (!before.isEffectiveAdmin || after.isEffectiveAdmin) return null;
    for (final s in getEffectiveAdmins()) {
      if (s.id != before.id) return s.id;
    }
    throw const LastAdminException();
  }

  /// メールアドレスを確かめて、保存する形（前後の空白を除いたもの。空なら未登録）にする
  String _checkEmail(String email, {String? staffId}) {
    final trimmed = email.trim();
    if (trimmed.isEmpty) return '';
    if (!StaffAccountService.isValidEmail(trimmed)) {
      throw const StaffInputException('メールアドレスの形が正しくありません');
    }
    final dup = StaffAccountService.instance
        .staffIdWithEmail(trimmed, exceptStaffId: staffId);
    if (dup != null) {
      final who = getById(dup)?.name ?? '別の職員';
      throw StaffInputException('このメールアドレスは「$who」に登録されています');
    }
    return trimmed;
  }

  Map<String, dynamic> _accountFields(String email, AuditStamp stamp) => {
        StaffAccountService.fGoogleEmail: email,
        StaffAccountService.fGoogleEmailLower:
            StaffAccountService.normalize(email),
        ...stamp.toFields(),
      };

  void _putLocal(Staff s) {
    _cache[s.id] = s;
    _echoes.add(s.id, s.toComparable());
    notifyListeners();
  }

  /// 職員を登録する（管理者だけ）。[googleEmail] を渡すとメールアドレスも登録する。
  Future<Staff> addStaff(Staff draft, {String googleEmail = ''}) async {
    _requireAdmin();
    final name = draft.name.trim();
    if (name.isEmpty) throw const StaffInputException('氏名を入力してください');
    final email = _checkEmail(googleEmail);
    final stamp = await StaffSession.instance.requireStamp();
    final ref = _col.doc();
    final data = {
      ...draft
          .copyWith(name: name, hasGoogleEmail: email.isNotEmpty)
          .toCreateMap(),
      ...stamp.toCreateFields(),
    };
    final staff = Staff.fromMap(
        ref.id, {...data, AuditStamp.fCreatedAt: Timestamp.now()});
    _putLocal(staff);
    final batch = FacilityContext.instance.db.batch()..set(ref, data);
    if (email.isNotEmpty) {
      batch.set(_accountCol.doc(ref.id), {
        ..._accountFields(email, stamp),
        AuditStamp.fCreatedAt: FieldValue.serverTimestamp(),
      });
      StaffAccountService.instance.setLocal(ref.id, email);
    }
    DataErrors.send(batch.commit(), what: '職員「$name」の登録');
    return staff;
  }

  /// 氏名・ふりがな・役割・資格・勤務日・送迎の可否を保存する（担当者を選んだ人なら誰でも）
  Future<void> updateProfile(Staff edited) async {
    final current = _cache[edited.id];
    if (current == null) return;
    final name = edited.name.trim();
    if (name.isEmpty) throw const StaffInputException('氏名を入力してください');
    final stamp = await StaffSession.instance.requireStamp();
    final next = current.copyWith(
      name: name,
      kana: edited.kana.trim(),
      role: edited.role,
      clearRole: edited.role == null,
      qualifications: edited.qualifications.trim(),
      workDays: Staff.normalizeDays(edited.workDays),
      canDrive: edited.canDrive,
    );
    _putLocal(next);
    DataErrors.send(
      _col.doc(edited.id).update({...next.toProfileMap(), ...stamp.toFields()}),
      what: '職員「$name」',
    );
  }

  /// 管理者・ログインの許可・Google メールアドレスを変える（管理者だけ）。
  ///
  /// [googleEmail] は null なら変えない。空文字なら登録を外す。
  Future<void> updateAccess(
    String id, {
    bool? isAdmin,
    bool? loginEnabled,
    String? googleEmail,
  }) async {
    _requireAdmin();
    final current = _cache[id];
    if (current == null) return;
    final oldEmail = StaffAccountService.instance.emailOf(id) ?? '';
    final email =
        googleEmail == null ? null : _checkEmail(googleEmail, staffId: id);
    final emailChanged = email != null && email != oldEmail;
    final next = current.copyWith(
      isAdmin: isAdmin,
      loginEnabled: loginEnabled,
      hasGoogleEmail: email?.isNotEmpty,
    );
    final other = _otherAdminIfDemoting(current, next);
    if (!emailChanged &&
        fsChangedFields(current.toComparable(), next.toComparable()).isEmpty) {
      return; // 変更なし
    }
    final stamp = await StaffSession.instance.requireStamp();
    _putLocal(next);
    final batch = FacilityContext.instance.db.batch()
      ..update(_col.doc(id), {
        Staff.fIsAdmin: next.isAdmin,
        Staff.fLoginEnabled: next.loginEnabled,
        Staff.fHasGoogleEmail: next.hasGoogleEmail,
        Staff.fOtherAdminId: other,
        ...stamp.toFields(),
      });
    if (emailChanged) {
      batch.set(_accountCol.doc(id), _accountFields(email, stamp));
      StaffAccountService.instance.setLocal(id, email);
    }
    DataErrors.send(batch.commit(), what: '職員「${current.name}」のアカウント');
  }

  /// 在籍終了にする（管理者だけ）。一覧から消えるが、ドキュメントと過去の記録の名前は残る。
  /// その職員の個人アカウントは、その時点からログインできなくなる。
  Future<void> deactivateStaff(String id) async {
    _requireAdmin();
    final current = _cache[id];
    if (current == null || !current.isActive) return;
    final next =
        current.copyWith(isActive: false, deactivatedAt: DateTime.now());
    final other = _otherAdminIfDemoting(current, next);
    final stamp = await StaffSession.instance.requireStamp();
    _putLocal(next);
    DataErrors.send(
      _col.doc(id).update({
        Staff.fIsActive: false,
        Staff.fDeactivatedAt: FieldValue.serverTimestamp(),
        Staff.fOtherAdminId: other,
        ...stamp.toFields(),
      }),
      what: '職員「${current.name}」の在籍終了',
    );
  }

  /// 在籍に戻す（管理者だけ）。個人アカウントは、もう一度ログインすると使える。
  Future<void> restoreStaff(String id) async {
    _requireAdmin();
    final current = _cache[id];
    if (current == null || current.isActive) return;
    final stamp = await StaffSession.instance.requireStamp();
    _putLocal(current.copyWith(isActive: true, clearDeactivatedAt: true));
    DataErrors.send(
      _col.doc(id).update({
        Staff.fIsActive: true,
        Staff.fDeactivatedAt: null,
        Staff.fOtherAdminId: null,
        ...stamp.toFields(),
      }),
      what: '職員「${current.name}」を在籍に戻す',
    );
  }

  /// テスト用: 外から購読せずにキャッシュだけ入れる
  @visibleForTesting
  void debugSetCache(List<Staff> staff) {
    _cache
      ..clear()
      ..addEntries(staff.map((s) => MapEntry(s.id, s)));
    notifyListeners();
  }
}
