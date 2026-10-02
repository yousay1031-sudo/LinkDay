import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'firebase_options.dart';
import 'models/app_settings.dart';
import 'models/attendance_record.dart';
import 'models/customer.dart';
import 'models/notification_log.dart';
import 'models/transport_plan.dart';
import 'models/weekly_schedule.dart';
import 'services/attendance_service.dart';
import 'services/customer_service.dart';
import 'services/settings_service.dart';
import 'services/transport_plan_service.dart';
import 'services/vacancy_notification_service.dart';
import 'services/weekly_schedule_service.dart';
import 'theme/app_theme.dart';
import 'widgets/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[Startup] app bootstrap begin');

  // ── 1. Hive 初期化（Web: IndexedDB / Mobile: ファイルシステム）
  await Hive.initFlutter();

  // ── 2. Hive アダプター登録（Firebase 初期化の前に行う）
  Hive.registerAdapter(CustomerAdapter());          // typeId=0
  Hive.registerAdapter(AttendanceRecordAdapter());  // typeId=1
  Hive.registerAdapter(AttendanceStatusAdapter());  // typeId=2
  // Day 5: 週間利用計画
  Hive.registerAdapter(WeeklyScheduleAdapter());    // typeId=3
  Hive.registerAdapter(DailySlotAdapter());         // typeId=4
  Hive.registerAdapter(ScheduleStatusAdapter());    // typeId=5
  Hive.registerAdapter(ScheduleEntryAdapter());     // typeId=6
  // Day 6: 設定・送迎計画
  Hive.registerAdapter(AppSettingsAdapter());       // typeId=7
  Hive.registerAdapter(TransportVehicleRouteAdapter()); // typeId=8
  Hive.registerAdapter(TransportStopAdapter());     // typeId=9
  Hive.registerAdapter(TransportTypeAdapter());     // typeId=10
  // Day 11: 空き枠 LINE 通知の送信記録
  Hive.registerAdapter(NotificationLogAdapter());   // typeId=11
  Hive.registerAdapter(NotificationStatusAdapter()); // typeId=12

  // ── 3. Firebase 初期化
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // ── 4. CustomerService の Hive ボックスを開く
  await CustomerService.instance.init();

  // ── 5. WeeklyScheduleService の Hive ボックスを開く（AttendanceService より先に）
  await WeeklyScheduleService.instance.init();

  // ── 6. AttendanceService の Hive ボックスを開く
  await AttendanceService.instance.init();

  // ── 7. SettingsService の Hive ボックスを開く（Day 6）
  await SettingsService.instance.init();

  // ── 8. TransportPlanService の Hive ボックスを開く（Day 6）
  await TransportPlanService.instance.init();

  // ── 9. VacancyNotificationService の Hive ボックスを開く（Day 11）
  await VacancyNotificationService.instance.init();

  // ── 10. 日本語ロケールデータ初期化（PDF出力の LocaleDataException 対策）
  await initializeDateFormatting('ja_JP', null);

  final s = SettingsService.instance.getSettings();
  debugPrint('[Startup] settings: vehicleCount=${s.vehicleCount}, '
      'vehicleNames=${s.vehicleNames.length}, '
      'facilityLatLng=${s.hasGeocode ? "あり" : "未設定"}');
  debugPrint('[Startup] app bootstrap end');

  runApp(const LinkDayApp());
}

class LinkDayApp extends StatelessWidget {
  const LinkDayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LinkDay',
      debugShowCheckedModeBanner: false,

      // ── テーマ
      theme: AppTheme.lightTheme,

      // ── 認証ゲートを home に設定
      // initialRoute / routes は使わず、AuthGate が状態に応じて画面を切り替える。
      // ログイン成功 → HomeScreen、ログアウト → LoginScreen が自動切替。
      home: const AuthGate(),

      // ── 名前付きルート（各機能画面を追加していく用）
      // AuthGate 経由で保護されるため、直接アクセスは AuthGate を通る
      routes: const {
        // TODO: 各機能実装時にここに追加
        // '/customers':       (context) => const CustomerScreen(),
        // '/weekly-plan':     (context) => const WeeklyPlanScreen(),
        // '/next-day-booking':(context) => const NextDayBookingScreen(),
        // '/transport':       (context) => const TransportScreen(),
        // '/attendance':      (context) => const AttendanceScreen(),
        // '/daily-journal':   (context) => const DailyJournalScreen(),
        // '/support-plan':    (context) => const SupportPlanScreen(),
        // '/staff':           (context) => const StaffScreen(),
      },

      // ── 404 フォールバック
      onUnknownRoute: (settings) {
        return MaterialPageRoute(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('ページが見つかりません')),
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 64,
                    color: AppColors.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'ページが見つかりません\n${settings.name}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context)
                        .pushAndRemoveUntil(
                          MaterialPageRoute(
                            builder: (_) => const AuthGate(),
                          ),
                          (_) => false,
                        ),
                    child: const Text('ホームに戻る'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
