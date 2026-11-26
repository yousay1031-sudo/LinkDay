import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/audit.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';
import '../data/fs_values.dart';
import '../data/staff_session.dart';
import '../models/customer.dart';
import '../models/weekly_schedule.dart';
import '../utils/week_util.dart';

/// 週間利用計画サービス
///
/// 保存先（Firestore、facilities/{facilityId}/ の下）:
/// - `scheduleEntries/{YYYY-MM-DD}_{customerId}` … 1件の利用予定（顧客×日）。
///   以前は「1週間 = 1データ」だったため、2台で同じ週の別のマスを編集すると
///   片方が消えた。マスごとに分けたので、別のマスの編集は両方残る。
///   同じマスへの書き込みは後勝ち。
/// - `scheduleWeeks/{weekKey}` … 「この週は作成済み」の目印（weekStartDate, note）。
///   これが無いと「まだ作っていない週」と「全員を消した週」を見分けられず、
///   消した週が定期利用曜日から作り直されてしまう。
///
/// 画面には従来どおり [WeeklySchedule]（週 → 7日 → エントリ）の形で渡す。
/// 週ごとに購読し、他の端末の変更は同じオブジェクトの中身を書き換えて反映する
/// （画面が持っているオブジェクトが古くならないように）。変更は [ChangeNotifier] で知らせる。
///
/// 書き込みは「前回の内容と違うマスだけ」を 1 回の一括書き込み（batch）で送る。
/// 担当者が必要（未選択なら選択画面）。週の自動作成は「自動」と記録する。
class WeeklyScheduleService extends ChangeNotifier {
  WeeklyScheduleService._();
  static final WeeklyScheduleService instance = WeeklyScheduleService._();

  final Map<String, WeeklySchedule> _weeks = {};
  final Map<String, _WeekState> _states = {};
  bool _attached = false;

  bool get isAttached => _attached;

  CollectionReference<Map<String, dynamic>> get _entriesCol =>
      FacilityContext.instance.col(FsPaths.scheduleEntries);
  CollectionReference<Map<String, dynamic>> get _weeksCol =>
      FacilityContext.instance.col(FsPaths.scheduleWeeks);

  // ── 接続 ────────────────────────────────────────────────────

  /// ログイン後に呼ぶ。今月の初めから 4 週先までを先に読み込む
  /// （出席・送迎・月間集計が同期で読む範囲）。
  Future<void> attach({DateTime? today}) async {
    await detach();
    _attached = true;
    final t = today ?? DateTime.now();
    await ensureRange(DateTime(t.year, t.month, 1), t.add(const Duration(days: 28)));
    debugPrint('[WeeklyScheduleService] attached: weeks=${_weeks.length}');
  }

  Future<void> detach() async {
    for (final s in _states.values) {
      await s.cancel();
    }
    _states.clear();
    _weeks.clear();
    _attached = false;
  }

  /// [from]〜[to] を含む週を購読し、最初の読み込みを待つ
  Future<void> ensureRange(DateTime from, DateTime to) async {
    var monday = WeekUtil.weekStartFromDate(from);
    final last = WeekUtil.weekStartFromDate(to);
    final futures = <Future<void>>[];
    while (!monday.isAfter(last)) {
      futures.add(ensureWeek(WeekUtil.weekKeyFromDate(monday)));
      monday = WeekUtil.nextWeekStart(monday);
    }
    await Future.wait(futures);
  }

  /// 週 [weekKey] を購読し、最初のスナップショット（端末内キャッシュ由来でも可）を待つ
  Future<void> ensureWeek(String weekKey) {
    if (!FacilityContext.instance.isAttached) return Future.value();
    final existing = _states[weekKey];
    if (existing != null) {
      // 読み込み済みなら、その場で完了する Future を返す（呼び出し側の zone で解決させる）
      return existing.isReady ? Future<void>.value() : existing.ready;
    }
    final st = _WeekState(weekKey);
    _states[weekKey] = st;
    st.entriesSub = _entriesCol
        .where('weekKey', isEqualTo: weekKey)
        .snapshots()
        .listen((snap) => _onEntries(st, snap), onError: (Object e) {
      DataErrors.report('週間利用計画を読み込めませんでした（${DataErrors.describe(e)}）');
      st.entriesSeen = true;
      st.checkReady();
    });
    st.markerSub = _weeksCol.doc(weekKey).snapshots().listen(
        (snap) => _onMarker(st, snap), onError: (Object e) {
      st.markerSeen = true;
      st.checkReady();
    });
    return st.ready.timeout(const Duration(seconds: 10), onTimeout: () {
      debugPrint('[WeeklyScheduleService] $weekKey first snapshot timeout');
    });
  }

