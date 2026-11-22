import 'dart:io';

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/attendance_screen.dart';
import 'package:linkday_app/screens/customer_management_screen.dart';
import 'package:linkday_app/screens/home_screen.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/monthly_usage_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 手直し: 一覧とカードの縦の長さを中身に合わせて詰めた。
/// どの幅でも中身があふれない（RenderFlex overflow が出ない）こと、
/// 入室・退室・欠席のボタンが高さ 48 以上であることを確かめる。
const _sizes = [
  Size(1280, 900),
  Size(820, 1180),
  Size(530, 900),
  Size(390, 844)
];

Future<void> _ms(WidgetTester t, int ms) async {
  var left = ms;
  while (left > 0) {
    final step = left > 16 ? 16 : left;
    await t.pump(Duration(milliseconds: step));
    left -= step;
  }
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_dense_');
    Hive.init(tmp.path);
    await FakeBackend.attachWithStaff();
    await SettingsService.instance.init();
    SlotService.instance.remoteEnabled = false;
    AppMotion.debugDisableLooping = true;
  });

  tearDownAll(() async {
    AppMotion.debugDisableLooping = false;
    await Future.any<Object?>([
      Hive.close(),
      Future<Object?>.delayed(const Duration(seconds: 3)),
    ]);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> seed(WidgetTester t) => t.runAsync(() async {
        await FakeBackend.resetAttendance();
        await FakeBackend.resetCustomers();
        final key = AttendanceRecord.makeDateKey(DateTime.now());
        final today = DateTime.now();
        DateTime at(int h, int m) =>
            DateTime(today.year, today.month, today.day, h, m);
        final records = [
          AttendanceRecord(
              customerId: 'a1', customerName: '予定 一郎', dateKey: key),
          AttendanceRecord(
              customerId: 'a2',
              customerName: '在室 花子',
              dateKey: key,
              status: AttendanceStatus.present,
              checkInTime: at(10, 5)),
          AttendanceRecord(
              customerId: 'a3',
              customerName: '検証用ダミーの非常に長い氏名 一郎ジョセフ',
              dateKey: key,
              status: AttendanceStatus.departed,
              checkInTime: at(10, 5),
              checkOutTime: at(15, 30)),
          AttendanceRecord(
              customerId: 'a4',
              customerName: '欠席 次郎',
              dateKey: key,
              status: AttendanceStatus.absent,
              absenceReason: 'その他：長めの欠席理由が入った場合の表示を確かめるための文章'),
        ];
        for (final r in records) {
          await AttendanceService.instance.upsertRecord(r);
        }
        for (var i = 0; i < 6; i++) {
          await CustomerService.instance.addCustomer(Customer(
            id: 'c$i',
            name: i == 0 ? '検証用ダミーの非常に長い氏名 一郎ジョセフ' : '顧客 $i',
            nameKana: 'コキャク $i',
            regularDays: [1, 2, 3, 4, 5, 6],
            recipientCertExpiry: today.add(Duration(days: 10 + i)),
          ));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

  for (final size in _sizes) {
    final w = size.width.toInt();

    testWidgets('出席管理: 幅 $w でカードの中身があふれず、ボタンは高さ 48 以上', (t) async {
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await seed(t);
      await t.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme, home: const AttendanceScreen()));
      await _ms(t, 1500);
      expect(t.takeException(), isNull);
      for (final label in ['入室', '欠席', '退室', '欠席を取り消す']) {
        final btn = find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
        if (btn.evaluate().isEmpty) continue; // 画面外のカード
        expect(t.getSize(btn.first).height, greaterThanOrEqualTo(48),
            reason: '「$label」の高さ');
      }
      await t.pumpWidget(const SizedBox.shrink());
      await _ms(t, 3000);
    });

    testWidgets('顧客管理: 幅 $w でカードの中身があふれない', (t) async {
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await seed(t);
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: CustomerManagementScreen(
            usageLoader: () => MonthlyUsageService.instance
                .getAllUsage(DateTime.now(), reconcileCache: false)),
      ));
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await _ms(t, 1500);
      expect(t.takeException(), isNull);
      expect(find.textContaining('今月'), findsWidgets);
      await t.pumpWidget(const SizedBox.shrink());
      await _ms(t, 3000);
    });

    // ホームは幅 600 以上だけ（テスト用の文字は実際の文字より横幅が広く、狭い幅では
    // 今回変えていない上部の日付・件数の行があふれる。幅 530 はブラウザで確認）
    if (size.width >= 600) {
      testWidgets('ホーム: 幅 $w でメニューの中身があふれず、押す場所は高さ 48 以上', (t) async {
        await t.binding.setSurfaceSize(size);
        addTearDown(() => t.binding.setSurfaceSize(null));
        await t.pumpWidget(
            MaterialApp(theme: AppTheme.lightTheme, home: const HomeScreen()));
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await _ms(t, 1500);
        expect(t.takeException(), isNull);
        final tile = find.byKey(const ValueKey('homeMenu_/customers'));
        expect(t.getSize(tile).height, greaterThanOrEqualTo(48));
        await t.pumpWidget(const SizedBox.shrink());
        await _ms(t, 3000);
      });
    }
  }
}
