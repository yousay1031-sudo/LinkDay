@Timeout(Duration(seconds: 150))
library;

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/models/support_plan.dart';
import 'package:linkday_app/screens/customer_edit_screen.dart';
import 'package:linkday_app/screens/daily_journal_screen.dart';
import 'package:linkday_app/screens/staff_edit_screen.dart';
import 'package:linkday_app/screens/support_plan_edit_screen.dart';
import 'package:linkday_app/services/daily_journal_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 選択肢（押して選ぶ札）は、選ぶ前と後でどの札も位置と大きさが変わらない。
/// 続けて押したとき、狙った札だけが変わる。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    DailyJournalService.instance.now = DateTime.now;
    await FakeBackend.detach();
  });

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return v;
      })) as T;

  Future<void> open(WidgetTester t, Widget home) async {
    await t.binding.setSurfaceSize(const Size(1280, 1400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(theme: AppTheme.lightTheme, home: home));
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  /// [chips] の位置と大きさを記録し、[toTap] を順に押して、どれも変わらないこと・
  /// 押したものだけ選んだ状態が変わることを確かめる
  Future<void> check(WidgetTester t, Finder chips, List<int> toTap,
      bool Function(Widget) isSelected) async {
    final n = chips.evaluate().length;
    expect(n, greaterThan(toTap.length));
    await t.ensureVisible(chips.first);
    await t.pumpAndSettle();
    final before = [for (var i = 0; i < n; i++) t.getRect(chips.at(i))];
    final selBefore = [
      for (var i = 0; i < n; i++) isSelected(t.widget(chips.at(i)))
    ];
    for (final i in toTap) {
      await t.tap(chips.at(i));
      await io(t, () async {});
      await t.pumpAndSettle();
      final now = [for (var j = 0; j < n; j++) t.getRect(chips.at(j))];
      expect(now, before, reason: '$i 番目を押した後に位置か大きさが変わった');
    }
    for (var i = 0; i < n; i++) {
      final sel = isSelected(t.widget(chips.at(i)));
      expect(sel, toTap.contains(i) ? !selBefore[i] : selBefore[i],
          reason: '$i 番目の選んだ状態');
    }
  }

  bool filterSel(Widget w) => (w as FilterChip).selected;

  testWidgets('業務日誌: 今日いた職員・その日の内容', (t) async {
    await io(t, () async {
      await FakeBackend.attach(staff: const [
        Staff(id: 's-a', name: '職員 冬子'),
        Staff(id: 's-b', name: '職員 夏男'),
        Staff(id: 's-c', name: '職員 秋子'),
      ], currentStaffId: 's-a');
      DailyJournalService.instance.now = () => DateTime(2026, 12, 1, 18);
    });
    await open(t, DailyJournalScreen(initialDate: DateTime(2026, 12, 1)));
    await check(
        t,
        find.byWidgetPredicate((w) =>
            w is FilterChip && w.key.toString().contains('journalActivity_')),
        [0, 2, 3, 5],
        filterSel);
    await check(
        t,
        find.byWidgetPredicate((w) =>
            w is FilterChip && w.key.toString().contains('journalStaff_')),
        [0, 1],
        filterSel);
  });

  testWidgets('個別支援計画: 項目・5領域・達成時期・担当者', (t) async {
    await io(
        t,
        () => FakeBackend.attach(staff: const [
              Staff(id: 's-a', name: '職員 冬子'),
              Staff(id: 's-b', name: '職員 夏男')
            ], currentStaffId: 's-a'));
    await open(
        t,
        SupportPlanEditScreen(
            plan: SupportPlan(
              id: 'p1',
              customerId: 'c1',
              customerName: '架空 一郎',
              createdOn: DateTime(2026, 12, 1),
              rows: const [
                SupportPlanRow(categories: ['self'])
              ],
            ),
            isNew: true));
    Finder row(String part) => find.byWidgetPredicate(
        (w) => w is FilterChip && w.key.toString().contains('planRow_0_$part'));
    await check(t, row('cat_'), [1, 2], filterSel);
    await check(t, row('dom_'), [0, 2, 4], filterSel);
    await check(t, row('period_'), [1], filterSel);
    await check(t, row('staff_'), [1], filterSel);
  });

  testWidgets('職員管理: 勤務日', (t) async {
    const st = Staff(id: 's-a', name: '職員 冬子', workDays: [1]);
    await io(
        t, () => FakeBackend.attach(staff: const [st], currentStaffId: 's-a'));
    await open(t, const StaffEditScreen(staff: st));
    await check(
        t,
        find.byWidgetPredicate(
            (w) => w is FilterChip && w.key.toString().contains('staffDay_')),
        [1, 2, 6],
        filterSel);
  });

  testWidgets('顧客管理: 利用曜日・性別', (t) async {
    await io(t, FakeBackend.attachWithStaff);
    await open(
        t,
        CustomerEditScreen(
            customer: Customer(
                id: 'c1',
                name: '架空 一郎',
                nameKana: 'カクウ イチロウ',
                regularDays: [1])));
    // 表示だけの画面なら編集に切り替える
    final editButton = find.byTooltip('編集');
    if (editButton.evaluate().isNotEmpty) {
      await t.tap(editButton);
      await t.pumpAndSettle();
    }
    final days = find.byType(FilterChip);
    await t.ensureVisible(days.first);
    await t.pumpAndSettle();
    await check(t, days, [1, 3], filterSel);
    final gender = find.byType(ChoiceChip);
    await t.ensureVisible(gender.first);
    await t.pumpAndSettle();
    await check(t, gender, [0], (w) => (w as ChoiceChip).selected);
  });
}