  void _onMarker(_WeekState st, DocumentSnapshot<Map<String, dynamic>> snap) {
    final data = snap.data();
    st.markerBase = data == null ? null : _markerFields(data);
    st.markerSeen = true;
    final changed = _syncWeekObject(st);
    if (data != null) {
      final w = _weeks[st.weekKey];
      final note = readString(data['note']);
      if (w != null && w.note != note) w.note = note;
    }
    st.checkReady();
    if (changed) notifyListeners();
  }

  void _onEntries(_WeekState st, QuerySnapshot<Map<String, dynamic>> snap) {
    var changed = false;
    for (final ch in snap.docChanges) {
      final id = ch.doc.id;
      final data =
          ch.type == DocumentChangeType.removed ? null : ch.doc.data();
      final fields = data == null ? null : _entryFields(data);
      st.lastSeen[id] = fields;
      if (data == null) {
        st.updatedAt.remove(id);
      } else {
        // 未確定の書き込みはサーバーの時刻がまだ無い（届いた時刻で代える）
        st.updatedAt[id] = readTimestamp(data['updatedAt']) ?? DateTime.now();
      }
      // この端末の書き込みが未確定のマスは、古い通知で上書きしない
      if ((st.pending[id] ?? 0) > 0) continue;
      changed |= _applyDoc(st, id, fields);
    }
    st.entriesSeen = true;
    changed |= _syncWeekObject(st);
    st.checkReady();
    if (changed) notifyListeners();
  }

  /// 保存先のマス 1 件を、画面用の週オブジェクトに反映する（変化があれば true）
  bool _applyDoc(_WeekState st, String id, Map<String, dynamic>? fields) {
    final base = st.entriesBase[id];
    if (fields == null && base == null) return false;
    if (fields != null && base != null && fsChangedFields(base, fields).isEmpty) {
      return false; // 自分の書き込みの折り返し
    }
    if (fields == null) {
      st.entriesBase.remove(id);
    } else {
      st.entriesBase[id] = fields;
    }
    final w = _weeks[st.weekKey];
    if (w == null) {
      // 週オブジェクトがまだ無い: 基準（このマスを含む）から組み立てる
      _syncWeekObject(st);
      return true;
    }
    final date = dateOnlyFromString((fields ?? base)!['date']);
    final customerId = (fields ?? base)!['customerId'] as String?;
    if (date == null || customerId == null) return true;
    final slot = w.slotForDate(date);
    if (slot == null) return true;
    final idx = slot.entries.indexWhere((e) => e.customerId == customerId);
    if (fields == null) {
      if (idx >= 0) slot.entries.removeAt(idx);
      return true;
    }
    final e = _entryFromFields(fields);
    if (idx >= 0) {
      final cur = slot.entries[idx];
      cur
        ..customerName = e.customerName
        ..status = e.status
        ..plannedStartTime = e.plannedStartTime
        ..plannedEndTime = e.plannedEndTime
        ..transportLocationIndex = e.transportLocationIndex
        ..note = e.note;
    } else {
      slot.entries.add(e);
      slot.entries.sort((a, b) => a.customerName.compareTo(b.customerName));
    }
    return true;
  }

  /// 目印またはマスがあれば週オブジェクトを用意し、どちらも無ければ消す
  bool _syncWeekObject(_WeekState st) {
    final exists = st.markerBase != null || st.entriesBase.isNotEmpty;
    final cur = _weeks[st.weekKey];
    if (exists && cur == null) {
      final w = _emptyWeek(st.weekKey, note: st.markerBase?['note'] as String?);
      for (final f in st.entriesBase.values) {
        final date = dateOnlyFromString(f['date']);
        final slot = date == null ? null : w.slotForDate(date);
        slot?.entries.add(_entryFromFields(f));
      }
      for (final s in w.dailySlots) {
        s.entries.sort((a, b) => a.customerName.compareTo(b.customerName));
      }
      _weeks[st.weekKey] = w;
      return true;
    }
    if (!exists && cur != null && st.markerSeen && st.entriesSeen) {
      _weeks.remove(st.weekKey);
      return true;
    }
    return false;
  }

  // ── 基本 CRUD ────────────────────────────────────────────────

  /// 読み込み済みの週（作成済みでなければ null）
  WeeklySchedule? getScheduleByWeekKey(String weekKey) => _weeks[weekKey];

