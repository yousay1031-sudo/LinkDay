import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/audit.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';
import '../data/fs_values.dart';
import '../data/staff_session.dart';
import '../models/attendance_record.dart';
import '../models/customer.dart';
import 'settings_service.dart';
import 'weekly_schedule_service.dart';

/// 欠席ダイアログ選択肢
const List<String> kAbsenceReasons = [
  '体調不良',
  '家庭の都合',
  '連絡なし欠席',
  '学校都合',
  'その他',
];

/// markDeparted の結果
enum DepartResult {
  success,
  noCheckIn, // 入室記録がない
}

/// 他の端末で状態が先に変わっていたため、操作を取りやめた（状態を逆戻りさせない）
class AttendanceConflictException implements Exception {
  const AttendanceConflictException(this.current);

  /// 保存先の現在の状態
  final AttendanceStatus current;

  String get message {
    const labels = {
      AttendanceStatus.scheduled: '予定',
      AttendanceStatus.present: '在室中',
      AttendanceStatus.departed: '退室済',
      AttendanceStatus.absent: '欠席',
    };
    return '他の端末で先に「${labels[current]}」になっていたため、記録しませんでした。'
        '画面を最新の状態にしました。';
  }

  @override
  String toString() => message;
}

/// 通信できないため、入室・退室などを記録できなかった（画面は理由と再試行を出す）
class AttendanceUnavailableException implements Exception {
  const AttendanceUnavailableException(this.cause);
  final Object cause;

  String get message => '通信できないため記録できませんでした。接続を確かめて再試行してください。';

  @override
  String toString() => message;
}

/// 出席管理サービス
///
/// 保存先: Firestore `facilities/{facilityId}/attendance/{YYYY-MM-DD}_{customerId}`。
/// ドキュメント ID が日付と顧客から決まるので、同じ日・同じ顧客の記録は 1 件だけ。
///
/// - 月ごとに購読し、端末内に持つ。読み取りは従来どおり同期。
///   他の端末の変更は購読で届き、[ChangeNotifier] で画面へ知らせる。
/// - 入室・退室・欠席・欠席の取り消しは、トランザクションで保存先の現在の状態を
///   確かめてから書く。画面に出ていた状態と違っていたら記録せず
///   [AttendanceConflictException]（状態を逆戻りさせない）。
///   通信できなければ [AttendanceUnavailableException]（オフラインでは記録しない）。
/// - 当日予定の作成（[ensureTodayScheduledRecords]）は、1 回のトランザクションで
///   対象をすべて読み、無いものだけを作る。2 台が同時に動いても二重にならない。
///   担当者は不要（「自動」と記録）。
/// - 記録を変える操作には担当者が必要。入室・退室を記録した担当者も残す。
class AttendanceService extends ChangeNotifier {
  AttendanceService._();
  static final AttendanceService instance = AttendanceService._();

  final Map<String, AttendanceRecord> _cache = {};
  final Map<String, _MonthState> _months = {};
  bool _attached = false;

  bool get isAttached => _attached;

  /// トランザクションの待ち時間（通信できないときに画面を止めない）
  @visibleForTesting
  Duration transactionTimeout = const Duration(seconds: 10);

  /// テスト用: トランザクションを始める前にこの例外を投げる（通信できない状態の再現）
  @visibleForTesting
  Object? debugTransactionError;

  /// テスト用: トランザクションの前に待つ処理（応答待ちの状態の再現）
  @visibleForTesting
  Future<void> Function()? debugBeforeTransaction;

  Future<T> _runTransaction<T>(TransactionHandler<T> handler) async {
    final e = debugTransactionError;
    if (e != null) throw e;
    final wait = debugBeforeTransaction;
    if (wait != null) await wait();
    return FacilityContext.instance.db
        .runTransaction<T>(handler)
        .timeout(transactionTimeout);
  }

  CollectionReference<Map<String, dynamic>> get _col =>
      FacilityContext.instance.col(FsPaths.attendance);

  // ── 接続 ────────────────────────────────────────────────────

  /// ログイン後に呼ぶ。今月分を読み込む。
  Future<void> attach({DateTime? today}) async {
    await detach();
    _attached = true;
    await ensureDate(today ?? DateTime.now());
    debugPrint('[AttendanceService] attached: records=${_cache.length}');
  }

  Future<void> detach() async {
    for (final m in _months.values) {
      await m.cancel();
    }
    _months.clear();
    _cache.clear();
    _attached = false;
  }

