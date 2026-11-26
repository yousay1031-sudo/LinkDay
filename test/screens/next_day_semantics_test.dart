@Timeout(Duration(seconds: 150))
library;

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/day_ticker.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/next_day_booking_screen.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 翌日予約選択: 時間のボタンの読み上げ（別のファイルにした: 読み上げを有効にすると同じファイルの後のテストに影響するため）
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    DayTicker.instance.debugReset();
    WeeklyScheduleService.instance.debugCreateError = null;
    await FakeBackend.detach();
  });

  const stamp = AuditStamp(staffId: 's-a', staffName: '職員 冬子');
  // 今日は 2026-12-01（火）。明日 12-02（水）
  final today = DateTime(2026, 12, 1);

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return v;
      })) as T;

  Future<void> setUpData(WidgetTester t,
          {int count = 3, String? currentStaffId = 's-a', int capacity = 10}) =>
      io(t, () async {
        DayTicker.instance.now = () => today.add(const Duration(hours: 16));
        await FakeBackend.attach(
            staff: const [FakeBackend.staffA, FakeBackend.staffB],
            currentStaffId: currentStaffId);
        await CustomerService.instance.addCustomer(
            Customer(
                id: 'c1',
                name: '架空 一',
                nameKana: 'カクウ イチ',
                regularDays: [1, 3],
                transportLocations: ['架空の家']),
            stamp: stamp);
        for (var i = 2; i <= count; i++) {
          await CustomerService.instance.addCustomer(
              Customer(
                  id: 'c$i',
                  name: '架空 児童$i',
                  nameKana: 'カクウ ジドウ${i.toString().padLeft(2, '0')}',
                  regularDays: [3]),
              stamp: stamp);
        }
        await CustomerService.instance.addCustomer(
            Customer(
                id: 'x1',
                name: '架空 追加',
                nameKana: 'カクウ ツイカ',
                regularDays: [2],
                monthlyAvailableDays: 1),
            stamp: stamp);
        final s = SettingsService.instance.getSettings();
        SettingsService.instance.debugSetSettings(AppSettings(
            facilityName: s.facilityName, maxStudentsPerDay: capacity));
      });

  Future<void> open(WidgetTester t,
      {Size size = const Size(1280, 900), DateTime? date}) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: NextDayBookingScreen(initialDate: date)));
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  testWidgets('時間のボタンは読み上げで独立したボタン（カード全体はボタンにしない）', (t) async {
    final h = t.ensureSemantics();
    await setUpData(t);
    await open(t);
    final btn = t
        .getSemantics(find.byKey(const Key('nextDayTimeBtn_c1')))
        .getSemanticsData();
    expect(btn.flagsCollection.isButton, isTrue);
    expect(btn.label, '架空 一さんの時間を変える');
    final card = t
        .getSemantics(find.byKey(const Key('nextDayCard_c1')))
        .getSemanticsData();
    expect(card.label.contains('時間を変える'), isFalse);
    h.dispose();
  });
}