  /// 週の内容を保存する（前回の内容と違うマスだけを書く）。
  ///
  /// [stamp] を省略すると担当者を求める。担当者が選ばれなければ
  /// 画面の内容を保存先の状態に戻して [StaffNotSelectedException] を投げる。
  Future<void> saveSchedule(WeeklySchedule schedule, {AuditStamp? stamp}) async {
    await ensureWeek(schedule.weekKey);
    final st = _states[schedule.weekKey];
    if (st == null) return; // 未接続（ログイン前）
    final current = _weeks[schedule.weekKey];
    if (!identical(current, schedule)) _weeks[schedule.weekKey] = schedule;
    if (!_hasChanges(st, schedule)) return;
    AuditStamp s;
    try {
      s = stamp ?? await StaffSession.instance.requireStamp();
    } on StaffNotSelectedException {
      _rebuildFromBase(st);
      notifyListeners();
      rethrow;
    }
    _write(st, schedule, s);
    schedule.updatedAt = DateTime.now();
    notifyListeners();
  }

  /// 週を削除する（目印と全マス）。
  Future<void> deleteSchedule(String weekKey) async {
    await ensureWeek(weekKey);
    final st = _states[weekKey];
    if (st == null) return;
    await StaffSession.instance.requireStamp();
    final batch = FacilityContext.instance.db.batch();
    for (final id in st.entriesBase.keys.toList()) {
      batch.delete(_entriesCol.doc(id));
      _markPending(st, id);
    }
    batch.delete(_weeksCol.doc(weekKey));
    final ids = st.entriesBase.keys.toList();
    st.entriesBase.clear();
    st.markerBase = null;
    _weeks.remove(weekKey);
    notifyListeners();
    _sendBatch(st, batch, ids, what: '週間利用計画（$weekKey）の削除');
  }

  // ── 取得または新規作成 ────────────────────────────────────────