  /// [date] を含む月を購読し、最初の読み込みを待つ
  Future<void> ensureDate(DateTime date) =>
      ensureMonth(DateTime(date.year, date.month));

  Future<void> ensureMonth(DateTime month) {
    if (!FacilityContext.instance.isAttached) return Future.value();
    final key = '${month.year}-${month.month.toString().padLeft(2, '0')}';
    final existing = _months[key];
    if (existing != null) {
      return existing.isReady ? Future<void>.value() : existing.ready;
    }
    final st = _MonthState();
    _months[key] = st;
    final start = '$key-01';
    final end = '$key-31';
    st.sub = _col
        .where('date', isGreaterThanOrEqualTo: start)
        .where('date', isLessThanOrEqualTo: end)
        .snapshots()
        .listen((snap) {
      var changed = false;
      for (final ch in snap.docChanges) {
        final id = ch.doc.id;
        if (ch.type == DocumentChangeType.removed) {
          changed |= _cache.remove(id) != null;
          continue;
        }
        final data = ch.doc.data();
        if (data == null) continue;
        final r = AttendanceRecord.fromFirestore(id, data);
        final cur = _cache[id];
        if (cur != null &&
            fsChangedFields(cur.toFirestoreData(), r.toFirestoreData()).isEmpty) {
          continue; // 内容が同じ（自分の書き込みの折り返しなど）
        }
        _cache[id] = r;
        changed = true;
      }
      st.complete();
      if (changed) notifyListeners();
    }, onError: (Object e) {
      DataErrors.report('出席の記録を読み込めませんでした（${DataErrors.describe(e)}）');
      st.complete();
    });
    return st.ready.timeout(const Duration(seconds: 10), onTimeout: () {
      debugPrint('[AttendanceService] $key first snapshot timeout');
    });
  }

  // ── 基本 CRUD ────────────────────────────────────────────────

  /// 指定日の全レコードを取得（読み込み済みの月だけ。必要なら先に [ensureDate]）
  List<AttendanceRecord> getRecordsByDate(DateTime date) {
    final key = AttendanceRecord.makeDateKey(date);
    return _cache.values.where((r) => r.dateKey == key).toList()
      ..sort((a, b) => a.customerName.compareTo(b.customerName));
  }

  /// 特定利用者・特定日のレコードを取得（なければ null）
  AttendanceRecord? getRecord(String customerId, DateTime date) =>
      _cache[AttendanceRecord.docIdOf(AttendanceRecord.makeDateKey(date), customerId)];

  /// レコードを保存・上書きする（upsert。送信は待たない）
  Future<void> upsertRecord(AttendanceRecord record, {AuditStamp? stamp}) async {
    final s = stamp ?? await StaffSession.instance.requireStamp();
    final isNew = !_cache.containsKey(record.docId);
    _cache[record.docId] = record;
    notifyListeners();
    DataErrors.send(
      _col.doc(record.docId).set({
        ...record.toFirestoreData(),
        ...(isNew ? s.toCreateFields() : s.toFields()),
      }, SetOptions(merge: true)),
      what: '${record.customerName}さんの出席記録',
    );
    debugPrint('[AttendanceService] upsert: ${record.boxKey} status=${record.status}');
  }

  /// レコードを削除する
  Future<void> deleteRecord(String customerId, DateTime date) async {
    await StaffSession.instance.requireStamp();
    final id = AttendanceRecord.docIdOf(AttendanceRecord.makeDateKey(date), customerId);
    _cache.remove(id);
    notifyListeners();
    DataErrors.send(_col.doc(id).delete(), what: '出席記録の削除');
  }

  // ── 当日スケジュール生成 ────────────────────────────────────

