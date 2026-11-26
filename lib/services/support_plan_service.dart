import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/audit.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';
import '../data/pending_echoes.dart';
import '../data/staff_session.dart';
import '../models/customer.dart';
import '../models/support_plan.dart';
import '../models/weekly_schedule.dart';

/// 同意済みにできない（足りない点がある）のに同意を得た日が入っている
class PlanCannotAgreeException implements Exception {
  final List<String> blockers;
  const PlanCannotAgreeException(this.blockers);
  @override
  String toString() => '同意済みにできません: ${blockers.join(' / ')}';
}

/// 保存のしかた
enum PlanSaveMode {
  /// 作成中の計画の保存（同意を得た日を入れると同意済みになる）
  normal,

  /// 同意済みの計画の軽い修正（同意済みのまま。同意後に修正した日時と担当者を残す）
  lightRevision,

  /// 同意済みの計画の内容を変える（作成中に戻し、説明した日・同意を得た日を空にする）
  revertToDraft,
}

/// 個別支援計画の読み書き（facilities/{facilityId}/supportPlans/{planId}）。
///
/// 事業所の計画をすべて購読する（一覧・履歴・ホームの知らせに使う）。
/// 保存は「端末内へ反映 → 送信は待たない」（ステップ1と同じ）。削除はしない。
class SupportPlanService extends ChangeNotifier {
  SupportPlanService._();
  static final SupportPlanService instance = SupportPlanService._();

  final Map<String, SupportPlan> _cache = {};
  final PendingEchoesByDoc _echoes = PendingEchoesByDoc();
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  bool _attached = false;
  bool _loaded = false;

  bool get isAttached => _attached;
  bool get isLoaded => _loaded;

  CollectionReference<Map<String, dynamic>> get _col =>
      FacilityContext.instance.col(FsPaths.supportPlans);

  Future<void> attach() async {
    await detach();
    _attached = true;
    if (!FacilityContext.instance.isAttached) return;
    final first = Completer<void>();
    _sub = _col.snapshots().listen((snap) {
      var changed = false;
      for (final ch in snap.docChanges) {
        final id = ch.doc.id;
        if (ch.type == DocumentChangeType.removed) {
          changed |= _cache.remove(id) != null;
          continue;
        }
        final data = ch.doc.data();
        if (data == null) continue;
        final p = SupportPlan.fromFirestore(id, data);
        final normalized = p.toFirestoreData();
        if (_echoes.isStaleEcho(id, normalized)) continue;
        final cur = _cache[id];
        if (cur != null &&
            cur.sameContent(p) &&
            cur.revisedAfterAgreementAt == p.revisedAfterAgreementAt &&
            cur.updatedByStaffName == p.updatedByStaffName &&
            cur.updatedAt == p.updatedAt) {
          continue;
        }
        _cache[id] = p;
        changed = true;
      }
      _loaded = true;
      if (!first.isCompleted) first.complete();
      if (changed) notifyListeners();
    }, onError: (Object e) {
      DataErrors.report('個別支援計画を読み込めませんでした（${DataErrors.describe(e)}）');
      if (!first.isCompleted) first.complete();
    });
    await first.future.timeout(const Duration(seconds: 10), onTimeout: () {
      debugPrint('[SupportPlanService] first snapshot timeout');
    });
    debugPrint('[SupportPlanService] attached: plans=${_cache.length}');
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    _cache.clear();
    _echoes.clear();
    _attached = false;
    _loaded = false;
  }

  SupportPlan? getById(String id) => _cache[id];

  List<SupportPlan> get all => _cache.values.toList();

  /// 児童の計画（新しい順: 作成年月日 → 作った日時）
  List<SupportPlan> plansOf(String customerId) {
    final list =
        _cache.values.where((p) => p.customerId == customerId).toList();
    list.sort((a, b) {
      final ca = a.createdOn, cb = b.createdOn;
      if (ca != null && cb != null && ca != cb) return cb.compareTo(ca);
      if (ca == null && cb != null) return -1; // 作成年月日が無い（書きかけ）を先に
      if (ca != null && cb == null) return 1;
      final xa = a.createdAt, xb = b.createdAt;
      if (xa != null && xb != null && xa != xb) return xb.compareTo(xa);
      return b.id.compareTo(a.id);
    });
    return list;
  }

  /// 新しい計画の ID
  String newId() => FacilityContext.instance.isAttached
      ? _col.doc().id
      : 'local-${DateTime.now().microsecondsSinceEpoch}';

