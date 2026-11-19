import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 段階3: 顧客の保存先を Firestore に移したことの確認
Customer _sample({String id = 'c1'}) => Customer(
      id: id,
      name: '見本 一郎',
      nameKana: 'ミホン イチロウ',
      birthday: DateTime(2015, 4, 3),
      gender: '男児',
      guardianName: '保護者',
      recipientCertNumber: '1000000001',
      recipientCertExpiry: DateTime(2027, 3, 31),
      monthlyAvailableDays: 20,
      currentMonthUsedDays: 2,
      regularDays: [1, 3, 5],
      transportLocations: ['帯広市西2条（見本）', '祖父母宅（見本）'],
      transportLocationLats: [42.92, null],
      transportLocationLngs: [143.19, null],
      transportLocationStatus: [Customer.locResolved, Customer.locFailed],
      transportLocationFormatted: ['北海道帯広市西2条', null],
      transportLocationTypes: ['street_address,premise', null],
      notes: '備考',
    );

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  group('Firestore との変換', () {
    test('保存 → 読み直しで内容が変わらない（送迎場所は 1 つの配列）', () async {
      final b = await FakeBackend.attachWithStaff();
      await CustomerService.instance.addCustomer(_sample());
      await FakeBackend.reloadCustomers();

      final stored = (await b.storedCustomers())['c1']!;
      expect(stored['birthday'], '2015-04-03', reason: '日付だけの項目は文字列');
      expect(stored['recipientCertExpiry'], '2027-03-31');
      expect(stored['transportLocations'], [
        {
          'address': '帯広市西2条（見本）',
          'lat': 42.92,
          'lng': 143.19,
          'status': 'resolved',
          'formattedAddress': '北海道帯広市西2条',
          'types': ['street_address', 'premise'],
        },
        {
          'address': '祖父母宅（見本）',
          'lat': null,
          'lng': null,
          'status': 'failed',
          'formattedAddress': null,
          'types': <String>[],
        },
      ]);
      expect(stored['updatedByStaffName'], '山田');
      expect(stored['updatedByStaffId'], 's-a');
      expect(stored['createdAt'], isA<Timestamp>());

      final r = CustomerService.instance.getCustomerById('c1')!;
      expect(r.toFirestoreData(), _sample().toFirestoreData());
      expect(r.birthday, DateTime(2015, 4, 3));
      expect(r.transportTypes(0), ['street_address', 'premise']);
      expect(r.isTransportResolved(0), isTrue);
      expect(r.transportStatus(1), Customer.locFailed);
    });
  });

  group('担当者', () {
    test('担当者が未選択なら追加・更新・在籍終了を止め、何も保存しない', () async {
      final b = await FakeBackend.attach(
          staff: const [FakeBackend.staffA], currentStaffId: null);
      expect(
          () => CustomerService.instance.addCustomer(_sample()),
          throwsA(isA<StaffNotSelectedException>()));
      await _settle();
      expect(await b.storedCustomers(), isEmpty);
      expect(CustomerService.instance.getCustomerById('c1'), isNull,
          reason: '画面にも出さない');
    });

    test('選択画面で選べば、そのまま保存して担当者を記録する', () async {
      final b = await FakeBackend.attach(
          staff: const [FakeBackend.staffA, FakeBackend.staffB],
          currentStaffId: null);
      StaffSession.instance.prompter = () async => FakeBackend.staffB;
      await CustomerService.instance.addCustomer(_sample());
      await _settle();
      expect((await b.storedCustomers())['c1']!['updatedByStaffName'], '佐藤');
    });
  });

  group('更新は変わった項目だけ', () {
    test('1 項目だけ変えると、その項目と記録欄だけを書く', () async {
      final b = await FakeBackend.attachWithStaff();
      await CustomerService.instance.addCustomer(_sample());
      await _settle();
      // 他の端末が別の項目を書き換えていた（この端末はまだ知らない）
      await b.customerCol.doc('c1').update({'notes': '他端末の備考'});
      // この端末の購読に届く前に、手元の古い内容のまま電話番号だけ変える
      final c = CustomerService.instance.getCustomerById('c1')!;
      c.phone = '0155-00-0000';
      await CustomerService.instance.updateCustomer(c);
      await _settle();

      final stored = (await b.storedCustomers())['c1']!;
      expect(stored['phone'], '0155-00-0000');
      expect(stored['notes'], '他端末の備考', reason: '変えていない項目は上書きしない');
    });

    test('値が変わっていなければ書かない（記録欄も変わらない）', () async {
      final b = await FakeBackend.attachWithStaff();
      await CustomerService.instance.addCustomer(_sample());
      await _settle();
      StaffSession.instance.debugSet(
          facilityId: FakeBackend.defaultFacilityId,
          staffId: FakeBackend.staffB.id);
      await CustomerService.instance
          .updateCustomer(CustomerService.instance.getCustomerById('c1')!);
      await _settle();
      expect((await b.storedCustomers())['c1']!['updatedByStaffName'], '山田');
    });

    test('利用日数の自動補正は担当者なしで「自動」と記録し、その項目だけを書く', () async {
      final b = await FakeBackend.attachWithStaff();
      await CustomerService.instance.addCustomer(_sample());
      await _settle();
      StaffSession.instance.debugSet(
          facilityId: FakeBackend.defaultFacilityId, staffId: null);
      final c = CustomerService.instance.getCustomerById('c1')!;
      c.currentMonthUsedDays = 7;
      await CustomerService.instance.updateCustomer(c, stamp: AuditStamp.auto);
      await _settle();
      final stored = (await b.storedCustomers())['c1']!;
      expect(stored['currentMonthUsedDays'], 7);
      expect(stored['updatedByStaffName'], '自動');
      expect(stored['updatedByStaffId'], isNull);
    });
  });

  group('在籍終了・在籍に戻す', () {
    test('在籍終了は isActive だけを変え、送迎場所の座標を残す', () async {
      final b = await FakeBackend.attachWithStaff();
      await CustomerService.instance.addCustomer(_sample());
      await CustomerService.instance.deleteCustomer('c1');
      await _settle();

      expect(CustomerService.instance.getAllCustomers(), isEmpty);
      expect(CustomerService.instance.getInactiveCustomers().single.id, 'c1');
      final stored = (await b.storedCustomers())['c1']!;
      expect(stored['isActive'], isFalse);
      expect(stored['deactivatedAt'], isA<Timestamp>());
      expect((stored['transportLocations'] as List).first['lat'], 42.92,
          reason: '旧実装では在籍終了で座標が消えていた（範囲外①）');
      expect(stored['name'], '見本 一郎', reason: 'ドキュメントは削除しない');
    });

    test('在籍に戻すと在籍中の一覧に戻り、在籍終了日時を消す', () async {
      final b = await FakeBackend.attachWithStaff();
      await CustomerService.instance.addCustomer(_sample());
      await CustomerService.instance.deleteCustomer('c1');
      await CustomerService.instance.restoreCustomer('c1');
      await _settle();

      expect(CustomerService.instance.getAllCustomers().single.id, 'c1');
      expect(CustomerService.instance.getInactiveCustomers(), isEmpty);
      final stored = (await b.storedCustomers())['c1']!;
      expect(stored['isActive'], isTrue);
      expect(stored['deactivatedAt'], isNull);
      expect(stored['updatedByStaffName'], '山田');
    });
  });

  group('他の端末の変更', () {
    test('保存先の変更が、開き直さずに一覧へ届き、変更通知が出る', () async {
      final b = await FakeBackend.attachWithStaff();
      var notified = 0;
      void onChange() => notified++;
      CustomerService.instance.addListener(onChange);
      addTearDown(() => CustomerService.instance.removeListener(onChange));

      // 別の端末が追加した（この端末のサービスを通らない書き込み）
      await b.customerCol.doc('other').set({
        ..._sample(id: 'other').toFirestoreData(),
        'name': '他端末 花子',
        'updatedByStaffName': '佐藤',
      });
      await _settle();
      expect(CustomerService.instance.getCustomerById('other')?.name, '他端末 花子');
      expect(notified, greaterThan(0));

      // 別の端末が在籍終了にした
      await b.customerCol.doc('other').update({'isActive': false});
      await _settle();
      expect(CustomerService.instance.getAllCustomers(), isEmpty);
      expect(CustomerService.instance.getInactiveCustomers().single.id, 'other');
    });

    test('自分の書き込みの折り返しでは変更通知を出さない（画面の読み直しを繰り返さない）',
        () async {
      await FakeBackend.attachWithStaff();
      await CustomerService.instance.addCustomer(_sample());
      await _settle();
      var notified = 0;
      void onChange() => notified++;
      CustomerService.instance.addListener(onChange);
      addTearDown(() => CustomerService.instance.removeListener(onChange));

      final c = CustomerService.instance.getCustomerById('c1')!;
      c.notes = '変更';
      await CustomerService.instance.updateCustomer(c);
      await _settle();
      expect(notified, 1, reason: '更新した時点の 1 回だけ');
    });
  });
}
