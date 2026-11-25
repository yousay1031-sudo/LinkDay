import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:linkday_app/data/account_session.dart';
import 'package:linkday_app/data/data_session.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/staff_account_service.dart';
import 'package:linkday_app/services/staff_service.dart';
import 'package:linkday_app/services/transport_plan_service.dart';
import 'package:linkday_app/services/weekly_schedule_service.dart';

/// テスト用の保存先（エミュレータ不要のメモリ上の Firestore）。
///
/// 本番と同じ facilities/{facilityId}/... の形でデータを持ち、
/// 各サービスを attach する。担当者 [currentStaffId] を選択済みにできる。
class FakeBackend {
  FakeBackend._(this.db, this.facilityId);

  final FakeFirebaseFirestore db;
  final String facilityId;

  static const String defaultFacilityId = 'f-test';

  static Future<FakeBackend> attach({
    String facilityId = defaultFacilityId,
    List<Staff> staff = const [],
    String? currentStaffId,
    String? personalStaffId,
    Map<String, String> emails = const {},
  }) async {
    final db = FakeFirebaseFirestore();
    final backend = FakeBackend._(db, facilityId);
    for (final s in staff) {
      await backend.staffCol.doc(s.id).set({
        ...s.toCreateMap(),
        Staff.fIsActive: s.isActive,
        'createdAt': DateTime(2026, 1, 1).add(Duration(minutes: staff.indexOf(s))),
        'updatedByStaffId': null,
        'updatedByStaffName': 'テスト',
      });
    }
    for (final e in emails.entries) {
      await backend.db
          .collection(FsPaths.facilities)
          .doc(facilityId)
          .collection(FsPaths.staffAccounts)
          .doc(e.key)
          .set({
        StaffAccountService.fGoogleEmail: e.value,
        StaffAccountService.fGoogleEmailLower: e.value.toLowerCase(),
      });
    }
    FacilityContext.instance.attach(db, facilityId);
    await StaffService.instance.attach();
    // 個人アカウント（[personalStaffId] の本人）としてログインした状態。省略時は共用端末
    if (personalStaffId != null) {
      AccountSession.instance.debugSet(
          kind: AccountKind.personal, staffId: personalStaffId);
    } else {
      AccountSession.instance.debugSet();
    }
    StaffAccountService.instance.start();
    await pumpUntilAccountsLoaded();
    StaffSession.instance.debugSet(facilityId: facilityId, staffId: currentStaffId);
    await SettingsService.instance.attach();
    await CustomerService.instance.attach();
    await WeeklyScheduleService.instance.attach();
    await AttendanceService.instance.attach();
    await TransportPlanService.instance.attach();
    _current = backend;
    return backend;
  }

  /// テストで使う標準の職員 2 名
  static const Staff staffA = Staff(id: 's-a', name: '山田');
  static const Staff staffB = Staff(id: 's-b', name: '佐藤');

  /// 職員 2 名・山田を選択済みで接続する（多くのテストの既定）
  static Future<FakeBackend> attachWithStaff({String facilityId = defaultFacilityId}) =>
      attach(facilityId: facilityId, staff: const [staffA, staffB], currentStaffId: staffA.id);

  static FakeBackend? _current;

  /// 管理者のとき、メールアドレスの一覧（管理者だけが読める）の最初の読み込みを待つ
  static Future<void> pumpUntilAccountsLoaded() async {
    for (var i = 0; i < 20; i++) {
      if (!AccountSession.instance.isAdmin ||
          StaffAccountService.instance.isLoaded) {
        return;
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 管理者の職員（在籍中・管理者・ログイン許可）
  static const Staff adminStaff = Staff(
      id: 's-admin', name: '管理 一郎', isAdmin: true, loginEnabled: true, hasGoogleEmail: true);

  /// 直近に attach した保存先
  static FakeBackend get current {
    final c = _current;
    if (c == null) throw StateError('FakeBackend.attach を先に呼んでください');
    return c;
  }

  /// 顧客を空にした新しい保存先に付け替える（旧 Hive の customers.clear() の代わり）
  static Future<FakeBackend> resetCustomers() => attachWithStaff();

  /// 保存先（偽の Firestore）上の顧客ドキュメント
  Future<Map<String, Map<String, dynamic>>> storedCustomers() async {
    final snap = await customerCol.get();
    return {for (final d in snap.docs) d.id: d.data()};
  }

  /// 購読をやり直して、保存先から顧客を読み直す（再読み込み・別端末の起動に相当）
  static Future<void> reloadCustomers() async {
    // 送信は待たずに戻る書き込みが偽の保存先に届くのを待つ
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await CustomerService.instance.detach();
    await CustomerService.instance.attach();
  }

  /// 週間利用計画を空にする（旧 Hive の weekly_schedules.clear() の代わり）
  static Future<void> resetSchedules() async {
    final b = current;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final name in [FsPaths.scheduleEntries, FsPaths.scheduleWeeks]) {
      final col = b.db.collection(FsPaths.facilities).doc(b.facilityId).collection(name);
      for (final d in (await col.get()).docs) {
        await d.reference.delete();
      }
    }
    await WeeklyScheduleService.instance.detach();
    await WeeklyScheduleService.instance.attach();
  }

  /// 出席の記録を空にする（旧 Hive の attendance_records.clear() の代わり）
  static Future<void> resetAttendance() async {
    final b = current;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final col = b.db.collection(FsPaths.facilities).doc(b.facilityId).collection(FsPaths.attendance);
    for (final d in (await col.get()).docs) {
      await d.reference.delete();
    }
    await AttendanceService.instance.detach();
    await AttendanceService.instance.attach();
  }

  /// 送迎計画を空にする（旧 Hive の transport_plans.clear() の代わり）
  static Future<void> resetTransport() async {
    final b = current;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final col = b.db.collection(FsPaths.facilities).doc(b.facilityId).collection(FsPaths.transportRoutes);
    for (final d in (await col.get()).docs) {
      await d.reference.delete();
    }
    await TransportPlanService.instance.detach();
    await TransportPlanService.instance.attach();
  }

  /// 購読をやり直して、保存先から送迎計画を読み直す
  static Future<void> reloadTransport() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await TransportPlanService.instance.detach();
    await TransportPlanService.instance.attach();
  }

  /// 購読をやり直して、保存先から出席を読み直す
  static Future<void> reloadAttendance() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await AttendanceService.instance.detach();
    await AttendanceService.instance.attach();
  }

  /// 購読をやり直して、保存先から週間利用計画を読み直す
  static Future<void> reloadSchedules() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await WeeklyScheduleService.instance.detach();
    await WeeklyScheduleService.instance.attach();
  }

  /// 端末内の顧客（在籍終了を含む）の件数
  static int get customerCount =>
      CustomerService.instance.getAllCustomers(includeInactive: true).length;

  /// 端末内の顧客（在籍終了を含む）
  static List<Customer> get allCustomers =>
      CustomerService.instance.getAllCustomers(includeInactive: true);

  CollectionReference<Map<String, dynamic>> get customerCol => db
      .collection(FsPaths.facilities)
      .doc(facilityId)
      .collection(FsPaths.customers);

  CollectionReference<Map<String, dynamic>> get staffCol => db
      .collection(FsPaths.facilities)
      .doc(facilityId)
      .collection(FsPaths.staff);

  static Future<void> detach() async {
    StaffSession.instance.prompter = null;
    await DataSession.instance.stop();
    DataSession.instance.debugReset();
    await StaffAccountService.instance.stop();
    AccountSession.instance.reset();
  }
}
