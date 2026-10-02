import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/customer_import_screen.dart';
import 'package:linkday_app/services/customer_service.dart';

/// 利用者インポート画面: 初回 build / 空データ状態で例外なく表示されること
///
/// 実行: flutter test test/customer_import_screen_test.dart
///
/// 【Hive.init / hive パッケージを使う理由】
/// Hive.initFlutter()（hive_flutter）は path_provider 経由で
/// getApplicationDocumentsDirectory() を呼ぶため、VM テストでは
/// MissingPluginException になる。一時ディレクトリを明示指定する
/// Hive.init(path) を使うことで VM 上でも実行可能にしている。
void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('linkday_import_screen_test_');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(CustomerAdapter());
    }
    await CustomerService.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
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
