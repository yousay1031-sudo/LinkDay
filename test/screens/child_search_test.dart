@Timeout(Duration(seconds: 150))
library;

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/day_ticker.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/support_plan.dart';
import 'package:linkday_app/screens/next_day_booking_screen.dart';
import 'package:linkday_app/screens/support_plan_list_screen.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:linkday_app/utils/name_search.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 児童を探す検索（翌日予約選択の「児童を追加」・個別支援計画の一覧）
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    DayTicker.instance.debugReset();
    await FakeBackend.detach();
  });

  const stamp = AuditStamp(staffId: 's-a', staffName: '職員 冬子');
  final today = DateTime(2026, 12, 1); // 火曜

  test('氏名・ふりがなの一部。ひらがな・カタカナ・空白の違いは同じに扱う', () {
    bool m(String q) => NameSearch.matches(q, name: '架空 花子', kana: 'カクウ ハナコ');
    expect(m(''), isTrue);
    expect(m('花子'), isTrue);
    expect(m('架空花子'), isTrue);
    expect(m('はなこ'), isTrue);
    expect(m('ハナ'), isTrue);
    expect(m('かくう は'), isTrue);
    expect(m('太郎'), isFalse);
    expect(NameSearch.matches('はなこ', name: '架空 花子'), isFalse); // ふりがな無し
  });

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return v;
      })) as T;

  Future<void> setUpData(WidgetTester t) => io(t, () async {
        DayTicker.instance.now = () => today.add(const Duration(hours: 16));
        await FakeBackend.attachWithStaff();
        for (final (id, name, kana, days) in [
          ('a', '架空 花子', 'カクウ ハナコ', <int>[3]),
          ('b', '架空 太郎', 'カクウ タロウ', <int>[2]),
          ('c', '見本 花代', 'ミホン ハナヨ', <int>[2]),
          ('d', '見本 次郎', 'ミホン ジロウ', <int>[4]),
        ]) {
          await CustomerService.instance.addCustomer(
              Customer(id: id, name: name, nameKana: kana, regularDays: days),
              stamp: stamp);
        }
      });

  Future<void> open(WidgetTester t, Widget home) async {
    await t.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    // PC のブラウザと同じ詰めた表示（ここで検索欄の高さが変わりやすい）
    await t.pumpWidget(MaterialApp(
        theme:
            AppTheme.lightTheme.copyWith(visualDensity: VisualDensity.compact),
        home: home));
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  Future<void> type(WidgetTester t, String key, String text) async {
    await t.enterText(find.byKey(Key(key)), text);
    await t.pumpAndSettle();
  }

  bool shown(WidgetTester t, String key) =>
      find.byKey(Key(key)).evaluate().isNotEmpty;

  testWidgets('翌日予約選択の「児童を追加」: 打つたびに絞り込み、該当なしを出し、消す印で戻る', (t) async {
    await setUpData(t);
    await open(t, NextDayBookingScreen(initialDate: DateTime(2026, 12, 2)));
    await t.tap(find.byKey(const Key('nextDayAdd')));
    await t.pumpAndSettle();
    // 水曜に予定がある a は候補に出ない
    expect([
      for (final id in ['a', 'b', 'c', 'd']) shown(t, 'nextDayAddPick_$id')
    ], [
      false,
      true,
      true,
      true
    ]);
    final fieldBefore = t.getRect(find.byKey(const Key('nextDayAddSearch')));
    await type(t, 'nextDayAddSearch', 'はな'); // ふりがな（ひらがな）
    // 消す印が出ても検索欄の大きさは変わらない
    expect(t.getRect(find.byKey(const Key('nextDayAddSearch'))), fieldBefore);
    expect([
      for (final id in ['b', 'c', 'd']) shown(t, 'nextDayAddPick_$id')
    ], [
      false,
      true,
      false
    ]);
    await type(t, 'nextDayAddSearch', '架空'); // 氏名
    expect([
      for (final id in ['b', 'c', 'd']) shown(t, 'nextDayAddPick_$id')
    ], [
      true,
      false,
      false
    ]);
    await type(t, 'nextDayAddSearch', '該当しない名前');
    expect(find.text('該当する児童はいません'), findsOneWidget);
    await t.tap(find.byKey(const Key('nextDayAddSearchClear')));
    await t.pumpAndSettle();
    expect([
      for (final id in ['b', 'c', 'd']) shown(t, 'nextDayAddPick_$id')
    ], [
      true,
      true,
      true
    ]);
  });

  testWidgets('個別支援計画の一覧: 氏名・ふりがなと、知らせの種類で絞り込める', (t) async {
    await setUpData(t);
    await io(t, () async {
      final col = FakeBackend.current.db
          .collection(FsPaths.facilities)
          .doc(FakeBackend.current.facilityId)
          .collection(FsPaths.supportPlans);
      SupportPlan p(String id, String cid, DateTime created) => SupportPlan(
          id: id,
          customerId: cid,
          customerName: cid,
          createdOn: created,
          managerName: '職員 冬子',
          explainedOn: created,
          agreedOn: created);
      // a: 期限切れ（期限 2026-10-01）、b: 期限間近（12/10）、c: アセスメント（2027-01-05）、d: 未作成
      for (final x in [
        p('pa', 'a', DateTime(2026, 4, 1)),
        p('pb', 'b', DateTime(2026, 6, 10)),
        p('pc', 'c', DateTime(2026, 7, 5)),
      ]) {
        await col.doc(x.id).set({
          ...x.toFirestoreData(),
          'status': 'agreed',
          'updatedByStaffName': '職員 冬子',
        });
      }
    });
    await open(t, SupportPlanListScreen(today: today));
    List<bool> entries() => [
          for (final id in ['a', 'b', 'c', 'd']) shown(t, 'planEntry_$id')
        ];
    expect(entries(), [true, true, true, true]);
    await type(t, 'planListSearch', 'みほん');
    expect(entries(), [false, false, true, true]);
    await t.tap(find.byKey(const Key('planListSearchClear')));
    await t.pumpAndSettle();
    for (final (kind, expected) in [
      ('overdue', [true, false, false, false]),
      ('near', [false, true, false, false]),
      ('assessment', [false, false, true, false]),
      ('noPlan', [false, false, false, true]),
      ('all', [true, true, true, true]),
    ]) {
      await t.tap(find.byKey(Key('planListKind_$kind')));
      await t.pumpAndSettle();
      expect(entries(), expected, reason: kind);
    }
    // 打ち始めて消す印が出ても、検索欄の高さと下の選択肢の位置は変わらない
    await t.tap(find.byKey(const Key('planListKind_all')));
    await type(t, 'planListSearch', '');
    final fieldBefore = t.getRect(find.byKey(const Key('planListSearch')));
    final chipBefore = t.getRect(find.byKey(const Key('planListKind_near')));
    await type(t, 'planListSearch', 'か');
    expect(find.byKey(const Key('planListSearchClear')), findsOneWidget);
    expect(t.getRect(find.byKey(const Key('planListSearch'))), fieldBefore);
    expect(t.getRect(find.byKey(const Key('planListKind_near'))), chipBefore);
    await type(t, 'planListSearch', '');
    // 種類と検索の組み合わせで該当なし
    await t.tap(find.byKey(const Key('planListKind_overdue')));
    await t.pumpAndSettle();
    await type(t, 'planListSearch', '次郎');
    expect(find.text('該当する児童はいません'), findsOneWidget);
  });
}