  /// 指定週のスケジュールを取得、なければ regularDays から自動生成して返す
  ///
  /// 作成は「目印が無いことをサーバーで確かめてから書く」トランザクション。
  /// 2台が同時に開いても、後から動いた側は作成を飛ばす。担当者は不要（「自動」）。
  Future<WeeklySchedule> getOrCreateSchedule(
    DateTime weekStart,
    List<Customer> customers,
  ) async {
    final weekKey = WeekUtil.weekKeyFromDate(weekStart);
    await ensureWeek(weekKey);
    final existing = _weeks[weekKey];
    if (existing != null) return existing;

    final monday = WeekUtil.weekStartFromKey(weekKey);
    final fresh = buildFromRegularDays(monday, weekKey, customers);
    final st = _states[weekKey];
    if (st == null) return fresh; // 未接続（ログイン前）

    bool created;
    try {
      created = await _createWithTransaction(fresh)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      // 通信できない等: 仮の案は出さない（通信が戻ってから作る。画面は再試行を出す）
      debugPrint('[WeeklyScheduleService] create $weekKey failed: $e');
      throw WeekUnavailableException(weekKey, e);
    }
    if (created) {
      // 送った内容を基準にする（折り返しの通知では画面を作り直さない）
      st.markerBase = _markerFields(_markerData(fresh));
      for (final e in _docsOf(fresh).entries) {
        st.entriesBase[e.key] = e.value;
      }
      _weeks[weekKey] = _weeks[weekKey] ?? fresh;
      notifyListeners();
      return _weeks[weekKey]!;
    }
    // 他の端末が先に作っていた: 購読に届くのを待つ
    for (var i = 0; i < 50 && _weeks[weekKey] == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _weeks[weekKey] ?? fresh;
  }

  /// テスト用: 週の自動作成の前にこの例外を投げる（通信できない状態の再現）
  @visibleForTesting
  Object? debugCreateError;

  Future<bool> _createWithTransaction(WeeklySchedule fresh) async {
    final err = debugCreateError;
    if (err != null) throw err;
    final markerRef = _weeksCol.doc(fresh.weekKey);
    final docs = _docsOf(fresh);
    final stamp = AuditStamp.auto.toCreateFields();
    return FacilityContext.instance.db.runTransaction<bool>((tx) async {
      final m = await tx.get(markerRef);
      if (m.exists) return false;
      tx.set(markerRef, {..._markerData(fresh), ...stamp});
      for (final e in docs.entries) {
        tx.set(_entriesCol.doc(e.key), {...e.value, ...stamp});
      }
      return true;
    });
  }

  // ── regularDays 同期 ─────────────────────────────────────────

  /// planned エントリだけ最新の regularDays に同期する
  /// additional / cancelled は手動編集済みなので保持する
  Future<WeeklySchedule> regenerateFromRegularDays(
    String weekKey,
    List<Customer> customers,
  ) async {
    await ensureWeek(weekKey);
    final stamp = await StaffSession.instance.requireStamp();
    final existing = _weeks[weekKey];
    if (existing == null) {
      final monday = WeekUtil.weekStartFromKey(weekKey);
      final fresh = buildFromRegularDays(monday, weekKey, customers);
      await saveSchedule(fresh, stamp: stamp);
      return fresh;
    }

    // planned を削除して再構築、additional/cancelled は保持
    for (final slot in existing.dailySlots) {
      slot.entries.removeWhere((e) => e.status == ScheduleStatus.planned);
    }

    // 新しい planned を追加
    final customerMap = <String, Customer>{
      for (final c in customers) c.id: c,
    };
    for (final slot in existing.dailySlots) {
      for (final customer in customers) {
        if (!customer.isActive) continue;
        if (!customer.regularDays.contains(slot.dayOfWeek)) continue;
        // already has additional or cancelled → skip adding planned
        final alreadyExists =
            slot.entries.any((e) => e.customerId == customer.id);
        if (alreadyExists) continue;
        slot.entries.add(ScheduleEntry(
          customerId: customer.id,
          customerName: customer.name,
          status: ScheduleStatus.planned,
        ));
      }
      // 氏名スナップショットを更新
      for (final entry in slot.entries) {
        final c = customerMap[entry.customerId];
        if (c != null) entry.customerName = c.name;
      }
      // 氏名順にソート
      slot.entries.sort((a, b) => a.customerName.compareTo(b.customerName));
    }

    await saveSchedule(existing, stamp: stamp);
    return existing;
  }

  // ── エントリ操作 ──────────────────────────────────────────────
  //
  // 担当者を先に確かめてから画面の内容を変える（選ばれなければ何も変えない）。

  Future<WeeklySchedule?> _editable(String weekKey) async {
    await ensureWeek(weekKey);
    return _weeks[weekKey];
  }

  /// エントリを追加する（同一 customerId が既にあれば上書き）
  Future<void> addEntry(
    String weekKey,
    int dayOfWeek,
    ScheduleEntry entry,
  ) async {
    final schedule = await _editable(weekKey);
    if (schedule == null) return;
    final slot = schedule.slotForDay(dayOfWeek);
    if (slot == null) return;
    final stamp = await StaffSession.instance.requireStamp();

    final idx = slot.entries.indexWhere((e) => e.customerId == entry.customerId);
    if (idx >= 0) {
      slot.entries[idx] = entry;
    } else {
      slot.entries.add(entry);
      slot.entries.sort((a, b) => a.customerName.compareTo(b.customerName));
    }
    await saveSchedule(schedule, stamp: stamp);
  }

  /// エントリを削除する
  Future<void> removeEntry(
    String weekKey,
    int dayOfWeek,
    String customerId,
  ) async {
    final schedule = await _editable(weekKey);
    if (schedule == null) return;
    final slot = schedule.slotForDay(dayOfWeek);
    if (slot == null) return;
    final stamp = await StaffSession.instance.requireStamp();

    slot.entries.removeWhere((e) => e.customerId == customerId);
    await saveSchedule(schedule, stamp: stamp);
  }

  /// エントリのステータスを更新する
  Future<void> updateEntryStatus(
    String weekKey,
    int dayOfWeek,
    String customerId,
    ScheduleStatus newStatus,
  ) async {
    final schedule = await _editable(weekKey);
    if (schedule == null) return;
    final slot = schedule.slotForDay(dayOfWeek);
    if (slot == null) return;
    if (slot.entries.indexWhere((e) => e.customerId == customerId) < 0) return;
    final stamp = await StaffSession.instance.requireStamp();

    final idx = slot.entries.indexWhere((e) => e.customerId == customerId);
    if (idx < 0) return;
    slot.entries[idx] = slot.entries[idx].copyWith(status: newStatus);
    await saveSchedule(schedule, stamp: stamp);
  }

  /// エントリの時刻を更新する
  Future<void> updateEntryTimes(
    String weekKey,
    int dayOfWeek,
    String customerId,
    String? startTime,
    String? endTime,
  ) async {
    final schedule = await _editable(weekKey);
    if (schedule == null) return;
    final slot = schedule.slotForDay(dayOfWeek);
    if (slot == null) return;
    if (slot.entries.indexWhere((e) => e.customerId == customerId) < 0) return;
    final stamp = await StaffSession.instance.requireStamp();

    final idx = slot.entries.indexWhere((e) => e.customerId == customerId);
    if (idx < 0) return;
    slot.entries[idx] = slot.entries[idx].copyWith(
      plannedStartTime: startTime,
      plannedEndTime: endTime,
    );
    await saveSchedule(schedule, stamp: stamp);
  }

  // ── 日付ベースの参照 ─────────────────────────────────────────

  /// [date] を含む週の週間利用計画があるか（週の目印かマスがある。読み込み済みの週だけ）。
  ///
  /// 「その日の有効な予定が 0 件」とは違う。全員をキャンセルにした日は、週はあるが
  /// 有効な予定が 0 件（誰も来ない日）。出席・送迎の「計画が無い週は利用曜日から」の
  /// 判定はこちらを使う。
  bool hasWeekFor(DateTime date) =>
      _weeks.containsKey(WeekUtil.weekKeyFromDate(date));

  /// 当日出席管理から呼ぶ: 指定日の有効エントリ（planned + additional）を返す
  /// 該当週のスケジュールがなければ空リストを返す
  /// （読み込み済みの週だけを見る。必要なら先に [ensureRange] を待つ）
  List<ScheduleEntry> getEntriesForDate(DateTime date) {
    final weekKey = WeekUtil.weekKeyFromDate(date);
    final schedule = _weeks[weekKey];
    if (schedule == null) return [];

    final slot = schedule.slotForDate(date);
    if (slot == null) return [];

    return slot.entries
        .where((e) => e.status != ScheduleStatus.cancelled)
        .toList();
  }

  // ── 翌日予約選択（ステップ4）──────────────────────────────────

  /// 指定日のすべての予定（キャンセルを含む。読み込み済みの週だけ）
  List<ScheduleEntry> getAllEntriesForDate(DateTime date) {
    final schedule = _weeks[WeekUtil.weekKeyFromDate(date)];
    final slot = schedule?.slotForDate(date);
    return slot == null ? const [] : List.of(slot.entries);
  }

  /// 指定日の予定のうち、いちばん新しい更新時刻（予定が無ければ null）
  DateTime? latestUpdateOn(DateTime date) {
    final st = _states[WeekUtil.weekKeyFromDate(date)];
    if (st == null) return null;
    final prefix = '${dateOnlyToString(date)}_';
    DateTime? latest;
    for (final e in st.updatedAt.entries) {
      if (!e.key.startsWith(prefix)) continue;
      if (latest == null || e.value.isAfter(latest)) latest = e.value;
    }
    return latest;
  }

  /// 「利用する」に戻したときの状態（その曜日が利用曜日なら通常、違えば追加）
  static ScheduleStatus useStatusFor(Customer c, DateTime date) =>
      c.regularDays.contains(date.weekday)
          ? ScheduleStatus.planned
          : ScheduleStatus.additional;

  /// 「利用する／お休み」（担当者が必要）。お休みは予定をキャンセルにする（消さない）。
  /// 利用するに戻すと、利用曜日なら通常、違えば追加の予定になる。
  Future<void> setUse(DateTime date, Customer c, {required bool use}) =>
      updateEntryStatus(WeekUtil.weekKeyFromDate(date), date.weekday, c.id,
          use ? useStatusFor(c, date) : ScheduleStatus.cancelled);

  /// 同じ週のほかの日の、その児童の予定時刻（追加したときの初期値。無ければ null）。
  /// いちばん多い組み合わせ、同じ数なら [date] に近い日のもの。
  (String?, String?)? sameWeekTimesFor(String customerId, DateTime date) {
    final schedule = _weeks[WeekUtil.weekKeyFromDate(date)];
    if (schedule == null) return null;
    final counts = <(String?, String?), int>{};
    final nearest = <(String?, String?), int>{};
    for (final slot in schedule.dailySlots) {
      if (slot.date == date) continue;
      for (final e in slot.entries) {
        if (e.customerId != customerId) continue;
        if (e.plannedStartTime == null && e.plannedEndTime == null) continue;
        final k = (e.plannedStartTime, e.plannedEndTime);
        counts[k] = (counts[k] ?? 0) + 1;
        final dist = slot.date.difference(date).inDays.abs();
        nearest[k] = nearest[k] == null || dist < nearest[k]! ? dist : nearest[k]!;
      }
    }
    (String?, String?)? best;
    for (final k in counts.keys) {
      if (best == null ||
          counts[k]! > counts[best]! ||
          (counts[k] == counts[best] && nearest[k]! < nearest[best]!)) {
        best = k;
      }
    }
    return best;
  }

  /// その日に予定の無い児童を「追加」の予定として足す（担当者が必要）。
  /// 予定時刻は同じ週のほかの日の予定時刻（無ければ空）。
  Future<void> addExtra(DateTime date, Customer c) async {
    final times = sameWeekTimesFor(c.id, date);
    await addEntry(
      WeekUtil.weekKeyFromDate(date),
      date.weekday,
      ScheduleEntry(
        customerId: c.id,
        customerName: c.name,
        status: ScheduleStatus.additional,
        plannedStartTime: times?.$1,
        plannedEndTime: times?.$2,
      ),
    );
  }

  // ── 利用日数集計 ─────────────────────────────────────────────

  /// 指定顧客の月間利用予定日数を集計（cancelled 除く。読み込み済みの週だけ）
  int countUsageByCustomer(
    String customerId,
    DateTime monthStart,
    DateTime monthEnd,
  ) {
    int count = 0;
    for (final schedule in _weeks.values) {
      // 週が月の範囲内か
      final weekEnd = schedule.weekStartDate.add(const Duration(days: 6));
      if (weekEnd.isBefore(monthStart)) continue;
      if (schedule.weekStartDate.isAfter(monthEnd)) continue;

      for (final slot in schedule.dailySlots) {
        if (slot.date.isBefore(monthStart)) continue;
        if (slot.date.isAfter(monthEnd)) continue;
        for (final entry in slot.entries) {
          if (entry.customerId != customerId) continue;
          if (entry.status == ScheduleStatus.cancelled) continue;
          count++;
        }
      }
    }
    return count;
  }

  // ── 翌週コピー ────────────────────────────────────────────────

  /// 現在の週を翌週にコピー（planned/additional だけ、cancelled は引き継がない）
  ///
  /// 翌週の内容は置き換わる（呼び出し元の画面で確認ダイアログを出す）。
  Future<WeeklySchedule> copyScheduleToNextWeek(String fromWeekKey) async {
    final nextMonday = WeekUtil.nextWeekStart(
      WeekUtil.weekStartFromKey(fromWeekKey),
    );
    final nextWeekKey = WeekUtil.weekKeyFromDate(nextMonday);
    await Future.wait([ensureWeek(fromWeekKey), ensureWeek(nextWeekKey)]);
    final stamp = await StaffSession.instance.requireStamp();
    final source = _weeks[fromWeekKey];

    if (source == null) {
      // 元が存在しない → 空のスケジュールを作成
      final empty = _emptyWeek(nextWeekKey);
      await saveSchedule(empty, stamp: stamp);
      return empty;
    }

    // ソースの planned/additional だけコピー
    final target = _emptyWeek(nextWeekKey, note: _weeks[nextWeekKey]?.note);
    for (var i = 0; i < 7; i++) {
      target.dailySlots[i].entries.addAll(source.dailySlots[i].entries
          .where((e) => e.status != ScheduleStatus.cancelled)
          .map((e) => ScheduleEntry(
                customerId: e.customerId,
                customerName: e.customerName,
                // additional → planned に戻す（翌週は通常予定として扱う）
                status: ScheduleStatus.planned,
                plannedStartTime: e.plannedStartTime,
                plannedEndTime: e.plannedEndTime,
                transportLocationIndex: e.transportLocationIndex,
                note: e.note,
              )));
    }
    // 画面が持っている翌週のオブジェクトをそのまま書き換える
    final shown = _weeks[nextWeekKey];
    if (shown != null) {
      for (var i = 0; i < 7; i++) {
        shown.dailySlots[i].entries
          ..clear()
          ..addAll(target.dailySlots[i].entries);
      }
      await saveSchedule(shown, stamp: stamp);
      return shown;
    }
    await saveSchedule(target, stamp: stamp);
    return target;
  }

  // ── 保存の内部処理 ──────────────────────────────────────────

  bool _hasChanges(_WeekState st, WeeklySchedule w) {
    if (st.markerBase == null) return true;
    if (fsChangedFields(st.markerBase, _markerFields(_markerData(w))).isNotEmpty) {
      return true;
    }
    final docs = _docsOf(w);
    if (docs.length != st.entriesBase.length) return true;
    for (final e in docs.entries) {
      final base = st.entriesBase[e.key];
      if (base == null || fsChangedFields(base, e.value).isNotEmpty) return true;
    }
    return false;
  }

  void _write(_WeekState st, WeeklySchedule w, AuditStamp s) {
    final docs = _docsOf(w);
    final ops = <void Function(WriteBatch)>[];
    final touched = <String>[];
    // 目印
    final marker = _markerData(w);
    final markerRef = _weeksCol.doc(w.weekKey);
    if (st.markerBase == null) {
      ops.add((b) => b.set(markerRef, {...marker, ...s.toCreateFields()}));
    } else {
      final ch = fsChangedFields(st.markerBase, _markerFields(marker));
      if (ch.isNotEmpty) ops.add((b) => b.update(markerRef, {...ch, ...s.toFields()}));
    }
    st.markerBase = _markerFields(marker);
    // 追加・変更されたマス
    for (final e in docs.entries) {
      final base = st.entriesBase[e.key];
      final ref = _entriesCol.doc(e.key);
      if (base == null) {
        ops.add((b) => b.set(ref, {...e.value, ...s.toCreateFields()}));
      } else {
        final ch = fsChangedFields(base, e.value);
        if (ch.isEmpty) continue;
        ops.add((b) => b.update(ref, {...ch, ...s.toFields()}));
      }
      st.entriesBase[e.key] = e.value;
      touched.add(e.key);
    }
    // 消されたマス
    for (final id in st.entriesBase.keys.toList()) {
      if (docs.containsKey(id)) continue;
      ops.add((b) => b.delete(_entriesCol.doc(id)));
      st.entriesBase.remove(id);
      touched.add(id);
    }
    if (ops.isEmpty) return;
    // 一括書き込みは 500 件まで
    for (var i = 0; i < ops.length; i += 450) {
      final batch = FacilityContext.instance.db.batch();
      for (final op in ops.skip(i).take(450)) {
        op(batch);
      }
      final ids = i == 0 ? touched : const <String>[];
      for (final id in ids) {
        _markPending(st, id);
      }
      _sendBatch(st, batch, ids, what: '週間利用計画（${w.weekKey}）');
    }
    debugPrint('[WeeklyScheduleService] saved: ${w.weekKey} '
        '(${ops.length} 件) by $s');
  }

  void _markPending(_WeekState st, String id) {
    st.pending[id] = (st.pending[id] ?? 0) + 1;
    st.updatedAt[id] = DateTime.now();
  }

  void _sendBatch(_WeekState st, WriteBatch batch, List<String> ids,
      {required String what}) {
    DataErrors.send(
      batch.commit().whenComplete(() {
        // 送信が確定したマスは、その後に届いた保存先の内容に合わせる
        var changed = false;
        for (final id in ids) {
          final n = (st.pending[id] ?? 1) - 1;
          if (n > 0) {
            st.pending[id] = n;
            continue;
          }
          st.pending.remove(id);
          if (st.lastSeen.containsKey(id)) {
            changed |= _applyDoc(st, id, st.lastSeen[id]);
          }
        }
        if (changed) notifyListeners();
      }),
      what: what,
    );
  }

  /// 担当者が選ばれず保存しなかったとき: 画面の内容を保存先の状態に戻す
  void _rebuildFromBase(_WeekState st) {
    _weeks.remove(st.weekKey);
    _syncWeekObject(st);
  }

  // ── 変換 ────────────────────────────────────────────────────

  static String entryDocId(DateTime date, String customerId) =>
      '${dateOnlyToString(date)}_$customerId';

  /// 週の全マス（docId → 保存する項目）
  static Map<String, Map<String, dynamic>> _docsOf(WeeklySchedule w) => {
        for (final slot in w.dailySlots)
          for (final e in slot.entries)
            entryDocId(slot.date, e.customerId): {
              'date': dateOnlyToString(slot.date),
              'weekKey': w.weekKey,
              'customerId': e.customerId,
              'customerName': e.customerName,
              'status': e.status.name,
              'plannedStartTime': e.plannedStartTime,
              'plannedEndTime': e.plannedEndTime,
              'transportLocationIndex': e.transportLocationIndex,
              'note': e.note,
            },
      };

  static Map<String, dynamic> _entryFields(Map<String, dynamic> d) => {
        'date': readString(d['date']),
        'weekKey': readString(d['weekKey']),
        'customerId': readString(d['customerId']),
        'customerName': readString(d['customerName']) ?? '',
        'status': readString(d['status']) ?? ScheduleStatus.planned.name,
        'plannedStartTime': readString(d['plannedStartTime']),
        'plannedEndTime': readString(d['plannedEndTime']),
        'transportLocationIndex': d['transportLocationIndex'] is num
            ? (d['transportLocationIndex'] as num).toInt()
            : null,
        'note': readString(d['note']),
      };

  static ScheduleEntry _entryFromFields(Map<String, dynamic> f) => ScheduleEntry(
        customerId: f['customerId'] as String? ?? '',
        customerName: f['customerName'] as String? ?? '',
        status: ScheduleStatus.values.firstWhere(
          (s) => s.name == f['status'],
          orElse: () => ScheduleStatus.planned,
        ),
        plannedStartTime: f['plannedStartTime'] as String?,
        plannedEndTime: f['plannedEndTime'] as String?,
        transportLocationIndex: f['transportLocationIndex'] as int?,
        note: f['note'] as String?,
      );

  static Map<String, dynamic> _markerData(WeeklySchedule w) => {
        'weekKey': w.weekKey,
        'weekStartDate': dateOnlyToString(w.weekStartDate),
        'note': w.note,
      };

  static Map<String, dynamic> _markerFields(Map<String, dynamic> d) => {
        'weekKey': readString(d['weekKey']),
        'weekStartDate': readString(d['weekStartDate']),
        'note': readString(d['note']),
      };

  static WeeklySchedule _emptyWeek(String weekKey, {String? note}) {
    final monday = WeekUtil.weekStartFromKey(weekKey);
    return WeeklySchedule(
      id: weekKey,
      weekStartDate: monday,
      weekKey: weekKey,
      note: note,
    );
  }

  // ── 定期利用曜日からの生成（検証データの組み立てにも使う） ──────────

  static WeeklySchedule buildFromRegularDays(
    DateTime monday,
    String weekKey,
    List<Customer> customers,
  ) {
    final slots = List.generate(7, (i) {
      final date = monday.add(Duration(days: i));
      final dayOfWeek = date.weekday; // 1=月〜7=日
      final entries = <ScheduleEntry>[];

      for (final customer in customers) {
        if (!customer.isActive) continue;
        if (!customer.regularDays.contains(dayOfWeek)) continue;
        entries.add(ScheduleEntry(
          customerId: customer.id,
          customerName: customer.name,
          status: ScheduleStatus.planned,
        ));
      }
      // 氏名順
      entries.sort((a, b) => a.customerName.compareTo(b.customerName));

      return DailySlot(date: date, dayOfWeek: dayOfWeek, entries: entries);
    });

    return WeeklySchedule(
      id: weekKey,
      weekStartDate: monday,
      weekKey: weekKey,
      dailySlots: slots,
    );
  }
}

/// まだ無い週を作れなかった（通信できない等）。画面は理由と再試行を出す。
class WeekUnavailableException implements Exception {
  WeekUnavailableException(this.weekKey, this.cause);
  final String weekKey;
  final Object cause;

