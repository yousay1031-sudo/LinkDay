// スクリーンショット用ハーネス（本番ビルドには含まれない）
// flutter build web --release -t tool/import_harness_main.dart -o /tmp/harness
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/customer_import_screen.dart';
import 'package:linkday_app/services/customer_export_service.dart';
import 'package:linkday_app/services/customer_import_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/theme/app_theme.dart';

final GlobalKey harnessKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter('linkday_harness');
  Hive.registerAdapter(CustomerAdapter());
  await Hive.deleteBoxFromDisk('customers');
  await CustomerService.instance.init();
  await CustomerService.instance.addCustomer(Customer(
      id: 'exist', name: '山田 太郎', nameKana: 'ヤマダ タロウ',
      recipientCertNumber: '1234567890'));
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.lightTheme,
    home: _Harness(step: Uri.base.queryParameters['step'] ?? 'pick'),
  ));
}

class _Harness extends StatefulWidget {
  final String step;
  const _Harness({required this.step});
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  @override
  void initState() {
    super.initState();
    if (widget.step != 'pick') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final bytes = CustomerExportService.instance.buildTemplateXlsx();
        final preview = CustomerImportService.instance.parse(
            fileName: 'linkday_customer_sample.xlsx',
            bytes: Uint8List.fromList(bytes));
        final st = harnessKey.currentState as dynamic;
        // ignore: avoid_dynamic_calls
        st.debugSetPreview(preview);
        if (widget.step == 'dialog' || widget.step == 'result') {
          await Future.delayed(const Duration(milliseconds: 600));
          // ignore: avoid_dynamic_calls
          st.debugExecute(overwriteAll: widget.step == 'result');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => CustomerImportScreen(key: harnessKey);
}
