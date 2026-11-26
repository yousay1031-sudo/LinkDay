import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/services/staff_account_service.dart';
import 'package:linkday_app/services/staff_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  const admin = FakeBackend.adminStaff;
  const a = FakeBackend.staffA;
  const b = FakeBackend.staffB;

  /// 管理者の個人アカウントでログインした状態
  Future<FakeBackend> asAdmin({List<Staff> extra = const [a, b]}) =>
      FakeBackend.attach(
        staff: [admin, ...extra],
        currentStaffId: admin.id,
        personalStaffId: admin.id,
        emails: {admin.id: 'admin@example.invalid'},
      );

  CollectionReference<Map<String, dynamic>> accounts(FakeBackend be) => be.db
      .collection(FsPaths.facilities)
      .doc(be.facilityId)
      .collection(FsPaths.staffAccounts);

  group('登録（管理者だけ）', () {
    test('管理者は全項目を付けて登録でき、メールアドレスは別の文書に入る', () async {
      final be = await asAdmin();
      final s = await StaffService.instance.addStaff(
        const Staff(
          id: '',
          name: '  鈴木 花子 ',
          kana: 'すずき はなこ',
          role: StaffRole.nurseryTeacher,
          qualifications: '保育士',
          workDays: [3, 1, 3],
          canDrive: true,
          loginEnabled: true,
        ),
        googleEmail: ' Hanako@Example.invalid ',
      );
      await pumpEventQueue();
      final doc = (await be.staffCol.doc(s.id).get()).data()!;
      expect(doc['name'], '鈴木 花子');
      expect(doc['kana'], 'すずき はなこ');
      expect(doc['role'], 'nurseryTeacher');
      expect(doc['workDays'], [1, 3]);
      expect(doc['canDrive'], true);
      expect(doc['isActive'], true);
      expect(doc['isAdmin'], false);
      expect(doc['loginEnabled'], true);
      expect(doc['hasGoogleEmail'], true);
      expect(doc.containsKey('googleEmail'), isFalse,
          reason: '職員の文書にアドレスを置かない');
      expect(doc['updatedByStaffId'], admin.id);
      final acc = (await accounts(be).doc(s.id).get()).data()!;
      expect(acc['googleEmail'], 'Hanako@Example.invalid');
      expect(acc['googleEmailLower'], 'hanako@example.invalid');
    });

    test('共用端末アカウントは、担当者に管理者を選んでいても登録できない', () async {
      final be = await FakeBackend.attach(
          staff: const [admin, a], currentStaffId: admin.id);
      await expectLater(
        StaffService.instance.addStaff(const Staff(id: '', name: '新人')),
        throwsA(isA<NotAdminException>()),
      );
      await pumpEventQueue();
      expect((await be.staffCol.get()).docs.length, 2);
    });

    test('管理者でない個人アカウントは登録できない', () async {
      await FakeBackend.attach(
          staff: const [admin, a], currentStaffId: a.id, personalStaffId: a.id);
      await expectLater(
        StaffService.instance.addStaff(const Staff(id: '', name: '新人')),
        throwsA(isA<NotAdminException>()),
      );
    });

    test('同じメールアドレス（大文字・小文字の違いだけ）は2人に登録できない', () async {
      await asAdmin();
      await expectLater(
        StaffService.instance.addStaff(const Staff(id: '', name: '新人'),
            googleEmail: 'ADMIN@example.invalid'),
        throwsA(isA<StaffInputException>()),
      );
    });

    test('メールアドレスの形が違えば登録しない・氏名は必須', () async {
      await asAdmin();
      await expectLater(
        StaffService.instance
            .addStaff(const Staff(id: '', name: '新人'), googleEmail: 'abc'),
        throwsA(isA<StaffInputException>()),
      );
      await expectLater(
        StaffService.instance.addStaff(const Staff(id: '', name: '  ')),
        throwsA(isA<StaffInputException>()),
      );
    });
  });

  group('氏名などの編集（誰でも）', () {
    test('共用端末でも、氏名・ふりがな・役割・資格・勤務日・送迎の可否を保存できる', () async {
      final be = await FakeBackend.attachWithStaff();
      await StaffService.instance.updateProfile(b.copyWith(
        name: '佐藤 次郎',
        kana: 'さとう じろう',
        role: StaffRole.driver,
        qualifications: '中型免許',
        workDays: [5, 2],
        canDrive: true,
      ));
      await pumpEventQueue();
      final doc = (await be.staffCol.doc(b.id).get()).data()!;
      expect(doc['name'], '佐藤 次郎');
      expect(doc['role'], 'driver');
      expect(doc['workDays'], [2, 5]);
      expect(doc['canDrive'], true);
      expect(doc['updatedByStaffName'], a.name);
      // 管理者だけの項目には触れない
      expect(doc['isAdmin'], false);
      expect(doc['isActive'], true);
    });

    test('担当者未選択なら選択画面がなければ中止（従来どおり）', () async {
      final be = await FakeBackend.attach(staff: const [a, b]);
      await expectLater(
        StaffService.instance.updateProfile(b.copyWith(name: 'x')),
        throwsA(isA<StaffNotSelectedException>()),
      );
      await pumpEventQueue();
      expect((await be.staffCol.doc(b.id).get()).data()!['name'], b.name);
    });

    test('続けて保存しても、前の保存の折り返しで古い内容に戻らない', () async {
      await FakeBackend.attachWithStaff();
      final seen = <String>[];
      void l() => seen.add(StaffService.instance.getById(b.id)!.name);
      StaffService.instance.addListener(l);
      await StaffService.instance.updateProfile(b.copyWith(name: '一回目'));
      await StaffService.instance.updateProfile(b.copyWith(name: '二回目'));
      await pumpEventQueue();
      StaffService.instance.removeListener(l);
      final after = seen.sublist(seen.indexOf('二回目'));
      expect(after.every((n) => n == '二回目'), isTrue, reason: '$seen');
    });
  });

  group('在籍終了・在籍に戻す（管理者だけ）', () {
    test('在籍終了にすると一覧から消えるがドキュメントは残る。在籍に戻せる', () async {
      final be = await asAdmin();
      await StaffService.instance.deactivateStaff(b.id);
      await pumpEventQueue();
      expect(StaffService.instance.getActiveStaff().map((e) => e.id),
          isNot(contains(b.id)));
      expect(StaffService.instance.getInactiveStaff().map((e) => e.id), [b.id]);
      var doc = (await be.staffCol.doc(b.id).get()).data()!;
      expect(doc['isActive'], false);
      expect(doc['deactivatedAt'], isA<Timestamp>());
      expect(StaffService.instance.getById(b.id)?.name, b.name);

      await StaffService.instance.restoreStaff(b.id);
      await pumpEventQueue();
      doc = (await be.staffCol.doc(b.id).get()).data()!;
      expect(doc['isActive'], true);
      expect(doc['deactivatedAt'], isNull);
      expect(StaffService.instance.getInactiveStaff(), isEmpty);
    });

    test('共用端末・管理者でない個人アカウントは在籍終了にできない', () async {
      await FakeBackend.attachWithStaff();
      await expectLater(StaffService.instance.deactivateStaff(b.id),
          throwsA(isA<NotAdminException>()));
      await FakeBackend.detach();
      await FakeBackend.attach(
          staff: const [admin, a, b],
          currentStaffId: a.id,
          personalStaffId: a.id);
      await expectLater(StaffService.instance.deactivateStaff(b.id),
          throwsA(isA<NotAdminException>()));
    });

    test('共用端末で選んでいた担当者が、他の端末で在籍終了になると未選択に戻る', () async {
      final be = await FakeBackend.attach(
          staff: const [admin, a], currentStaffId: a.id);
      expect(StaffSession.instance.current?.id, a.id);
      await be.staffCol.doc(a.id).update({'isActive': false});
      await pumpEventQueue();
      expect(StaffSession.instance.current, isNull);
    });
  });

  group('最後の管理者', () {
    test('最後の管理者は、在籍終了・管理者の解除・ログインの停止ができない', () async {
      final be = await asAdmin();
      await expectLater(StaffService.instance.deactivateStaff(admin.id),
          throwsA(isA<LastAdminException>()));
      await expectLater(
          StaffService.instance.updateAccess(admin.id, isAdmin: false),
          throwsA(isA<LastAdminException>()));
      await expectLater(
          StaffService.instance.updateAccess(admin.id, loginEnabled: false),
          throwsA(isA<LastAdminException>()));
      await pumpEventQueue();
      final doc = (await be.staffCol.doc(admin.id).get()).data()!;
      expect(doc['isAdmin'], true);
      expect(doc['loginEnabled'], true);
      expect(doc['isActive'], true);
    });

    test('別の管理者がいれば外せ、その職員 ID を書き込みに付ける（ルールで確かめる）', () async {
      const admin2 = Staff(
          id: 's-admin2', name: '管理 二郎', isAdmin: true, loginEnabled: true);
      final be = await asAdmin(extra: const [admin2]);
      await StaffService.instance.updateAccess(admin2.id, isAdmin: false);
      await pumpEventQueue();
      final doc = (await be.staffCol.doc(admin2.id).get()).data()!;
      expect(doc['isAdmin'], false);
      expect(doc['otherAdminId'], admin.id);
    });
  });

  group('アカウントの項目（管理者だけ）', () {
    test('メールアドレスの登録・変更・取り消しとログインの許可', () async {
      final be = await asAdmin();
      await StaffService.instance.updateAccess(b.id,
          googleEmail: 'sato@example.invalid', loginEnabled: true);
      await pumpEventQueue();
      var doc = (await be.staffCol.doc(b.id).get()).data()!;
      expect(doc['hasGoogleEmail'], true);
      expect(doc['loginEnabled'], true);
      expect(StaffService.instance.getById(b.id)!.loginStatus,
          StaffLoginStatus.allowed);
      expect((await accounts(be).doc(b.id).get()).data()!['googleEmailLower'],
          'sato@example.invalid');

      await StaffService.instance.updateAccess(b.id, loginEnabled: false);
      await pumpEventQueue();
      expect(StaffService.instance.getById(b.id)!.loginStatus,
          StaffLoginStatus.stopped);

      await StaffService.instance.updateAccess(b.id, googleEmail: '');
      await pumpEventQueue();
      doc = (await be.staffCol.doc(b.id).get()).data()!;
      expect(doc['hasGoogleEmail'], false);
      expect((await accounts(be).doc(b.id).get()).data()!['googleEmail'], '');
      expect(StaffAccountService.instance.emailOf(b.id), isNull);
      expect(StaffService.instance.getById(b.id)!.loginStatus,
          StaffLoginStatus.none);
    });

    test('他の職員と同じアドレスは登録できない', () async {
      await asAdmin();
      await expectLater(
        StaffService.instance
            .updateAccess(b.id, googleEmail: 'Admin@Example.invalid'),
        throwsA(isA<StaffInputException>()),
      );
    });

    test('管理者でなければ購読せず、アドレスは読めない', () async {
      await FakeBackend.attach(
        staff: const [admin, a],
        currentStaffId: a.id,
        personalStaffId: a.id,
        emails: {admin.id: 'admin@example.invalid'},
      );
      await pumpEventQueue();
      expect(StaffAccountService.instance.isLoaded, isFalse);
      expect(StaffAccountService.instance.emailOf(admin.id), isNull);
      await expectLater(StaffService.instance.updateAccess(a.id, isAdmin: true),
          throwsA(isA<NotAdminException>()));
    });
  });

  test('他の端末の変更が購読で届き、変更通知が出る', () async {
    final be = await FakeBackend.attachWithStaff();
    var notified = 0;
    void listener() => notified++;
    StaffService.instance.addListener(listener);
    await be.staffCol.doc('s-c').set({
      ...const Staff(id: 's-c', name: '鈴木').toCreateMap(),
      'createdAt': Timestamp.fromDate(DateTime(2026, 2, 1)),
    });
    await pumpEventQueue();
    StaffService.instance.removeListener(listener);
    expect(notified, greaterThan(0));
    expect(StaffService.instance.getActiveStaff().map((e) => e.name),
        containsAll(['職員 冬子', '佐藤', '鈴木']));
  });

  test('項目の無い既存の職員（ステップ1の形）は初期値で読める', () {
    final s = Staff.fromMap('x', {'name': '旧', 'isActive': true});
    expect(s.kana, '');
    expect(s.role, isNull);
    expect(s.workDays, isEmpty);
    expect(s.canDrive, isFalse);
    expect(s.isAdmin, isFalse);
    expect(s.loginEnabled, isFalse);
    expect(s.loginStatus, StaffLoginStatus.none);
  });
}