  String get message => DataErrors.isRetryable(cause)
      ? '通信できないため、この週の計画を作成できません。\n接続を確かめて再試行してください。'
      : 'この週の計画を作成できませんでした（${DataErrors.describe(cause)}）。\n再試行してください。';

  @override
  String toString() => message;
}

/// 購読中の 1 週分の状態
class _WeekState {
  _WeekState(this.weekKey);

  final String weekKey;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? entriesSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? markerSub;

  /// 最後に保存先と一致していたマス（docId → 項目）
  final Map<String, Map<String, dynamic>> entriesBase = {};

  /// 最後に届いた保存先のマス（null は削除）。未確定の書き込みが終わった後に反映する
  final Map<String, Map<String, dynamic>?> lastSeen = {};

  /// この端末の書き込みが未確定のマス（docId → 件数）
  final Map<String, int> pending = {};

  /// マスごとの最後の更新時刻（保存先の updatedAt。この端末の未確定の書き込みは
  /// 書いた時刻）。翌日予約選択の「確認後に変更あり」に使う
  final Map<String, DateTime> updatedAt = {};

  /// 目印（null = 未作成）
  Map<String, dynamic>? markerBase;

  bool markerSeen = false;
  bool entriesSeen = false;
  final Completer<void> _ready = Completer<void>();
  Future<void> get ready => _ready.future;
  bool get isReady => _ready.isCompleted;

  void checkReady() {
    if (markerSeen && entriesSeen && !_ready.isCompleted) _ready.complete();
  }

  Future<void> cancel() async {
    await entriesSub?.cancel();
    await markerSub?.cancel();
    if (!_ready.isCompleted) _ready.complete();
  }
}
