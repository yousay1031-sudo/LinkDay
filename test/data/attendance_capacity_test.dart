import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 手直し4: 出席管理の空き枠は、設定の「1日の最大利用者数」を定員にして数える
DocumentReference<Map<String, dynamic>> _settingsDoc() =>
    FacilityContext.instance.col(FsPaths.settings).doc(FsPaths.settingsDocId);
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  final today = DateTime.now();
  final key = AttendanceRecord.makeDateKey(today);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FakeBackend.attachWithStaff();
    await FakeBackend.resetAttendance();
    // 予定 2・在室 1・退室 1・欠席 1
    final recs = [
      AttendanceRecord(customerId: 'a', customerName: 'A', dateKey: key),
      AttendanceRecord(customerId: 'b', customerName: 'B', dateKey: key),
      AttendanceRecord(
          customerId: 'c',
          customerName: 'C',
          dateKey: key,
          status: AttendanceStatus.present,
          checkInTime: today),
      AttendanceRecord(
          customerId: 'd',
          customerName: 'D',
          dateKey: key,
          status: AttendanceStatus.departed,
          checkInTime: today,
          checkOutTime: today),
      AttendanceRecord(
          customerId: 'e',
          customerName: 'E',
          dateKey: key,
          status: AttendanceStatus.absent),
    ];
    for (final r in recs) {
      await AttendanceService.instance.upsertRecord(r);
    }
    await _settle();
  });
  tearDown(FakeBackend.detach);

  AttendanceSummary summary() =>
      AttendanceService.instance.getTodaySummary(today);

  test('設定が未入力（設定の文書が無い）ときは既定の 10 名で数える', () async {
    expect((await _settingsDoc().get()).exists, isFalse);
    expect(summary().capacity, 10);
    expect(summary().availableSlots, 10 - 2 - 1);
  });

  test('設定の項目だけ無いときも 10 名', () async {
    await SettingsService.instance.updateSlotTtlHours(8); // 文書を作る
    await _settle();
    await _settingsDoc().update({'maxStudentsPerDay': FieldValue.delete()});
    await _settle();
    expect(summary().capacity, 10);
  });

  test('設定画面で保存した「1日の最大利用者数」を定員にする', () async {
    await SettingsService.instance.updateOperatingHours('08:00', '17:00', 6);
    await _settle();
    expect(summary().capacity, 6);
    expect(summary().availableSlots, 6 - 2 - 1);
  });

  test('別の端末で変えた値も反映される（変更通知で読み直す）', () async {
    await SettingsService.instance.updateOperatingHours('08:00', '17:00', 6);
    await _settle();
    await _settingsDoc().update({'maxStudentsPerDay': 20});
    await _settle();
    expect(summary().availableSlots, 20 - 2 - 1);
  });

  test('定員より予定・在室が多いときは 0（負の数にしない）。定員が 0 以下でも例外にしない', () async {
    await SettingsService.instance.updateOperatingHours('08:00', '17:00', 2);
    await _settle();
    expect(summary().availableSlots, 0);
    await _settingsDoc().update({'maxStudentsPerDay': -5});
    await _settle();
    expect(summary().availableSlots, 0);
  });
}
