@Timeout(Duration(seconds: 90))
library;

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/screens/inactive_staff_screen.dart';
import 'package:linkday_app/screens/staff_edit_screen.dart';
import 'package:linkday_app/screens/staff_management_screen.dart';
import 'package:linkday_app/services/staff_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 職員管理の画面（一覧・編集・在籍終了）
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  const admin = FakeBackend.adminStaff;
  const a = Staff(
    id: 's-a',
    name: '山田 花子',
    kana: 'やまだ はなこ',
    role: StaffRole.childDevManager,
    workDays: [1, 3, 5],
    canDrive: true,
  );
  const b = FakeBackend.staffB;

  /// 偽の保存先との読み書きは本物の時間で動かす（テスト用の時計では進まないため）
  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return v;
      })) as T;

  Future<void> asAdmin() => FakeBackend.attach(
        staff: const [admin, a, b],
        currentStaffId: admin.id,
        personalStaffId: admin.id,
        emails: {admin.id: 'admin@example.invalid'},
      );

  Future<void> asShared() =>
      FakeBackend.attach(staff: const [admin, a, b], currentStaffId: admin.id);

  Future<void> asNonAdminPersonal() => FakeBackend.attach(
      staff: const [admin, a, b], currentStaffId: a.id, personalStaffId: a.id);

  Future<void> open(WidgetTester t, Widget home,
      {Size size = const Size(1280, 900)}) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(home: home));
    await t.pumpAndSettle();
  }

  group('一覧', () {
    for (final size in const [
      Size(1280, 900),
      Size(820, 1000),
      Size(530, 900)
    ]) {
      testWidgets('幅 ${size.width.toInt()} で崩れず、1件の高さは顧客管理と同じ', (t) async {
        await io(t, asAdmin);
        await open(t, const StaffManagementScreen(), size: size);
        expect(t.takeException(), isNull);
        final card = find.byKey(Key('staffCard_${a.id}'));
        expect(card, findsOneWidget);
        final cols = StaffManagementScreen.columnCount(size.width - 0);
        expect(
            t.getSize(card).height,
            moreOrLessEquals(StaffManagementScreen.cardExtent(cols),
                epsilon: 1));
        expect(t.getSize(card).height, greaterThanOrEqualTo(48));
        expect(find.text('山田 花子'), findsOneWidget);
        expect(find.textContaining('勤務 月・水・金'), findsOneWidget);
        expect(find.text('送迎可'), findsWidgets);
        expect(find.text('ログイン：未登録'), findsWidgets);
        expect(find.text('ログイン：許可'), findsOneWidget); // 管理者
      });
    }

    testWidgets('在籍終了の職員は一覧に出ず、別の画面に分かれる', (t) async {
      await io(t, asAdmin);
      await io(t, () => StaffService.instance.deactivateStaff(b.id));
      await open(t, const StaffManagementScreen());
      expect(find.byKey(Key('staffCard_${b.id}')), findsNothing);
      await t.tap(find.byKey(const Key('openInactiveStaff')));
      await t.pumpAndSettle();
      expect(find.byType(InactiveStaffScreen), findsOneWidget);
      expect(find.byKey(Key('inactiveStaff_${b.id}')), findsOneWidget);
    });

    testWidgets('管理者には「職員を登録」が出る。管理者でなければ出ず、理由が出る', (t) async {
      await io(t, asAdmin);
      await open(t, const StaffManagementScreen());
      expect(find.byKey(const Key('staffAddFab')), findsOneWidget);
      expect(find.byKey(const Key('staffListAdminNote')), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
      await io(t, FakeBackend.detach);

      await io(t, asShared);
      await open(t, const StaffManagementScreen());
      expect(find.byKey(const Key('staffAddFab')), findsNothing);
      expect(find.byKey(const Key('staffListAdminNote')), findsOneWidget);
      expect(find.textContaining('共用端末のアカウントでは変更できません'), findsOneWidget);
    });
  });

  group('編集', () {
    testWidgets('管理者でない個人アカウント: 管理者だけの項目は表示するが編集できない', (t) async {
      await io(t, asNonAdminPersonal);
      await open(
          t, StaffEditScreen(staff: StaffService.instance.getById(admin.id)));
      expect(find.byKey(const Key('staffAdminOnlyReason')), findsOneWidget);
      expect(find.text('管理者だけが変更できます。'), findsWidgets);
      // アドレスは読めない（登録の有無だけ）
      expect(find.byKey(const Key('staffEmailField')), findsNothing);
      expect(find.text('登録済み'), findsOneWidget);
      final sw =
          t.widget<SwitchListTile>(find.byKey(const Key('staffAdminSwitch')));
      expect(sw.onChanged, isNull);
      expect(sw.value, isTrue);
      final lw =
          t.widget<SwitchListTile>(find.byKey(const Key('staffLoginSwitch')));
      expect(lw.onChanged, isNull);
      final dz = t.widget<OutlinedButton>(
          find.byKey(const Key('staffDeactivateButton')));
      expect(dz.onPressed, isNull);
    });

    testWidgets('共用端末で担当者に管理者を選んでいても、管理者だけの項目は編集できない', (t) async {
      await io(t, asShared);
      await open(
          t, StaffEditScreen(staff: StaffService.instance.getById(b.id)));
      expect(find.textContaining('共用端末のアカウントでは変更できません'), findsWidgets);
      expect(
          t
              .widget<SwitchListTile>(find.byKey(const Key('staffAdminSwitch')))
              .onChanged,
          isNull);
    });

    testWidgets('誰でも氏名・勤務日・送迎を保存できる（共用端末）', (t) async {
      final be = await io(
          t,
          () => FakeBackend.attach(
              staff: const [admin, a, b], currentStaffId: a.id));
      await open(t, StaffEditScreen(staff: StaffService.instance.getById(b.id)),
          size: const Size(530, 1400));
      await t.enterText(find.byKey(const Key('staffNameField')), '佐藤 三郎');
      final chip = find.byKey(const Key('staffDay_2'));
      expect(t.getSize(chip).height, greaterThanOrEqualTo(48));
      await t.tap(chip);
      await t.tap(find.byKey(const Key('staffCanDriveSwitch')));
      await t.pump();
      await t.tap(find.byKey(const Key('staffSaveButton')));
      await t.pumpAndSettle();
      await io(t, () async {});
      final doc = (await io(t, () => be.staffCol.doc(b.id).get())).data()!;
      expect(doc['name'], '佐藤 三郎');
      expect(doc['workDays'], [2]);
      expect(doc['canDrive'], true);
      expect(doc['isAdmin'], false);
    });

    testWidgets('押す場所は高さ48以上（スイッチ・保存・在籍終了）', (t) async {
      await io(t, asAdmin);
      await open(t, StaffEditScreen(staff: StaffService.instance.getById(b.id)),
          size: const Size(530, 1600));
      for (final k in const [
        'staffCanDriveSwitch',
        'staffLoginSwitch',
        'staffAdminSwitch',
        'staffSaveButton',
        'staffDeactivateButton',
      ]) {
        expect(t.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48),
            reason: k);
      }
    });

    testWidgets('管理者は在籍終了にでき、確認文で「ログインできなくなる」と伝える', (t) async {
      final be = await io(
          t,
          () => FakeBackend.attach(
                staff: const [admin, a, b],
                currentStaffId: admin.id,
                personalStaffId: admin.id,
              ));
      await open(t, StaffEditScreen(staff: StaffService.instance.getById(b.id)),
          size: const Size(820, 1600));
      await t.tap(find.byKey(const Key('staffDeactivateButton')));
      await t.pumpAndSettle();
      expect(
          find.text('ログインできなくなります。記録に残った名前はそのままで、あとで在籍に戻せます。'), findsOneWidget);
      await t.tap(find.byKey(const Key('staffDeactivateConfirm')));
      await t.pumpAndSettle();
      expect(
          (await io(t, () => be.staffCol.doc(b.id).get())).data()!['isActive'],
          false);
    });

    testWidgets('最後の管理者は管理者を外せない（保存しても何も変わらない）', (t) async {
      final be = await io(
          t,
          () => FakeBackend.attach(
                staff: const [admin, a],
                currentStaffId: admin.id,
                personalStaffId: admin.id,
              ));
      await open(
          t, StaffEditScreen(staff: StaffService.instance.getById(admin.id)),
          size: const Size(820, 1600));
      await t.tap(find.byKey(const Key('staffAdminSwitch')));
      await t.pump();
      await t.tap(find.byKey(const Key('staffSaveButton')));
      await t.pumpAndSettle();
      expect(find.textContaining('管理者が1人もいなくなる'), findsOneWidget);
      expect(
          (await io(t, () => be.staffCol.doc(admin.id).get()))
              .data()!['isAdmin'],
          true);
      expect(find.byType(StaffEditScreen), findsOneWidget);
    });

    testWidgets('新規登録（管理者）: メールアドレスの重複は欄に理由を出して止める', (t) async {
      await io(t, asAdmin);
      await open(t, const StaffEditScreen(), size: const Size(820, 1600));
      await t.enterText(find.byKey(const Key('staffNameField')), '新人');
      await t.enterText(
          find.byKey(const Key('staffEmailField')), 'ADMIN@example.invalid');
      await t.tap(find.byKey(const Key('staffSaveButton')));
      await t.pumpAndSettle();
      expect(find.textContaining('このメールアドレスは「管理 一郎」に登録されています'), findsOneWidget);
      expect(StaffService.instance.getActiveStaff().map((s) => s.name),
          isNot(contains('新人')));

      await t.enterText(
          find.byKey(const Key('staffEmailField')), 'shinjin@example.invalid');
      await t.tap(find.byKey(const Key('staffSaveButton')));
      await t.pumpAndSettle();
      expect(StaffService.instance.getActiveStaff().map((s) => s.name),
          contains('新人'));
    });
  });

  testWidgets('在籍に戻す: 管理者だけ押せる', (t) async {
    await io(t, asAdmin);
    await io(t, () => StaffService.instance.deactivateStaff(b.id));
    await open(t, const InactiveStaffScreen());
    await t.tap(find.byKey(Key('restoreStaff_${b.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('restoreStaffConfirm')));
    await t.pumpAndSettle();
    expect(StaffService.instance.getById(b.id)!.isActive, isTrue);
    await t.pumpWidget(const SizedBox.shrink());
    await io(t, FakeBackend.detach);

    final be = await io(
        t,
        () => FakeBackend.attach(staff: [
              admin,
              b.copyWith(isActive: false),
            ], currentStaffId: admin.id));
    await io(t, () => be.staffCol.doc(b.id).update({'isActive': false}));
    await t.pump();
    await open(t, const InactiveStaffScreen());
    final btn =
        t.widget<OutlinedButton>(find.byKey(Key('restoreStaff_${b.id}')));
    expect(btn.onPressed, isNull);
    expect(find.textContaining('在籍に戻すのは管理者だけができます'), findsOneWidget);
  });
}
