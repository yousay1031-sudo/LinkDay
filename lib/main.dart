import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'data/data_errors.dart';
import 'data/staff_session.dart';
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
import 'verify/verify_bootstrap.dart';
import 'verify/verify_config.dart';
import 'verify/verify_seed.dart';
import 'widgets/auth_gate.dart';
import 'widgets/motion/reduced_motion_scope.dart';
import 'widgets/staff_bar.dart';
import 'widgets/staff_picker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[Startup] app bootstrap begin');

  // ── 0. 【検証構成のみ】エミュレータへ到達できなければ起動を止める。
  //    通常ビルドでは VerifyConfig.enabled が const false なので、この分岐は
  //    出力から消える。本番へはフォールバックしない。
  if (VerifyConfig.enabled) {
    final problem = await VerifyBootstrap.preflight();
    if (problem != null) {
      runApp(VerifyFailureApp(message: problem));
      return;
    }
  }

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
  if (VerifyConfig.enabled) {
    // 検証構成: demo プロジェクト + Auth/Firestore エミュレータ（docs/VERIFY_ENV.md）
    final problem = await VerifyBootstrap.initFirebase();
    if (problem != null) {
      runApp(VerifyFailureApp(message: problem));
      return;
    }
  } else {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  // ── 3.5 Firestore の端末内キャッシュ（オフライン時の表示・入力用）
  //    複数タブで同期させる。共用端末のためログアウト時に消す（logout_flow.dart）。
  //    有効にできなくても（非対応ブラウザ等）メモリキャッシュで動作を続ける。
  await _enableFirestorePersistence();

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
  // 検証構成では LINE 送信・連携コード発行などの外部呼び出しを遮断する
  // （remoteEnabled=false）。通常ビルドは従来どおり true。
  await VacancyNotificationService.instance
      .init(remoteEnabled: !VerifyConfig.enabled);

  // ── 10. 日本語ロケールデータ初期化（PDF出力の LocaleDataException 対策）
  await initializeDateFormatting('ja_JP', null);

  // ── 10.5 【検証構成のみ】ダミーデータ投入（URL の ?verify_data= で切替）
  if (VerifyConfig.enabled) {
    await VerifySeed.runFromUrl();
  }

  final s = SettingsService.instance.getSettings();
  debugPrint('[Startup] settings: vehicleCount=${s.vehicleCount}, '
      'vehicleNames=${s.vehicleNames.length}, '
      'facilityLatLng=${s.hasGeocode ? "あり" : "未設定"}');
  debugPrint('[Startup] app bootstrap end');

  runApp(const LinkDayApp());
}

Future<void> _enableFirestorePersistence() async {
  if (!kIsWeb) return; // モバイルは既定で永続化される
  try {
    // 複数タブ同期（synchronizeTabs）は Settings.persistenceEnabled では
    // 指定できない（web 実装が単一タブ用キャッシュになる）ため、旧 API を使う。
    await FirebaseFirestore.instance
        // ignore: deprecated_member_use
        .enablePersistence(const PersistenceSettings(synchronizeTabs: true));
    debugPrint('[Startup] Firestore persistence enabled (multi-tab)');
  } catch (e) {
    debugPrint('[Startup] Firestore persistence not enabled: $e');
  }
}

/// 全画面共通のナビゲーター（画面上部の担当者帯からダイアログを開くため）
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 全画面共通の SnackBar 表示口（保存失敗の通知用）
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class LinkDayApp extends StatefulWidget {
  const LinkDayApp({super.key});

  @override
  State<LinkDayApp> createState() => _LinkDayAppState();
}

class _LinkDayAppState extends State<LinkDayApp> {
  StreamSubscription<String>? _errorSub;

  @override
  void initState() {
    super.initState();
    // 記録を変える操作で担当者が未選択なら、その場で選択画面を出す
    StaffSession.instance.prompter = () async {
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) return null;
      return showStaffPicker(ctx, reason: '記録するには、担当者を選んでください。');
    };
    // 送信は待たずに戻る書き込みの失敗を知らせる
    _errorSub = DataErrors.messages.listen((msg) {
      appMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 6),
        ),
      );
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LinkDay',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appMessengerKey,

      // ── テーマ
      theme: AppTheme.lightTheme,

      // ── Web の prefers-reduced-motion を MediaQuery.disableAnimations に反映
      builder: (context, child) {
        // ログイン後は画面上部に「いまの担当者」を常に表示する
        final withStaff = StaffBarScope(
          navigatorKey: appNavigatorKey,
          child: child ?? const SizedBox.shrink(),
        );
        final scoped = ReducedMotionScope(child: withStaff);
        // 検証構成では細い帯で常に区別できるようにする（通常ビルドでは消える）
        return VerifyConfig.enabled ? VerifyStrip(child: scoped) : scoped;
      },

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