  /// 当日対象の顧客を scheduled レコードとして自動生成する。
  /// 既に当日のレコードが存在する場合は上書きしない。
  ///
  /// 優先順位:
  ///   1. WeeklyScheduleService に当日の週間利用計画がある場合:
  ///      planned + additional の顧客を対象にする（cancelled は除外）
  ///   2. 週間利用計画がない場合:
  ///      従来どおり customer.regularDays から生成
  ///
  ///   ScheduleEntry.plannedStartTime / plannedEndTime がある場合は
  ///   AttendanceRecord にコピーする。
  ///
  /// 【二重作成しない】1 回のトランザクションで対象のドキュメントをすべて読み、
  /// 無いものだけを作る。他の端末が同時に作っていたら、再試行で読み直して飛ばす。
  /// 通信できないときは作らずに知らせる（画面の表示は続ける）。
  Future<int> ensureTodayScheduledRecords(
    DateTime date,
    List<Customer> customers,
  ) async {
    final dateKey = AttendanceRecord.makeDateKey(date);

    // 週間利用計画と出席（Firestore）をこの日まで読み込んでから判定する。
    // 読み込む前に判定すると「計画なし」「記録なし」と誤って作ってしまう。
    await Future.wait([
      WeeklyScheduleService.instance.ensureRange(date, date),
      ensureDate(date),
    ]);

    // ── 週間利用計画から当日エントリを取得
    final weeklyEntries =
        WeeklyScheduleService.instance.getEntriesForDate(date);

    final candidates = <AttendanceRecord>[];
    final String basis;
    if (weeklyEntries.isNotEmpty) {
      // ── 週間利用計画ベース ────────────────────────────────
      // cancelled は既に除外済み（WeeklyScheduleService.getEntriesForDate）
      basis = 'weekly plan';
      final customerMap = <String, Customer>{
        for (final c in customers) c.id: c,
      };
      for (final entry in weeklyEntries) {
        // 週間計画から名前を取得（念のため Customer マスタでも上書き）
        final customerName =
            customerMap[entry.customerId]?.name ?? entry.customerName;
        candidates.add(AttendanceRecord(
          customerId: entry.customerId,
          customerName: customerName,
          dateKey: dateKey,
          status: AttendanceStatus.scheduled,
          // 週間計画の時刻設定をコピー
          plannedStartTime: _parseTimeString(dateKey, entry.plannedStartTime),
          plannedEndTime: _parseTimeString(dateKey, entry.plannedEndTime),
        ));
      }
    } else {
      // ── 従来の regularDays ベース（週間計画なし）────────────
      basis = 'regularDays fallback';
      final weekday = date.weekday; // 1=月,2=火,3=水,4=木,5=金,6=土,7=日
      for (final customer in customers) {
        if (!customer.isActive) continue;
        // 日曜（7）は regularDays には含まれないが念のためスキップ
        if (!customer.regularDays.contains(weekday)) continue;
        candidates.add(AttendanceRecord(
          customerId: customer.id,
          customerName: customer.name,
          dateKey: dateKey,
          status: AttendanceStatus.scheduled,
        ));
      }
    }

    // 端末内に既にあるものは触らない
    final missing =
        candidates.where((r) => !_cache.containsKey(r.docId)).toList();
    if (missing.isEmpty || !FacilityContext.instance.isAttached) {
      debugPrint('[AttendanceService] ensureTodayScheduled ($basis): created=0');
      return 0;
    }

    final created = <AttendanceRecord>[];
    try {
      final stamp = AuditStamp.auto.toCreateFields();
      await _runTransaction((tx) async {
        created.clear(); // 再試行のたびに数え直す
        final snaps = <DocumentSnapshot<Map<String, dynamic>>>[];
        for (final r in missing) {
          snaps.add(await tx.get(_col.doc(r.docId)));
        }
        for (var i = 0; i < missing.length; i++) {
          if (snaps[i].exists) continue; // 他の端末が作成済み
          tx.set(_col.doc(missing[i].docId),
              {...missing[i].toFirestoreData(), ...stamp});
          created.add(missing[i]);
        }
      });
    } catch (e) {
      debugPrint('[AttendanceService] ensureTodayScheduled failed: $e');
      DataErrors.report(
          '今日の予定を作成できませんでした（${DataErrors.isRetryable(e) ? '通信できません。接続を確かめて画面を開き直してください' : DataErrors.describe(e)}）');
      return 0;
    }
    for (final r in created) {
      _cache.putIfAbsent(r.docId, () => r);
    }
    if (created.isNotEmpty) notifyListeners();
    debugPrint(
      '[AttendanceService] ensureTodayScheduled ($basis): created=${created.length}',
    );
    return created.length;
  }

  /// ensureTodayScheduledRecords で利用した週間計画があるかどうかを返す
  /// （デバッグ / ホーム画面のバッジ更新用）
  bool hasWeeklyPlanForDate(DateTime date) {
    return WeeklyScheduleService.instance.getEntriesForDate(date).isNotEmpty;
  }

  // ── ステータス変更（トランザクション）──────────────────────

