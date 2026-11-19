import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/data_session.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/services/staff_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  group('事業所IDの解決', () {
    test('memberships に所属があれば ready になり、その事業所に接続する', () async {
      final db = FakeFirebaseFirestore();
      await db.collection('memberships').doc('u1').set({'facilityId': 'fac-1'});
      await db
          .collection('facilities')
          .doc('fac-1')
          .collection('staff')
          .doc('s1')
          .set({'name': '山田', 'isActive': true});

      await DataSession.instance.start('u1', db: db);

      expect(DataSession.instance.status, DataSessionStatus.ready);
      expect(FacilityContext.instance.facilityId, 'fac-1');
      expect(StaffService.instance.getActiveStaff().single.name, '山田');
    });

    test('所属がなければ notMember（業務データには接続しない）', () async {
      final db = FakeFirebaseFirestore();
      await DataSession.instance.start('u-none', db: db);
      expect(DataSession.instance.status, DataSessionStatus.notMember);
      expect(FacilityContext.instance.isAttached, isFalse);
    });

    test('facilityId が空文字なら notMember', () async {
      final db = FakeFirebaseFirestore();
      await db.collection('memberships').doc('u2').set({'facilityId': '  '});
      await DataSession.instance.start('u2', db: db);
      expect(DataSession.instance.status, DataSessionStatus.notMember);
    });

    test('この端末で今日選んだ担当者を事業所ごとに復元する', () async {
      // 段階3: 担当者は「選んだ日」と一緒に保存する（日付が変われば未選択）
      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      SharedPreferences.setMockInitialValues({
        StaffSession.prefsKey('fac-1'): 's1',
        StaffSession.prefsDateKey('fac-1'): today,
        StaffSession.prefsKey('fac-other'): 's9',
        StaffSession.prefsDateKey('fac-other'): today,
      });
      final db = FakeFirebaseFirestore();
      await db.collection('memberships').doc('u1').set({'facilityId': 'fac-1'});
      await db
          .collection('facilities')
          .doc('fac-1')
          .collection('staff')
          .doc('s1')
          .set({'name': '山田', 'isActive': true});
      await DataSession.instance.start('u1', db: db);
      expect(StaffSession.instance.current?.name, '山田');
    });
  });

  group('ログアウト（未送信の記録を黙って消さない）', () {
    test('未送信の書き込みが残っていればログアウトを止め、何も消さない', () async {
      await FakeBackend.attachWithStaff();
      // 通信が切れていて送信が終わらない状態
      DataSession.instance.debugWaitPendingWrites = () => Completer<void>().future;
      var signedOut = false;
      var cleared = false;

      final outcome = await DataSession.instance.logout(
        signOut: () async => signedOut = true,
        timeout: const Duration(milliseconds: 50),
        clearCache: (_) async => cleared = true,
      );

      expect(outcome, LogoutOutcome.pendingWrites);
      expect(signedOut, isFalse);
      expect(cleared, isFalse);
      // 購読も担当者も残る（そのまま作業を続けられる）
      expect(FacilityContext.instance.isAttached, isTrue);
      expect(StaffSession.instance.hasStaff, isTrue);
    });

    test('送信の確認自体が失敗した場合も止める', () async {
      await FakeBackend.attachWithStaff();
      DataSession.instance.debugWaitPendingWrites =
          () async => throw StateError('x');
      var signedOut = false;
      final outcome = await DataSession.instance.logout(
        signOut: () async => signedOut = true,
        clearCache: (_) async => true,
      );
      expect(outcome, LogoutOutcome.pendingWrites);
      expect(signedOut, isFalse);
    });

    test('送信済みなら購読停止 → キャッシュ消去 → サインアウトの順で進む', () async {
      await FakeBackend.attachWithStaff();
      DataSession.instance.debugWaitPendingWrites = () async {};
      final order = <String>[];

      final outcome = await DataSession.instance.logout(
        signOut: () async => order.add('signOut'),
        clearCache: (_) async {
          order.add('clear(attached=${FacilityContext.instance.isAttached})');
          return true;
        },
      );

      expect(outcome, LogoutOutcome.done);
      expect(order, ['clear(attached=false)', 'signOut']);
      expect(DataSession.instance.status, DataSessionStatus.idle);
      expect(StaffService.instance.isAttached, isFalse);
    });

    test('キャッシュを消せなかった場合はそれを返す（画面で知らせる）', () async {
      await FakeBackend.attachWithStaff();
      DataSession.instance.debugWaitPendingWrites = () async {};
      final outcome = await DataSession.instance.logout(
        signOut: () async {},
        clearCache: (_) async => false,
      );
      expect(outcome, LogoutOutcome.cacheNotCleared);
    });
  });
}
