import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/weekly_schedule.dart';
import 'package:linkday_app/screens/attendance_screen.dart';
import 'package:linkday_app/widgets/attendance_status_badge.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/slot_service.dart';
import 'package:linkday_app/theme/app_motion.dart';

import '../support/fake_backend.dart';

/// 在室中ドット（集計バー／カード内バッジ）の静止表示の回帰テスト。
///
/// 通常モーション設定（debugDisableLooping=false, disableAnimations=false）のまま、
/// 読込と有限演出が終わった後に、この2種類のドットが繰り返し描画（フレーム要求）
/// を出さないこと、および状態表示・入室による集計更新が保たれることを確認する。
/// 実顧客データは使わない（一時ディレクトリの Hive にダミーのみ）。
const _green = Color(0xFF2E7D32);

/// 8x8 の円（在室中ドット）。色は不透明の緑そのもの（点滅していれば alpha が変わる）
Finder _dots() => find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final d = w.decoration;
      return d is BoxDecoration &&
          d.shape == BoxShape.circle &&
          d.color == _green &&
          w.constraints?.maxWidth == 8 &&
          w.constraints?.maxHeight == 8;
    });

Future<void> _ms(WidgetTester t, int ms) async {
  var left = ms;
  while (left > 0) {
    final step = left > 16 ? 16 : left;
    await t.pump(Duration(milliseconds: step));
    left -= step;
  }
}

Future<void> _real(WidgetTester t, [int ms = 300]) async {
  for (var i = 0; i < 3; i++) {
    await t
        .runAsync(() => Future<void>.delayed(Duration(milliseconds: ms ~/ 3)));
    await t.pump();
  }
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_inroom_dot_');
    Hive.init(tmp.path);
    void reg<T>(TypeAdapter<T> a) {
      if (!Hive.isAdapterRegistered(a.typeId)) Hive.registerAdapter<T>(a);
    }

    reg(CustomerAdapter());
    reg(AttendanceRecordAdapter());
    reg(AttendanceStatusAdapter());
    reg(WeeklyScheduleAdapter());
    reg(DailySlotAdapter());
    reg(ScheduleStatusAdapter());
    reg(ScheduleEntryAdapter());
    reg(AppSettingsAdapter());
    await FakeBackend.attachWithStaff();
    // 週間利用計画は Firestore（FakeBackend.attachWithStaff で接続済み）
    await AttendanceService.instance.init();
    await SettingsService.instance.init();
    SlotService.instance.remoteEnabled = false;
  });

  tearDownAll(() async {
    await Future.any<Object?>([
      Hive.close(),
      Future<Object?>.delayed(const Duration(seconds: 3)),
    ]);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // 通常モーション設定: ループ無効化フラグを使わない
  setUp(() => AppMotion.debugDisableLooping = false);

  testWidgets('在室中ドットは読込・有限演出の後にフレームを要求し続けない／入室で集計が更新される', (t) async {
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final key = AttendanceRecord.makeDateKey(DateTime.now());
    await t.runAsync(() async {
      await Hive.box<AttendanceRecord>('attendance_records').clear();
      await FakeBackend.resetCustomers();
      await AttendanceService.instance.upsertRecord(AttendanceRecord(
          customerId: 'c-in',
          customerName: '在室 一郎',
          dateKey: key,
          status: AttendanceStatus.present,
          checkInTime: DateTime.now()));
      await AttendanceService.instance.upsertRecord(AttendanceRecord(
          customerId: 'c-wait', customerName: '予定 二郎', dateKey: key));
    });

    await t.pumpWidget(const MaterialApp(home: AttendanceScreen()));
    await _ms(t, 1500); // 読込＋カード入場などの有限演出が終わる時間

    // 状態の表示: 在室中ラベル（集計バー・絞り込み・バッジ）と集計バーのドット1つ
    expect(find.text('在室中'), findsNWidgets(3));
    expect(find.text('在室 一郎'), findsOneWidget);
    expect(_dots(), findsOneWidget); // 集計バーのドット（カードは compact バッジでアイコン表示）
    // 点滅していない: 時間が経っても色は不透明の緑のまま
    await _ms(t, 700);
    expect(_dots(), findsOneWidget);

    // 繰返し描画を要求しない（通常モーションのまま、フレーム要求がない）
    expect(t.binding.hasScheduledFrame, isFalse,
        reason: '静止後に次のフレームが要求されている（無限アニメが残っている）');
    expect(
        AttendanceService.instance.getTodaySummary(DateTime.now()).presentCount,
        1);

    // 入室操作: 在室中カードが増える（バッジ＋ボタン列ラベルで+2）／集計が更新される
    await t.tap(find.byIcon(Icons.login).first);
    await _real(t);
    await _ms(t, 3000); // スナックバー等の有限演出
    expect(find.text('在室中'), findsNWidgets(5));
    expect(_dots(), findsOneWidget);
    expect(
        AttendanceService.instance.getTodaySummary(DateTime.now()).presentCount,
        2);
    expect(
        AttendanceService.instance
            .getTodaySummary(DateTime.now())
            .scheduledCount,
        0);

    // 更新後も静止
    await _ms(t, 3000);
    expect(t.binding.hasScheduledFrame, isFalse);
    expect(t.takeException(), isNull);

    await t.pumpWidget(const SizedBox.shrink());
    await _real(t);
  });

  testWidgets('バッジの在室中ドットは静止（通常モーションでもフレームを要求しない）', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AttendanceStatusBadge(status: AttendanceStatus.present),
      ),
    ));
    await _ms(t, 1500);
    expect(find.text('在室中'), findsOneWidget);
    expect(_dots(), findsOneWidget);
    expect(t.binding.hasScheduledFrame, isFalse,
        reason: 'バッジのドットが繰返しフレームを要求している');
    await _ms(t, 2000);
    expect(t.binding.hasScheduledFrame, isFalse);
  });
}