  /// 保存先の現在の記録を読み、[decide] の結果を書く。
  ///
  /// [decide] は現在の記録（無ければ null）を受け取り、書く記録（書かないなら null）を返す。
  /// 状態の競合は [AttendanceConflictException] を投げる。
  Future<AttendanceRecord?> _transition(
    String docId,
    AttendanceRecord? Function(AttendanceRecord? current) decide,
    AuditStamp stamp,
  ) async {
    final ref = _col.doc(docId);
    AttendanceRecord? result;
    AttendanceConflictException? conflict;
    try {
      await _runTransaction((tx) async {
        final snap = await tx.get(ref);
        final current = snap.exists && snap.data() != null
            ? AttendanceRecord.fromFirestore(docId, snap.data()!)
            : null;
        // 競合はトランザクションの外で知らせる（Web 版では処理の中で投げた例外が
        // 別の形に包まれて届き、競合として扱えなくなるため）
        conflict = null;
        AttendanceRecord? next;
        try {
          next = decide(current);
        } on AttendanceConflictException catch (c) {
          conflict = c;
          return;
        }
        result = next ?? current;
        if (next == null) return;
        tx.set(
          ref,
          {
            ...next.toFirestoreData(),
            ...(snap.exists ? stamp.toFields() : stamp.toCreateFields()),
          },
          SetOptions(merge: true),
        );
      });
    } catch (e) {
      debugPrint('[AttendanceService] transaction failed: $e');
      if (DataErrors.isRetryable(e)) throw AttendanceUnavailableException(e);
      rethrow;
    }
    final c = conflict;
    if (c != null) {
      // 画面を保存先の状態に合わせる（購読より先に知らせる）
      final fresh = await _readQuietly(ref, docId);
      if (fresh != null) {
        _cache[docId] = fresh;
        notifyListeners();
      }
      throw AttendanceConflictException(fresh?.status ?? c.current);
    }
    final r = result;
    if (r != null) {
      _cache[docId] = r;
      notifyListeners();
    }
    return r;
  }

  Future<AttendanceRecord?> _readQuietly(
    DocumentReference<Map<String, dynamic>> ref,
    String docId,
  ) async {
    try {
      final s = await ref.get().timeout(const Duration(seconds: 5));
      final d = s.data();
      return d == null ? null : AttendanceRecord.fromFirestore(docId, d);
    } catch (_) {
      return null;
    }
  }

  /// 画面に出ていた状態と保存先の状態が違えば競合
  static void _expect(AttendanceRecord current, AttendanceStatus? expected) {
    if (expected != null && current.status != expected) {
      throw AttendanceConflictException(current.status);
    }
  }

  /// 入室処理
  /// - status → present
  /// - checkInTime が未設定なら現在時刻をセット（記録した担当者も残す）
  /// - 他の端末で既に在室中なら何もしない（入室時刻を上書きしない）
  ///
  /// [expected] は操作を始めたときに画面に出ていた状態（省略時は端末内の記録の状態）。
  /// 保存先の状態がこれと違えば記録しない（他の端末の操作を逆戻りさせない）。
  Future<void> markPresent({
    required String customerId,
    required DateTime date,
    DateTime? time,
    AttendanceStatus? expected,
  }) async {
    final stamp = await StaffSession.instance.requireStamp();
    final dateKey = AttendanceRecord.makeDateKey(date);
    final docId = AttendanceRecord.docIdOf(dateKey, customerId);
    final shown = _cache[docId];
    final expectedStatus = expected ?? shown?.status;
    final now = time ?? DateTime.now();

    await _transition(docId, (existing) {
      if (existing == null) {
        // scheduled レコードがない場合でも入室可能
        return AttendanceRecord(
          customerId: customerId,
          customerName: shown?.customerName ?? '', // ensureScheduled 経由でない場合は名前不明
          dateKey: dateKey,
          status: AttendanceStatus.present,
          checkInTime: now,
          checkInByStaffId: stamp.staffId,
          checkInByStaffName: stamp.staffName,
        );
      }
      if (existing.status == AttendanceStatus.present) return null; // 既に在室中
      _expect(existing, expectedStatus);
      final setCheckIn = existing.checkInTime == null;
      return existing.copyWith(
        status: AttendanceStatus.present,
        checkInTime: existing.checkInTime ?? now,
        clearAbsenceReason: true,
      )
        ..checkInByStaffId = setCheckIn ? stamp.staffId : existing.checkInByStaffId
        ..checkInByStaffName =
            setCheckIn ? stamp.staffName : existing.checkInByStaffName;
    }, stamp);
  }

