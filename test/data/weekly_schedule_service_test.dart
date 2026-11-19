import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/utils/week_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 段階4: 週間利用計画を「顧客×日」に分けて Firestore に置いたことの確認
final _monday = DateTime(2026, 11, 23); // 月曜
final _weekKey = WeekUtil.weekKeyFromDate(_monday);
final _customers = [
  Customer(id: 'c1', name: 'あ 一郎', nameKana: 'ア イチロウ', regularDays: [1, 3]),
  Customer(id: 'c2', name: 'い 花子', nameKana: 'イ ハナコ', regularDays: [1, 2]),
];

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

CollectionReference<Map<String, dynamic>> _entries() =>
    FacilityContext.instance.col(FsPaths.scheduleEntries);
CollectionReference<Map<String, dynamic>> _weeks() =>
    FacilityContext.instance.col(FsPaths.scheduleWeeks);

Future<Map<String, Map<String, dynamic>>> _storedEntries() async => {
      for (final d in (await _entries().get()).docs) d.id: d.data(),
    };

WeeklyScheduleService get _svc => WeeklyScheduleService.instance;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FakeBackend.attachWithStaff();
  });
  tearDown(FakeBackend.detach);

  test('1 マス = 1 ドキュメント（{日付}_{顧客ID}）と週の目印で保存する', () async {
    final w = await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    final stored = await _storedEntries();
    expect(stored.keys.toSet(), {
      '2026-11-23_c1', '2026-11-25_c1', // 月・水
      '2026-11-23_c2', '2026-11-24_c2', // 月・火
    });
    expect(stored['2026-11-23_c1'], containsPair('weekKey', _weekKey));
    expect(stored['2026-11-23_c1'], containsPair('status', 'planned'));
    expect(stored['2026-11-23_c1'], containsPair('updatedByStaffName', '自動'),
        reason: '週の自動作成は担当者なしで「自動」');
    final marker = (await _weeks().doc(_weekKey).get()).data()!;
    expect(marker['weekStartDate'], '2026-11-23');
    expect(w.slotForDay(1)!.entries.map((e) => e.customerId), ['c1', 'c2']);
  });

  test('同じ週の別のマスを 2 台で編集しても、両方の変更が残る', () async {
    final held = await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    // この端末: 月曜の c1 をキャンセル
    await _svc.updateEntryStatus(_weekKey, 1, 'c1', ScheduleStatus.cancelled);
    // 別の端末: 火曜の c2 の時刻を変更（この端末を通らない書き込み）
    await _entries().doc('2026-11-24_c2').update({
      'plannedStartTime': '13:00',
      'updatedByStaffName': '佐藤',
    });
    await _settle();

    final stored = await _storedEntries();
    expect(stored['2026-11-23_c1']!['status'], 'cancelled');
    expect(stored['2026-11-24_c2']!['plannedStartTime'], '13:00');
    // 画面が持っている同じオブジェクトに、別の端末の変更が反映される
    expect(held.slotForDay(2)!.findEntry('c2')!.plannedStartTime, '13:00');
    expect(held.slotForDay(1)!.findEntry('c1')!.status, ScheduleStatus.cancelled);
    expect(identical(_svc.getScheduleByWeekKey(_weekKey), held), isTrue);
  });

  test('変えたマスだけを書く（担当者を記録）', () async {
    await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    await _svc.updateEntryTimes(_weekKey, 3, 'c1', '10:00', '16:00');
    await _settle();
    final stored = await _storedEntries();
    expect(stored['2026-11-25_c1']!['plannedStartTime'], '10:00');
    expect(stored['2026-11-25_c1']!['updatedByStaffName'], '山田');
    expect(stored['2026-11-23_c1']!['updatedByStaffName'], '自動',
        reason: '他のマスは書かない');
  });

  test('全員を消した週は、定期利用曜日から作り直さない（週の目印）', () async {
    await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    for (final (day, id) in [(1, 'c1'), (3, 'c1'), (1, 'c2'), (2, 'c2')]) {
      await _svc.removeEntry(_weekKey, day, id);
    }
    await _settle();
    expect(await _storedEntries(), isEmpty);

    await FakeBackend.reloadSchedules(); // 再読み込み・別端末で開いた場合
    final w = await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    expect(w.dailySlots.expand((s) => s.entries), isEmpty);
    expect(await _storedEntries(), isEmpty);
  });

  test('他の端末が先に週を作っていたら、作り直さず（上書きせず）その内容を使う', () async {
    // 別の端末が作成済み: 月曜の c1 はキャンセル済み
    await _weeks().doc(_weekKey).set({
      'weekKey': _weekKey,
      'weekStartDate': '2026-11-23',
      'note': null,
    });
    await _entries().doc('2026-11-23_c1').set({
      'date': '2026-11-23',
      'weekKey': _weekKey,
      'customerId': 'c1',
      'customerName': 'あ 一郎',
      'status': 'cancelled',
    });
    await FakeBackend.reloadSchedules();
    final w = await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    expect(w.slotForDay(1)!.findEntry('c1')!.status, ScheduleStatus.cancelled);
    expect((await _storedEntries()).keys, ['2026-11-23_c1'],
        reason: '定期利用曜日の予定を足さない');
  });

  test('同時に作成しても、後から動いた側は作成を飛ばす（トランザクション）', () async {
    final a = _svc.getOrCreateSchedule(_monday, _customers);
    final b = _svc.getOrCreateSchedule(_monday, _customers);
    final results = await Future.wait([a, b]);
    await _settle();
    expect((await _storedEntries()).length, 4);
    expect(results[0].dailySlots.expand((s) => s.entries).length, 4);
    expect(results[1].dailySlots.expand((s) => s.entries).length, 4);
  });

  test('担当者が未選択なら編集を止め、画面にも保存先にも反映しない', () async {
    await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    StaffSession.instance.debugSet(
        facilityId: FakeBackend.defaultFacilityId, staffId: null);
    await expectLater(
        _svc.updateEntryStatus(_weekKey, 1, 'c1', ScheduleStatus.cancelled),
        throwsA(isA<StaffNotSelectedException>()));
    await _settle();
    expect(_svc.getScheduleByWeekKey(_weekKey)!.slotForDay(1)!.findEntry('c1')!.status,
        ScheduleStatus.planned);
    expect((await _storedEntries())['2026-11-23_c1']!['status'], 'planned');
  });

  test('翌週へのコピーは翌週の内容を置き換え、キャンセルは引き継がない', () async {
    await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    await _svc.updateEntryStatus(_weekKey, 1, 'c2', ScheduleStatus.cancelled);
    // 翌週に元からあった予定（コピーで消える）
    final next = WeekUtil.nextWeekStart(_monday);
    final nextKey = WeekUtil.weekKeyFromDate(next);
    await _svc.getOrCreateSchedule(next, [
      Customer(id: 'c9', name: 'ん 九郎', nameKana: 'ン', regularDays: [5]),
    ]);
    await _settle();

    await _svc.copyScheduleToNextWeek(_weekKey);
    await _settle();
    final stored = await _storedEntries();
    final nextIds = stored.keys.where((k) => stored[k]!['weekKey'] == nextKey).toSet();
    expect(nextIds, {'2026-11-30_c1', '2026-12-02_c1', '2026-12-01_c2'});
    expect(stored['2026-11-30_c1']!['status'], 'planned');
  });

  test('定期利用曜日から再生成: 追加・キャンセルは残し、予定だけ作り直す', () async {
    await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    await _svc.updateEntryStatus(_weekKey, 1, 'c1', ScheduleStatus.cancelled);
    final changed = [
      _customers[0],
      Customer(id: 'c2', name: 'い 花子', nameKana: 'イ ハナコ', regularDays: [5]),
    ];
    await _svc.regenerateFromRegularDays(_weekKey, changed);
    await _settle();
    final stored = await _storedEntries();
    expect(stored.keys.toSet(), {'2026-11-23_c1', '2026-11-25_c1', '2026-11-27_c2'});
    expect(stored['2026-11-23_c1']!['status'], 'cancelled');
  });

  test('別の端末の変更で変更通知が出る（画面を開き直さずに反映）', () async {
    await _svc.getOrCreateSchedule(_monday, _customers);
    await _settle();
    var notified = 0;
    void onChange() => notified++;
    _svc.addListener(onChange);
    addTearDown(() => _svc.removeListener(onChange));
    await _entries().doc('2026-11-27_c2').set({
      'date': '2026-11-27',
      'weekKey': _weekKey,
      'customerId': 'c2',
      'customerName': 'い 花子',
      'status': 'additional',
    });
    await _settle();
    expect(notified, greaterThan(0));
    expect(_svc.getEntriesForDate(DateTime(2026, 11, 27)).single.customerId, 'c2');
  });
}
