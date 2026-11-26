import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/data_session.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/services/staff_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 段階3: 共用端末で前の人・前日の担当者のまま記録しないこと
void main() {
  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 11, 19, 23, 59);
    StaffSession.instance.clock = () => now;
  });
  tearDown(() async {
    StaffSession.instance.clock = DateTime.now;
    await FakeBackend.detach();
  });

  Future<FakeFirebaseFirestore> member() async {
    final db = FakeFirebaseFirestore();
    await db.collection('memberships').doc('u1').set({'facilityId': 'fac-1'});
    await db
        .collection('facilities')
        .doc('fac-1')
        .collection('staff')
        .doc('s1')
        .set({'name': '職員 冬子', 'isActive': true});
    return db;
  }

  test('日付が変わると担当者は未選択に戻り、記録には担当者を求める', () async {
    await DataSession.instance.start('u1', db: await member());
    await StaffSession.instance.select(await _firstStaff());
    expect(StaffSession.instance.current?.name, '職員 冬子');

    now = DateTime(2026, 11, 20, 0, 1); // 0 時をまたいだ
    expect(StaffSession.instance.current, isNull);
    expect(StaffSession.instance.stamp, isNull);
    expect(() => StaffSession.instance.requireStamp(),
        throwsA(isA<StaffNotSelectedException>()));
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(StaffSession.prefsKey('fac-1')), isNull,
        reason: '端末の保存も消す');
  });

  test('前日に選んだ担当者は、次の日の起動で引き継がない', () async {
    SharedPreferences.setMockInitialValues({
      StaffSession.prefsKey('fac-1'): 's1',
      StaffSession.prefsDateKey('fac-1'): '2026-11-18',
    });
    await DataSession.instance.start('u1', db: await member());
    expect(StaffSession.instance.current, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(StaffSession.prefsKey('fac-1')), isNull);
  });

  test('日付の記録が無い保存（段階2の形式）は引き継がない', () async {
    SharedPreferences.setMockInitialValues({StaffSession.prefsKey('fac-1'): 's1'});
    await DataSession.instance.start('u1', db: await member());
    expect(StaffSession.instance.current, isNull);
  });

  test('ログアウトすると、端末に保存した担当者の選択も消す', () async {
    await DataSession.instance.start('u1', db: await member());
    await StaffSession.instance.select(await _firstStaff());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(StaffSession.prefsKey('fac-1')), 's1');

    DataSession.instance.debugWaitPendingWrites = () async {}; // 送信済み
    final outcome = await DataSession.instance.logout(
      signOut: () async {},
      clearCache: (_) async => true,
    );
    expect(outcome, LogoutOutcome.done);
    expect(prefs.getString(StaffSession.prefsKey('fac-1')), isNull);
    expect(prefs.getString(StaffSession.prefsDateKey('fac-1')), isNull);
  });

  test('未送信があってログアウトを止めたときは、担当者の選択を消さない', () async {
    await DataSession.instance.start('u1', db: await member());
    await StaffSession.instance.select(await _firstStaff());
    DataSession.instance.debugWaitPendingWrites =
        () => Future<void>.delayed(const Duration(seconds: 1));
    final outcome = await DataSession.instance.logout(
      signOut: () async {},
      timeout: const Duration(milliseconds: 10),
      clearCache: (_) async => true,
    );
    expect(outcome, LogoutOutcome.pendingWrites);
    expect(StaffSession.instance.current?.name, '職員 冬子');
  });
}

Future<Staff> _firstStaff() async =>
    StaffService.instance.getActiveStaff().first;