  /// 退室処理
  /// - checkInTime が null の場合は DepartResult.noCheckIn を返し保存しない
  /// - status → departed
  /// - checkOutTime が未設定なら現在時刻をセット（記録した担当者も残す）
  /// - 他の端末で既に退室済みなら何もしない（退室時刻を上書きしない）
  Future<DepartResult> markDeparted({
    required String customerId,
    required DateTime date,
    DateTime? time,
    AttendanceStatus? expected,
  }) async {
    final cached = getRecord(customerId, date);
    if (cached == null || cached.checkInTime == null) {
      return DepartResult.noCheckIn;
    }
    final stamp = await StaffSession.instance.requireStamp();
    final docId = cached.docId;
    final shown = expected ?? cached.status;
    final now = time ?? DateTime.now();
    var noCheckIn = false;

    await _transition(docId, (existing) {
      noCheckIn = false;
      if (existing == null || existing.checkInTime == null) {
        noCheckIn = true;
        return null;
      }
      if (existing.status == AttendanceStatus.departed) return null; // 既に退室済み
      _expect(existing, shown);
      final setCheckOut = existing.checkOutTime == null;
      return existing.copyWith(
        status: AttendanceStatus.departed,
        checkOutTime: existing.checkOutTime ?? now,
        clearAbsenceReason: true,
      )
        ..checkOutByStaffId = setCheckOut ? stamp.staffId : existing.checkOutByStaffId
        ..checkOutByStaffName =
            setCheckOut ? stamp.staffName : existing.checkOutByStaffName;
    }, stamp);
    return noCheckIn ? DepartResult.noCheckIn : DepartResult.success;
  }

  /// 欠席処理
  /// - status → absent
  /// - absenceReason を保存
  /// - checkInTime/checkOutTime は null にリセット
  /// - 他の端末で既に欠席・入室などになっていたら記録しない（競合）
  Future<void> markAbsent({
    required String customerId,
    required DateTime date,
    required String reason,
    AttendanceStatus? expected,
  }) async {
    final cached = getRecord(customerId, date);
    if (cached == null) return;
    final stamp = await StaffSession.instance.requireStamp();
    final shown = expected ?? cached.status;

    await _transition(cached.docId, (existing) {
      if (existing == null) return null;
      if (existing.status == AttendanceStatus.absent) {
        // 他の端末が先に欠席にしていた（理由の上書き・通知の二重起動をしない）
        throw const AttendanceConflictException(AttendanceStatus.absent);
      }
      _expect(existing, shown);
      return existing.copyWith(
        status: AttendanceStatus.absent,
        absenceReason: reason,
        clearCheckIn: true,
        clearCheckOut: true,
      );
    }, stamp);
  }

  /// 欠席取り消し
  /// - absent → scheduled
  /// - absenceReason をクリア
  /// - 他の端末で既に取り消されていたら何もしない
  Future<void> resetAbsent({
    required String customerId,
    required DateTime date,
  }) async {
    final cached = getRecord(customerId, date);
    if (cached == null || cached.status != AttendanceStatus.absent) return;
    final stamp = await StaffSession.instance.requireStamp();

    await _transition(cached.docId, (existing) {
      if (existing == null) return null;
      if (existing.status == AttendanceStatus.scheduled) return null; // 取り消し済み
      _expect(existing, AttendanceStatus.absent);
      return existing.copyWith(
        status: AttendanceStatus.scheduled,
        clearAbsenceReason: true,
        clearCheckIn: true,
        clearCheckOut: true,
      );
    }, stamp);
  }

  // ── 時刻の手動修正（項目の更新。後勝ち）────────────────────────

  Future<void> _updateFields(
    String customerId,
    DateTime date,
    AttendanceRecord Function(AttendanceRecord existing) change,
    Map<String, dynamic> Function(AttendanceRecord updated) fields,
  ) async {
    final existing = getRecord(customerId, date);
    if (existing == null) return;
    final stamp = await StaffSession.instance.requireStamp();
    final updated = change(existing);
    _cache[existing.docId] = updated;
    notifyListeners();
    DataErrors.send(
      _col.doc(existing.docId).update({...fields(updated), ...stamp.toFields()}),
      what: '${existing.customerName}さんの出席記録',
    );
  }

