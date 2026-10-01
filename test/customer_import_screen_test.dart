import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/customer_import_screen.dart';
import 'package:linkday_app/services/customer_service.dart';

/// 利用者インポート画面: 初回 build / 空データ状態で例外なく表示されること
///
/// 実行: flutter test --platform chrome test/customer_import_screen_test.dart
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await Hive.initFlutter('linkday_import_screen_test');
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(CustomerAdapter());
    }
    await Hive.deleteBoxFromDisk('customers');
    await CustomerService.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
  });

  testWidgets('ファイル選択ステップが表示され、16 列チップとテンプレートボタンがある',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CustomerImportScreen()));
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);

    expect(find.text('利用者インポート'), findsOneWidget);
    expect(find.text('ファイルを選択'), findsOneWidget);
    expect(find.text('氏名'), findsOneWidget);
    expect(find.text('備考'), findsOneWidget);
    expect(find.textContaining('サンプル付きテンプレートをダウンロード (.xlsx)'), findsOneWidget);
    expect(find.textContaining('サンプル付きテンプレートをダウンロード (.csv)'), findsOneWidget);
  });
}
