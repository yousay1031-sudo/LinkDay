import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/customer_import_screen.dart';
import 'package:linkday_app/services/customer_import_service.dart';
import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/theme/app_theme.dart';

import '../support/fake_backend.dart';

/// Day 15 ブラウザ検証で見つかった表示崩れの回帰テスト
/// 1. 390px 幅で下部「キャンセル」ボタンが 2 行に折り返していた
/// 2. Web で日本語フォント読込後もサンプル表の列幅が古いまま見出しが重なっていた
///    → システムフォント変更通知で表を作り直す
const _header =
    '氏名,ふりがな,生年月日,性別,電話番号,保護者氏名,保護者電話,LINE_ID,受給者証番号,受給者証期限,月間支給量,定期利用曜日,送迎場所1,送迎場所2,送迎場所3,備考';

void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('linkday_import_layout_');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(CustomerAdapter());
    await FakeBackend.attachWithStaff();
  });

  tearDownAll(() async {
    await Future.any<Object?>(
        [Hive.close(), Future<Object?>.delayed(const Duration(seconds: 3))]);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() => AppMotion.debugDisableLooping = true);
  tearDown(() => AppMotion.debugDisableLooping = false);

  Future<void> pumpPreview(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: const CustomerImportScreen(),
    ));
    final preview = CustomerImportService.instance.parse(
      fileName: 't.csv',
      bytes: Uint8List.fromList(utf8.encode(
          '$_header\nダミー 一郎,ダミー イチロウ,,,,,,,9990000101,,23,,,,,')),
    );
    final dynamic st = tester.state(find.byType(CustomerImportScreen));
    // ignore: avoid_dynamic_calls
    st.debugSetPreview(preview);
    await tester.pumpAndSettle();
  }

  testWidgets('390px 幅: プレビュー下部「キャンセル」は 1 行で表示される', (tester) async {
    await pumpPreview(tester);
    final label = find.text('キャンセル');
    expect(label, findsOneWidget);
    final text = tester.widget<Text>(label);
    expect(text.maxLines, 1);
    expect(text.softWrap, isFalse);
    // 1 行分の高さに収まっている（折り返していない）
    final para = tester.renderObject<RenderParagraph>(label);
    expect(para.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('システムフォント変更通知でサンプル表を作り直す', (tester) async {
    await pumpPreview(tester);
    final tableFinder = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_SampleTable');
    expect(tableFinder, findsOneWidget);
    final dynamic st = tester.state(tableFinder);
    // ignore: avoid_dynamic_calls
    expect(st.debugFontGeneration, 0);
    final key0 = tester.widget<DataTable>(find.byType(DataTable)).key;

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.system.name,
      SystemChannels.system.codec
          .encodeMessage(<String, dynamic>{'type': 'fontsChange'}),
      (_) {},
    );
    await tester.pump();

    // ignore: avoid_dynamic_calls
    expect(st.debugFontGeneration, 1);
    final key1 = tester.widget<DataTable>(find.byType(DataTable)).key;
    expect(key1, isNot(equals(key0)));
    expect(tester.takeException(), isNull);
  });
}