  /// 計画を保存する（担当者が必要）。使った担当者の記録を返す。
  ///
  /// - [exists]: 保存先に既にあるか（作成日時を付けるかどうか）
  /// - 状態は同意を得た日から決める（入っていれば同意済み）。足りない点があるのに
  ///   同意を得た日が入っていれば [PlanCannotAgreeException]（作成中のままなら保存できる）。
  /// - [mode] は同意済みの計画を直すときに使う（[PlanSaveMode]）。
  Future<AuditStamp> save(
    SupportPlan plan, {
    required bool exists,
    PlanSaveMode mode = PlanSaveMode.normal,
    AuditStamp? stamp,
  }) async {
    var p = plan;
    if (mode == PlanSaveMode.revertToDraft) {
      p = p.copyWith(
          explainedOn: () => null,
          agreedOn: () => null,
          status: PlanStatus.draft);
    } else {
      p = p.copyWith(
          status: p.agreedOn != null ? PlanStatus.agreed : PlanStatus.draft);
    }
    if (p.agreedOn != null) {
      final check = PlanCheck.of(p);
      if (!check.canAgree) throw PlanCannotAgreeException(check.blockers);
    }
    final s = stamp ?? await StaffSession.instance.requireStamp();
    final data = p.toFirestoreData();
    final revision = <String, dynamic>{
      if (mode == PlanSaveMode.lightRevision) ...{
        SupportPlan.fRevisedAt: FieldValue.serverTimestamp(),
        SupportPlan.fRevisedById: s.staffId,
        SupportPlan.fRevisedByName: s.staffName,
      },
      if (mode == PlanSaveMode.revertToDraft) ...{
        SupportPlan.fRevisedAt: null,
        SupportPlan.fRevisedById: null,
        SupportPlan.fRevisedByName: null,
      },
    };
    // 画面用の内容はすぐ新しくする（送信は待たない）
    final prev = _cache[p.id];
    final light = mode == PlanSaveMode.lightRevision;
    final keep = mode == PlanSaveMode.normal ? prev : null;
    final now = DateTime.now();
    _cache[p.id] = p.withRecords(
      revisedAt: light ? now : keep?.revisedAfterAgreementAt,
      revisedById: light ? s.staffId : keep?.revisedAfterAgreementByStaffId,
      revisedByName:
          light ? s.staffName : keep?.revisedAfterAgreementByStaffName,
      updatedAt: now,
      updatedById: s.staffId,
      updatedByName: s.staffName,
      createdAt: prev?.createdAt ?? now,
    );
    notifyListeners();
    if (!FacilityContext.instance.isAttached) return s;
    _echoes.add(p.id, data);
    DataErrors.send(
      _col.doc(p.id).set(
        {...data, ...revision, ...(exists ? s.toFields() : s.toCreateFields())},
        SetOptions(merge: true),
      ),
      what: '個別支援計画（${p.customerName}）',
    );
    return s;
  }

  // ── 初期値 ─────────────────────────────────────────────────

  static const List<String> _weekdays = ['月', '火', '水', '木', '金', '土', '日'];

  /// 「支援の標準的な提供時間等」の初期値。
  /// 曜日は顧客の利用曜日、時間は週間利用計画のその児童の予定時刻のうちいちばん
  /// 多いもの（同じ数なら新しい日のもの）。予定が無ければ曜日だけ。
  static String standardTimeFor(
      Customer c, Iterable<(DateTime, ScheduleEntry)> entries) {
    final days = [
      for (final d in [...c.regularDays]..sort())
        if (d >= 1 && d <= 7) _weekdays[d - 1]
    ];
    final counts = <String, int>{};
    final latest = <String, DateTime>{};
    for (final (date, e) in entries) {
      if (e.customerId != c.id) continue;
      final s = e.plannedStartTime, en = e.plannedEndTime;
      if (s == null || en == null || s.isEmpty || en.isEmpty) continue;
      final k = '$s〜$en';
      counts[k] = (counts[k] ?? 0) + 1;
      final l = latest[k];
      if (l == null || date.isAfter(l)) latest[k] = date;
    }
    String? time;
    for (final k in counts.keys) {
      if (time == null ||
          counts[k]! > counts[time]! ||
          (counts[k] == counts[time] && latest[k]!.isAfter(latest[time]!))) {
        time = k;
      }
    }
    final dayText = days.isEmpty ? '' : '${days.join('・')}曜日';
    return [dayText, if (time != null) time]
        .where((s) => s.isNotEmpty)
        .join('　');
  }

  @visibleForTesting
  void debugSetCache(List<SupportPlan> plans) {
    _cache
      ..clear()
      ..addEntries(plans.map((p) => MapEntry(p.id, p)));
    _loaded = true;
    notifyListeners();
  }
}
