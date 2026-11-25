import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/account_session.dart';
import 'package:linkday_app/data/data_session.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ2 段階3: 個人アカウント（Google）でのログインと所属
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  const fac = 'fac-1';

  Future<FakeFirebaseFirestore> seed({
    bool active = true,
    bool login = true,
    bool membership = true,
  }) async {
    final db = FakeFirebaseFirestore();
    final staff = db.collection('facilities').doc(fac).collection('staff');
    await staff.doc('haru').set({
      ...const Staff(id: 'haru', name: '職員 春子', loginEnabled: true)
          .toCreateMap(),
      'isActive': active,
      'loginEnabled': login,
    });
    await staff
        .doc('natsu')
        .set(const Staff(id: 'natsu', name: '職員 夏男').toCreateMap());
    if (membership) {
      await db.collection('memberships').doc('g-haru').set({
        'facilityId': fac,
        'kind': 'personal',
        'staffId': 'haru',
      });
    }
    return db;
  }

  test('個人アカウント: 担当者は本人に固定され、記録に本人の名前が残る', () async {
    final db = await seed();
    await DataSession.instance.start('g-haru', db: db);
    expect(DataSession.instance.status, DataSessionStatus.ready);
    expect(AccountSession.instance.isPersonal, isTrue);
    expect(StaffSession.instance.isFixed, isTrue);
    expect(StaffSession.instance.current?.name, '職員 春子');

    // 他の職員を選ぼうとしても変わらない
    final natsu = (await db
        .collection('facilities')
        .doc(fac)
        .collection('staff')
        .doc('natsu')
        .get());
    await StaffSession.instance.select(Staff.fromMap('natsu', natsu.data()!));
    expect(StaffSession.instance.current?.id, 'haru');

    // 記録に本人が残る
    final c = Customer(id: 'c1', name: '検証 太郎', nameKana: 'けんしょう たろう');
    await CustomerService.instance.addCustomer(c);
    await pumpEventQueue();
    final doc = await db
        .collection('facilities')
        .doc(fac)
        .collection('customers')
        .doc('c1')
        .get();
    expect(doc.data()!['updatedByStaffId'], 'haru');
    expect(doc.data()!['updatedByStaffName'], '職員 春子');
  });

  test('個人アカウント: 日付が変わっても担当者を未選択に戻さない', () async {
    final db = await seed();
    await DataSession.instance.start('g-haru', db: db);
    final real = DateTime.now();
    StaffSession.instance.clock = () => real.add(const Duration(days: 1));
    addTearDown(() => StaffSession.instance.clock = DateTime.now);
    StaffSession.instance.checkDay();
    await pumpEventQueue();
    expect(StaffSession.instance.current?.id, 'haru');
    expect(StaffSession.instance.stamp?.staffName, '職員 春子');
  });

  test('所属が無ければ Google のアカウントは claim を1回呼び、作れたら入る', () async {
    final db = await seed(membership: false);
    var calls = 0;
    await DataSession.instance.start('g-haru', db: db, claim: () async {
      calls++;
      // Cloud Functions が所属を作った想定
      await db.collection('memberships').doc('g-haru').set({
        'facilityId': fac,
        'kind': 'personal',
        'staffId': 'haru',
      });
      return true;
    });
    expect(calls, 1);
    expect(DataSession.instance.status, DataSessionStatus.ready);
    expect(StaffSession.instance.current?.id, 'haru');
  });

  test('未登録の Google アカウント: claim が作らなければ notMember（何も読まない）', () async {
    final db = await seed(membership: false);
    await DataSession.instance
        .start('g-stranger', db: db, claim: () async => false);
    expect(DataSession.instance.status, DataSessionStatus.notMember);
    expect(FacilityContext.instance.isAttached, isFalse);
  });

  test('ログイン停止・在籍終了の職員の所属が残っていても入れない', () async {
    for (final s in [
      (active: true, login: false),
      (active: false, login: true),
    ]) {
      final db = await seed(active: s.active, login: s.login);
      await DataSession.instance.start('g-haru', db: db);
      expect(DataSession.instance.status, DataSessionStatus.notMember,
          reason: '$s');
      expect(FacilityContext.instance.isAttached, isFalse);
      await FakeBackend.detach();
    }
  });

  test('開いたまま在籍終了にされると「登録されていません」に切り替わる', () async {
    final db = await seed();
    await DataSession.instance.start('g-haru', db: db);
    expect(DataSession.instance.isReady, isTrue);
    // 管理者が別の端末で在籍終了にした
    await db
        .collection('facilities')
        .doc(fac)
        .collection('staff')
        .doc('haru')
        .update({'isActive': false});
    await pumpEventQueue();
    expect(DataSession.instance.status, DataSessionStatus.notMember);
    expect(FacilityContext.instance.isAttached, isFalse);
    expect(StaffSession.instance.isFixed, isFalse);
  });

  test('開いたままログインを停止されると切り替わる', () async {
    final db = await seed();
    await DataSession.instance.start('g-haru', db: db);
    await db
        .collection('facilities')
        .doc(fac)
        .collection('staff')
        .doc('haru')
        .update({'loginEnabled': false});
    await pumpEventQueue();
    expect(DataSession.instance.status, DataSessionStatus.notMember);
  });

  test('開いたまま所属が消されると切り替わる（共用端末アカウントも同じ）', () async {
    final db = await seed();
    await db.collection('memberships').doc('shared').set({'facilityId': fac});
    await DataSession.instance.start('shared', db: db);
    expect(AccountSession.instance.isPersonal, isFalse);
    expect(StaffSession.instance.isFixed, isFalse);
    await db.collection('memberships').doc('shared').delete();
    await pumpEventQueue();
    expect(DataSession.instance.status, DataSessionStatus.notMember);
  });

  test('共用端末アカウントは従来どおり担当者を選べ、claim は呼ばない', () async {
    final db = await seed();
    await db.collection('memberships').doc('shared').set({'facilityId': fac});
    var calls = 0;
    await DataSession.instance.start('shared', db: db, claim: () async {
      calls++;
      return false;
    });
    expect(calls, 0);
    expect(StaffSession.instance.current, isNull);
    final natsu = await db
        .collection('facilities')
        .doc(fac)
        .collection('staff')
        .doc('natsu')
        .get();
    await StaffSession.instance.select(Staff.fromMap('natsu', natsu.data()!));
    expect(StaffSession.instance.current?.id, 'natsu');
  });
}
