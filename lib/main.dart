import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'firebase_options.dart';
import 'models/attendance_record.dart';
import 'models/customer.dart';
import 'services/attendance_service.dart';
import 'services/customer_service.dart';
import 'theme/app_theme.dart';
import 'widgets/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 1. Hive 初期化（Web: IndexedDB / Mobile: ファイルシステム）
  await Hive.initFlutter();

  // ── 2. Hive アダプター登録（Firebase 初期化の前に行う）
  Hive.registerAdapter(CustomerAdapter());          // typeId=0
  Hive.registerAdapter(AttendanceRecordAdapter());  // typeId=1
  Hive.registerAdapter(AttendanceStatusAdapter());  // typeId=2

  // ── 3. Firebase 初期化
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // ── 4. CustomerService の Hive ボックスを開く
  await CustomerService.instance.init();

  // ── 5. AttendanceService の Hive ボックスを開く
  await AttendanceService.instance.init();

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
