import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/screens/home_screen.dart';
import 'package:linkday_app/services/attendance_pdf_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/transport_pdf_service.dart';
import 'package:linkday_app/services/weekly_schedule_pdf_service.dart';

/// 出席・送迎・週間利用計画の PDF の事業所名は、設定の事業所名（決め打ちの「LinkDay」ではない）。
/// 未設定のときは、ホームの上のバーと同じ「事業所名 未設定」。
void main() {
  tearDown(() => SettingsService.instance.debugSetSettings(AppSettings()));

  String attendance() => AttendancePdfService.facilityName;
  String transport() => TransportPdfService.facilityName;
  String weekly() => WeeklySchedulePdfService.facilityName;

  test('設定の事業所名が出る', () {
    SettingsService.instance
        .debugSetSettings(AppSettings(facilityName: ' 架空の事業所 '));
    expect(
        [attendance(), transport(), weekly()], ['架空の事業所', '架空の事業所', '架空の事業所']);
    expect([attendance(), transport(), weekly()], isNot(contains('LinkDay')));
  });

  test('未設定（空・空白だけ）のときはホームの上のバーと同じ表示', () {
    for (final name in ['', '　 ']) {
      final s = AppSettings(facilityName: name);
      SettingsService.instance.debugSetSettings(s);
      expect(HomeScreen.facilityLabel(s), '事業所名 未設定');
      expect([attendance(), transport(), weekly()],
          ['事業所名 未設定', '事業所名 未設定', '事業所名 未設定']);
    }
  });

  test('設定が変わればその場で変わる（開き直さなくてよい）', () {
    SettingsService.instance
        .debugSetSettings(AppSettings(facilityName: '架空の事業所 A'));
    expect(attendance(), '架空の事業所 A');
    SettingsService.instance
        .debugSetSettings(AppSettings(facilityName: '架空の事業所 B'));
    expect([attendance(), transport(), weekly()],
        ['架空の事業所 B', '架空の事業所 B', '架空の事業所 B']);
  });
}
