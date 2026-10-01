// スクリーンショット/動作確認用ハーネス（本番ビルドには含まれない）
// flutter build web --release -t tool/resolve_harness_main.dart -o /tmp/harness2
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/customer_edit_screen.dart';
import 'package:linkday_app/screens/transport_location_resolve_screen.dart';
import 'package:linkday_app/services/customer_export_service.dart';
import 'package:linkday_app/services/customer_import_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  await Hive.initFlutter('linkday_harness2');
  Hive.registerAdapter(CustomerAdapter());
  Hive.registerAdapter(AppSettingsAdapter());
  await Hive.deleteBoxFromDisk('customers');
  await Hive.deleteBoxFromDisk('app_settings');
  await CustomerService.instance.init();
  await SettingsService.instance.init();

  // Day 7 サンプル 10 件を投入
  final bytes = CustomerExportService.instance.buildTemplateXlsx();
  final preview = CustomerImportService.instance.parse(fileName: 's.xlsx', bytes: bytes);
  await CustomerImportService.instance.execute(preview, resolveDuplicate: (_) async => null);
  // 一部を解決済み/失敗にして混在状態を作る
  final all = CustomerService.instance.getAllCustomers();
  all[0].setTransportCoord(0, 42.9241, 143.2051, Customer.locResolved);
  all[0].setTransportCoord(1, 42.9177, 143.2042, Customer.locManual);
  await CustomerService.instance.updateCustomer(all[0]);
  all[1].setTransportCoord(1, null, null, Customer.locFailed);
  await CustomerService.instance.updateCustomer(all[1]);
  all[2].setTransportCoord(0, 43.0621, 141.3544, Customer.locManual); // 札幌 → 市外警告
  await CustomerService.instance.updateCustomer(all[2]);

  final step = Uri.base.queryParameters['step'] ?? 'resolve';
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.lightTheme,
    home: step == 'edit'
        ? CustomerEditScreen(customer: CustomerService.instance.getAllCustomers()[0])
        : const TransportLocationResolveScreen(),
  ));
}
