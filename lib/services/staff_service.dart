import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/audit.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';
import '../data/staff_session.dart';
import '../models/staff.dart';

/// 職員（担当者選択用）サービス
///
/// Firestore: facilities/{facilityId}/staff/{staffId}
/// - ログイン後に [attach] でコレクション全体を購読し、端末内に一覧を持つ。
/// - 読み取りは同期（キャッシュから）。他端末の変更は購読で届き、
///   [ChangeNotifier] で画面へ知らせる。
/// - 職員は削除しない（在籍終了 = isActive:false）。過去の記録の名前は残る。
class StaffService extends ChangeNotifier {
  StaffService._();
  static final StaffService instance = StaffService._();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  final Map<String, Staff> _cache = {};
  bool _attached = false;

  bool get isAttached => _attached;

  CollectionReference<Map<String, dynamic>> get _col =>
      FacilityContext.instance.col(FsPaths.staff);

  // ── 接続 ────────────────────────────────────────────────────

  /// 購読を開始し、最初のスナップショット（端末内キャッシュ由来でも可）を待つ。
  Future<void> attach({Duration firstSnapshotTimeout = const Duration(seconds: 10)}) async {
    await detach();
    _attached = true;
    final first = Completer<void>();
    _sub = _col.snapshots().listen((snap) {
      _cache
        ..clear()
        ..addEntries(snap.docs.map((d) => MapEntry(d.id, Staff.fromMap(d.id, d.data()))));
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

  Staff? getById(String id) => _cache[id];

  // ── 書き込み ────────────────────────────────────────────────

  /// 職員を名前だけで追加する。
  ///
  /// 担当者が必要。ただし在籍中の職員が 1 人もいないとき（初期設定）は
  /// 選びようがないので「初期設定」として記録する。
  Future<Staff> addStaff(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('名前を入力してください');
    }
    final stamp = getActiveStaff().isEmpty
        ? AuditStamp.initialSetup
        : await StaffSession.instance.requireStamp();
    final ref = _col.doc();
    final staff = Staff(id: ref.id, name: trimmed, createdAt: DateTime.now());
    _cache[ref.id] = staff;
    notifyListeners();
    DataErrors.send(
      ref.set({...staff.toCreateMap(), ...stamp.toCreateFields()}),
      what: '職員「$trimmed」',
    );
    return staff;
  }

  /// 在籍終了にする（一覧から消えるが、ドキュメントと過去の記録の名前は残る）
  Future<void> deactivateStaff(String id) async {
    final current = _cache[id];
    if (current == null || !current.isActive) return;
    final stamp = await StaffSession.instance.requireStamp();
    _cache[id] = current.copyWith(isActive: false, deactivatedAt: DateTime.now());
    notifyListeners();
    DataErrors.send(
      _col.doc(id).update({
        Staff.fIsActive: false,
        Staff.fDeactivatedAt: FieldValue.serverTimestamp(),
        ...stamp.toFields(),
      }),
      what: '職員「${current.name}」の在籍終了',
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