  /// 入室時刻を更新する
  Future<void> updateCheckInTime({
    required String customerId,
    required DateTime date,
    required DateTime newTime,
  }) =>
      _updateFields(customerId, date, (e) => e.copyWith(checkInTime: newTime),
          (u) => {'checkInTime': Timestamp.fromDate(newTime)});

  /// 退室時刻を更新する
  Future<void> updateCheckOutTime({
    required String customerId,
    required DateTime date,
    required DateTime newTime,
  }) =>
      _updateFields(customerId, date, (e) => e.copyWith(checkOutTime: newTime),
          (u) => {'checkOutTime': Timestamp.fromDate(newTime)});

  /// 備考を更新する
  Future<void> updateNote({
    required String customerId,
    required DateTime date,
    required String note,
  }) =>
      _updateFields(customerId, date, (e) => e.copyWith(note: note),
          (u) => {'note': note});

  // ── サマリー取得 ─────────────────────────────────────────────

  /// 当日の集計サマリーを返す
  ///
  /// TODO(daily_report): このメソッドで取得した AttendanceSummary を
  ///   業務日誌の「本日の利用状況」欄に連携してください。
  AttendanceSummary getTodaySummary(DateTime date) {
    final records = getRecordsByDate(date);
    int scheduled = 0, present = 0, departed = 0, absent = 0;
    for (final r in records) {
      switch (r.status) {
        case AttendanceStatus.scheduled:
          scheduled++;
          break;
        case AttendanceStatus.present:
          present++;
          break;
        case AttendanceStatus.departed:
          departed++;
          break;
        case AttendanceStatus.absent:
          absent++;
          break;
      }
    }
    return AttendanceSummary(
      scheduledCount: scheduled,
      presentCount: present,
      departedCount: departed,
      absentCount: absent,
      // 定員は設定の「1日の最大利用者数」。設定が未入力（設定の文書や項目が無い）
      // ときは AppSettings の既定値 10 名になる（設定画面に表示される値と同じ）
      capacity: SettingsService.instance.getSettings().maxStudentsPerDay,
    );
  }

  /// 欠席レコードを返す
  List<AttendanceRecord> getAbsentRecords(DateTime date) =>
      getRecordsByDate(date)
          .where((r) => r.status == AttendanceStatus.absent)
          .toList();

  /// 在室中レコードを返す
  List<AttendanceRecord> getPresentRecords(DateTime date) =>
      getRecordsByDate(date)
          .where((r) => r.status == AttendanceStatus.present)
          .toList();

  /// 退室済みレコードを返す
  List<AttendanceRecord> getDepartedRecords(DateTime date) =>
      getRecordsByDate(date)
          .where((r) => r.status == AttendanceStatus.departed)
          .toList();

  /// 未処理（scheduled のまま）のレコード数を返す（ホーム画面のバッジ用）
  int getUnprocessedCount(DateTime date) =>
      getRecordsByDate(date)
          .where((r) => r.status == AttendanceStatus.scheduled)
          .length;

  /// テスト用: 購読せずに端末内の記録だけ入れる（保存先には書かない）
  @visibleForTesting
  void debugSetCache(List<AttendanceRecord> records) {
    _cache
      ..clear()
      ..addEntries(records.map((r) => MapEntry(r.docId, r)));
    notifyListeners();
  }

  // ── プライベートヘルパー ──────────────────────────────────────

  /// "HH:mm" 形式の文字列を dateKey の日付の DateTime に変換する
  /// 変換できない場合は null を返す
  DateTime? _parseTimeString(String dateKey, String? timeStr) {
    if (timeStr == null) return null;
    try {
      // dateKey = "2026-06-15"
      final dateParts = dateKey.split('-');
      if (dateParts.length != 3) return null;
      final year = int.parse(dateParts[0]);
      final month = int.parse(dateParts[1]);
      final day = int.parse(dateParts[2]);

      // timeStr = "09:00"
      final timeParts = timeStr.split(':');
      if (timeParts.length != 2) return null;
      final hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);

      return DateTime(year, month, day, hour, minute);
    } catch (_) {
      return null;
    }
  }
}

/// 購読中の 1 か月分
class _MonthState {
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? sub;
  final Completer<void> _ready = Completer<void>();
  Future<void> get ready => _ready.future;
  bool get isReady => _ready.isCompleted;

  void complete() {
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> cancel() async {
    await sub?.cancel();
    complete();
  }
}
