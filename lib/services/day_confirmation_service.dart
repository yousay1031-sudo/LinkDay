import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/audit.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';
import '../data/fs_values.dart';
import '../data/staff_session.dart';
import 'next_day_service.dart';
import 'weekly_schedule_service.dart';

/// 「その日の予定を確認した」の記録（facilities/{facilityId}/dayConfirmations/{YYYY-MM-DD}）。
/// 1 日 1 文書。印を残すだけで、予定は固定しない。
class DayConfirmation {
  final String dateKey;
  final DateTime? confirmedAt;
  final String? confirmedByStaffId;
  final String confirmedByStaffName;

  /// 確認したときの利用する人数・お休みの人数
  final int usingCount;
  final int absentCount;

  const DayConfirmation({
    required this.dateKey,
    required this.confirmedAt,
    required this.confirmedByStaffId,
    required this.confirmedByStaffName,
    required this.usingCount,
    required this.absentCount,
  });

  factory DayConfirmation.fromFirestore(String id, Map<String, dynamic> d) =>
      DayConfirmation(
        dateKey: id,
        confirmedAt: readTimestamp(d['confirmedAt']),
        confirmedByStaffId: readString(d['confirmedByStaffId']),
        confirmedByStaffName: readString(d['confirmedByStaffName']) ?? '',
        usingCount: readInt(d['usingCount'], 0),
        absentCount: readInt(d['absentCount'], 0),
      );
}

/// 確認の記録の読み書き。必要な日だけを購読する。
class DayConfirmationService extends ChangeNotifier {
  DayConfirmationService._();
  static final DayConfirmationService instance = DayConfirmationService._();

  final Map<String, DayConfirmation?> _cache = {};
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>
      _subs = {};
  final Map<String, Completer<void>> _ready = {};

  CollectionReference<Map<String, dynamic>> get _col =>
      FacilityContext.instance.col(FsPaths.dayConfirmations);

  static String keyOf(DateTime d) => dateOnlyToString(d)!;

  /// [date] の記録を購読し、最初の読み込みを待つ
  Future<void> ensure(DateTime date) {
    if (!FacilityContext.instance.isAttached) return Future.value();
    final key = keyOf(date);
    final r = _ready[key];
    if (r != null) return r.isCompleted ? Future.value() : r.future;
    final c = Completer<void>();
    _ready[key] = c;
    _subs[key] = _col.doc(key).snapshots().listen((snap) {
      final d = snap.data();
      _cache[key] = d == null ? null : DayConfirmation.fromFirestore(key, d);
      if (!c.isCompleted) c.complete();
      notifyListeners();
    }, onError: (Object e) {
      DataErrors.report('確認の記録を読み込めませんでした（${DataErrors.describe(e)}）');
      if (!c.isCompleted) c.complete();
    });
    return c.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  }

  /// [date] の記録（無ければ null。先に [ensure]）
  DayConfirmation? get(DateTime date) => _cache[keyOf(date)];

  /// 確認した（担当者が必要）。もう一度押すと、その時点の内容で上書きする
  /// （確認した人・時刻・人数が新しくなる。作成日時は残る）。
  Future<AuditStamp> confirm(DateTime date, NextDayCounts counts,
      {AuditStamp? stamp}) async {
    final s = stamp ?? await StaffSession.instance.requireStamp();
    final key = keyOf(date);
    final exists = _cache[key] != null;
    _cache[key] = DayConfirmation(
      dateKey: key,
      confirmedAt: DateTime.now(),
      confirmedByStaffId: s.staffId,
      confirmedByStaffName: s.staffName,
      usingCount: counts.using,
      absentCount: counts.absent,
    );
    notifyListeners();
    if (!FacilityContext.instance.isAttached) return s;
    DataErrors.send(
      _col.doc(key).set({
        'date': key,
        'confirmedAt': FieldValue.serverTimestamp(),
        'confirmedByStaffId': s.staffId,
        'confirmedByStaffName': s.staffName,
        'usingCount': counts.using,
        'absentCount': counts.absent,
        ...(exists ? s.toFields() : s.toCreateFields()),
      }, SetOptions(merge: true)),
      what: '翌日予約の確認（$key）',
    );
    return s;
  }

  /// 確認した後に、その日の予定が変わったか（承認済みの設計: 印は書き込まず、確認の時刻と
  /// 予定の最後の更新時刻、確認したときと今の利用する人数を比べて出す）
  static bool changedAfter(DayConfirmation c, DateTime date, int usingNow) {
    final at = c.confirmedAt;
    final latest = WeeklyScheduleService.instance.latestUpdateOn(date);
    if (usingNow != c.usingCount) return true;
    return at != null && latest != null && latest.isAfter(at);
  }

  Future<void> detach() async {
    for (final s in _subs.values) {
      await s.cancel();
    }
    _subs.clear();
    _ready.clear();
    _cache.clear();
  }
}
