import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/services/staff_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  test('職員が1人もいないときは担当者なしで追加でき「初期設定」と記録される', () async {
    final b = await FakeBackend.attach();
    final s = await StaffService.instance.addStaff('  山田  ');
    await pumpEventQueue();

    expect(s.name, '山田');
    final doc = await b.staffCol.doc(s.id).get();
    expect(doc.data()!['name'], '山田');
    expect(doc.data()!['isActive'], true);
    expect(doc.data()!['updatedByStaffId'], isNull);
    expect(doc.data()!['updatedByStaffName'], '初期設定');
    expect(doc.data()!['updatedAt'], isA<Timestamp>());
    expect(doc.data()!['pinHash'], isNull);
    expect(StaffService.instance.getActiveStaff().map((e) => e.name), ['山田']);
  });

  test('職員がいて担当者未選択なら追加できない（選択画面もない場合は中止）', () async {
    final b = await FakeBackend.attach(staff: const [FakeBackend.staffA]);
    await expectLater(
      StaffService.instance.addStaff('佐藤'),
      throwsA(isA<StaffNotSelectedException>()),
    );
    await pumpEventQueue();
    final all = await b.staffCol.get();
    expect(all.docs.length, 1);
  });

  test('担当者未選択でも、選択画面で選べばそのまま書き込みが続き担当者が残る', () async {
    final b = await FakeBackend.attach(staff: const [FakeBackend.staffA]);
    var prompted = 0;
    StaffSession.instance.prompter = () async {
      prompted++;
      return StaffService.instance.getById(FakeBackend.staffA.id);
    };
    final s = await StaffService.instance.addStaff('佐藤');
    await pumpEventQueue();
    expect(prompted, 1);
    expect(StaffSession.instance.current?.id, FakeBackend.staffA.id);
    final doc = await b.staffCol.doc(s.id).get();
    expect(doc.data()!['updatedByStaffId'], FakeBackend.staffA.id);
    expect(doc.data()!['updatedByStaffName'], '山田');
  });

  test('在籍終了にすると一覧から消えるがドキュメントは残り、担当者が記録される', () async {
    final b = await FakeBackend.attachWithStaff();
    await StaffService.instance.deactivateStaff(FakeBackend.staffB.id);
    await pumpEventQueue();

    expect(StaffService.instance.getActiveStaff().map((e) => e.id),
        [FakeBackend.staffA.id]);
    final doc = await b.staffCol.doc(FakeBackend.staffB.id).get();
    expect(doc.exists, isTrue);
    expect(doc.data()!['name'], '佐藤');
    expect(doc.data()!['isActive'], false);
    expect(doc.data()!['deactivatedAt'], isA<Timestamp>());
    expect(doc.data()!['updatedByStaffName'], '山田');
    // 在籍終了後も名前は引ける（過去の記録の表示用）
    expect(StaffService.instance.getById(FakeBackend.staffB.id)?.name, '佐藤');
  });

  test('選択中の担当者を在籍終了にすると未選択に戻る', () async {
    await FakeBackend.attachWithStaff();
    expect(StaffSession.instance.hasStaff, isTrue);
    await StaffService.instance.deactivateStaff(FakeBackend.staffA.id);
    await pumpEventQueue();
    expect(StaffSession.instance.hasStaff, isFalse);
    expect(StaffSession.instance.stamp, isNull);
  });

  test('他の端末の変更が購読で届き、変更通知が出る', () async {
    final b = await FakeBackend.attachWithStaff();
    var notified = 0;
    void listener() => notified++;
    StaffService.instance.addListener(listener);
    // 他端末が直接書き込んだ想定
    await b.staffCol.doc('s-c').set({
      ...const Staff(id: 's-c', name: '鈴木').toCreateMap(),
      'createdAt': Timestamp.fromDate(DateTime(2026, 2, 1)),
    });
    await pumpEventQueue();
    StaffService.instance.removeListener(listener);
    expect(notified, greaterThan(0));
    expect(StaffService.instance.getActiveStaff().map((e) => e.name),
        containsAll(['山田', '佐藤', '鈴木']));
  });

  test('空の名前は追加できない', () async {
    await FakeBackend.attach();
    expect(() => StaffService.instance.addStaff('   '), throwsArgumentError);
  });
}
