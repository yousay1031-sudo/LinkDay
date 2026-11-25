// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:linkday_app/data/account_session.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/screens/login_history_screen.dart';
import 'package:linkday_app/screens/staff_management_screen.dart';
import 'package:linkday_app/services/login_history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ2 段階5: ログイン履歴
void main() {
  setUpAll(() => initializeDateFormatting('ja_JP'));
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    LoginHistoryService.instance.authTimeProvider = null;
    await LoginHistoryService.instance.stop();
    await FakeBackend.detach();
  });

  const admin = FakeBackend.adminStaff;
  const haru = Staff(
      id: 's-haru', name: '職員 春子', loginEnabled: true, hasGoogleEmail: true);

  CollectionReference<Map<String, dynamic>> col(FakeBackend b) => b.db
      .collection(FsPaths.facilities)
      .doc(b.facilityId)
      .collection(FsPaths.loginHistory);

  test('個人アカウント: 1 回のログインにつき 1 件。再読み込み（同じ auth_time）では増えない', () async {
    final b = await FakeBackend.attach(
        staff: const [admin, haru], personalStaffId: haru.id);
    LoginHistoryService.instance.authTimeProvider = () async => 1764000000;
    await LoginHistoryService.instance.recordLogin('g-haru');
    await LoginHistoryService.instance.recordLogin('g-haru'); // 再読み込み
    final docs = (await col(b).get()).docs;
    expect(docs.map((d) => d.id), ['g-haru_1764000000']);
    final d = docs.single.data();
    expect(d['uid'], 'g-haru');
    expect(d['kind'], 'personal');
    expect(d['staffId'], haru.id);
    expect(d['staffName'], '職員 春子');
    expect(d['authTime'], 1764000000);
    expect(d['at'], isA<Timestamp>());
    expect(d.keys.toSet(),
        {'uid', 'kind', 'staffId', 'staffName', 'at', 'authTime'});

    // ログインし直す（auth_time が変わる）と 2 件目
    LoginHistoryService.instance.authTimeProvider = () async => 1764003600;
    await LoginHistoryService.instance.recordLogin('g-haru');
    expect((await col(b).get()).docs.length, 2);
  });

  test('共用端末アカウント: 種類は shared、職員は記録しない（担当者はログイン後に選ぶため）', () async {
    final b = await FakeBackend.attachWithStaff();
    LoginHistoryService.instance.authTimeProvider = () async => 1764000000;
    await LoginHistoryService.instance.recordLogin('shared-uid');
    final d = (await col(b).get()).docs.single.data();
    expect(d['kind'], 'shared');
    expect(d['staffId'], isNull);
    expect(d['staffName'], isNull);
  });

  test('ログインの時刻が分からなければ記録しない', () async {
    final b = await FakeBackend.attachWithStaff();
    await LoginHistoryService.instance.recordLogin('u'); // 未設定
    LoginHistoryService.instance.authTimeProvider = () async => null;
    await LoginHistoryService.instance.recordLogin('u');
    expect((await col(b).get()).docs, isEmpty);
  });

  test('管理者だけが一覧を読み、職員ごとの最後のログインが分かる', () async {
    final b = await FakeBackend.attach(
        staff: const [admin, haru],
        personalStaffId: admin.id,
        currentStaffId: admin.id);
    await col(b).doc('g-haru_1').set({
      'uid': 'g-haru',
      'kind': 'personal',
      'staffId': haru.id,
      'staffName': '職員 春子',
      'at': Timestamp.fromDate(DateTime(2026, 11, 20, 9, 5)),
      'authTime': 1,
    });
    await col(b).doc('g-haru_2').set({
      'uid': 'g-haru',
      'kind': 'personal',
      'staffId': haru.id,
      'staffName': '職員 春子',
      'at': Timestamp.fromDate(DateTime(2026, 11, 24, 18, 30)),
      'authTime': 2,
    });
    await col(b).doc('shared_3').set({
      'uid': 'shared',
      'kind': 'shared',
      'staffId': null,
      'staffName': null,
      'at': Timestamp.fromDate(DateTime(2026, 11, 25, 8, 0)),
      'authTime': 3,
    });
    LoginHistoryService.instance.start();
    await pumpEventQueue();
    expect(LoginHistoryService.instance.recent.map((e) => e.id),
        ['shared_3', 'g-haru_2', 'g-haru_1']);
    expect(LoginHistoryService.instance.lastLoginOf(haru.id),
        DateTime(2026, 11, 24, 18, 30));
  });

  test('管理者でなければ購読しない（ルールでも読めない）', () async {
    final b = await FakeBackend.attach(
        staff: const [admin, haru], personalStaffId: haru.id);
    await col(b)
        .doc('x')
        .set({'uid': 'x', 'kind': 'shared', 'at': Timestamp.now()});
    LoginHistoryService.instance.start();
    await pumpEventQueue();
    expect(LoginHistoryService.instance.isLoaded, isFalse);
    expect(LoginHistoryService.instance.recent, isEmpty);
    expect(AccountSession.instance.isAdmin, isFalse);
  });

  for (final w in const [1280.0, 820.0, 530.0]) {
    testWidgets('職員管理: 最終ログインの行があっても幅 ${w.toInt()} で崩れない（役割の名前が長くても）',
        (t) async {
      await t.binding.setSurfaceSize(Size(w, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      const long = Staff(
        id: 's-long',
        name: '職員 長子',
        kana: 'しょくいん ながこ',
        role: StaffRole.childDevManager,
        workDays: [1, 2, 3, 4, 5],
        canDrive: true,
        loginEnabled: true,
        hasGoogleEmail: true,
      );
      await t.runAsync(() async {
        final b = await FakeBackend.attach(
            staff: const [admin, long],
            personalStaffId: admin.id,
            currentStaffId: admin.id);
        await col(b).doc('x_1').set({
          'uid': 'x',
          'kind': 'personal',
          'staffId': long.id,
          'staffName': '職員 長子',
          'at': Timestamp.fromDate(DateTime(2026, 11, 24, 18, 30)),
          'authTime': 1,
        });
        LoginHistoryService.instance.start();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpWidget(const MaterialApp(home: StaffManagementScreen()));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('最終ログイン 11/24 18:30'), findsOneWidget);
    });
  }

  testWidgets('職員管理: 管理者には最後のログインと履歴の入口が出る。管理者でなければ出ない', (t) async {
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    late FakeBackend b;
    await t.runAsync(() async {
      b = await FakeBackend.attach(
          staff: const [admin, haru],
          personalStaffId: admin.id,
          currentStaffId: admin.id);
      await col(b).doc('g-haru_2').set({
        'uid': 'g-haru',
        'kind': 'personal',
        'staffId': haru.id,
        'staffName': '職員 春子',
        'at': Timestamp.fromDate(DateTime(2026, 11, 24, 18, 30)),
        'authTime': 2,
      });
      LoginHistoryService.instance.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpWidget(const MaterialApp(home: StaffManagementScreen()));
    await t.pumpAndSettle();
    expect(find.textContaining('最終ログイン 11/24 18:30'), findsOneWidget);
    await t.tap(find.byKey(const Key('openLoginHistory')));
    await t.pumpAndSettle();
    expect(find.byType(LoginHistoryScreen), findsOneWidget);
    expect(find.text('職員 春子'), findsOneWidget);
    expect(find.textContaining('個人アカウント（Google）'), findsOneWidget);

    await t.pumpWidget(const SizedBox.shrink());
    await t.runAsync(() async {
      await LoginHistoryService.instance.stop();
      AccountSession.instance
          .debugSet(kind: AccountKind.personal, staffId: haru.id);
      LoginHistoryService.instance.start();
    });
    await t.pumpWidget(const MaterialApp(home: StaffManagementScreen()));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('openLoginHistory')), findsNothing);
    expect(find.textContaining('最終ログイン'), findsNothing);
  });
}
