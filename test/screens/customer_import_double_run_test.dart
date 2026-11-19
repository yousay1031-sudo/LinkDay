import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/screens/customer_import_screen.dart';
import 'package:linkday_app/services/customer_import_service.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/theme/app_motion.dart';

import '../support/fake_backend.dart';

/// インポート画面: 二重実行防止 / 戻る制御 / 例外・失敗後の復帰
///
/// 実行: flutter test test/screens/customer_import_double_run_test.dart
/// 実顧客データは使わない（一時ディレクトリの Hive にダミーのみ）。

class _FakePicker extends FilePicker {
  int calls = 0;
  Completer<FilePickerResult?>? pending;
  Object? throwOnNext;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) {
    calls++;
    final err = throwOnNext;
    if (err != null) {
      throwOnNext = null;
      return Future.error(err);
    }
    final c = Completer<FilePickerResult?>();
    pending = c;
    return c.future;
  }
}

const _header =
    '氏名,ふりがな,生年月日,性別,電話番号,保護者氏名,保護者電話,LINE_ID,受給者証番号,受給者証期限,月間支給量,定期利用曜日,送迎場所1,送迎場所2,送迎場所3,備考';

Uint8List _csv(List<String> rows) =>
    Uint8List.fromList(utf8.encode([_header, ...rows].join('\n')));

/// 先頭が重複行（既存の受給者証番号と一致）、2 行目が新規
const _dupRow = 'ダミー 重複,ダミー チョウフク,,,,,,,9990000001,,23,,,,,';
const _newRow = 'ダミー 新規,ダミー シンキ,,,,,,,9990000002,,23,,,,,';

void main() {
  late Directory tmp;
  late _FakePicker picker;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('linkday_import_dbl_');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(CustomerAdapter());
    await FakeBackend.attachWithStaff();
    // Hive の実ファイル I/O は FakeAsync 内で行うと詰まるため、投入は 1 度だけここで行う
    await FakeBackend.resetCustomers();
    await CustomerService.instance.addCustomer(Customer(
      id: 'existing-1',
      name: '既存 太郎',
      nameKana: 'キゾン タロウ',
      recipientCertNumber: '9990000001',
    ));
  });

  tearDownAll(() async {
    // FakeAsync 内で開始した Hive 書込みの完了待ちで close が戻らないことがあるため、
    // 終了処理のみ上限付きにする（テスト本体の検証には影響しない）
    await Future.any<Object?>([
      Hive.close(),
      Future<Object?>.delayed(const Duration(seconds: 3)),
    ]);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    AppMotion.debugDisableLooping = true;
    picker = _FakePicker();
    FilePicker.platform = picker;
  });

  tearDown(() => AppMotion.debugDisableLooping = false);

  /// Navigator 上にインポート画面を積む（pop 結果の検証用）
  Future<void> pumpScreen(
    WidgetTester tester, {
    CustomerImportScreen? screen,
    List<Object?>? popResults,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () async {
                final r = await Navigator.of(ctx).push<bool>(MaterialPageRoute(
                    builder: (_) => screen ?? const CustomerImportScreen()));
                popResults?.add(r);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
  }

  dynamic stateOf(WidgetTester t) => t.state(find.byType(CustomerImportScreen));

  ImportPreview previewOf(List<String> rows) =>
      CustomerImportService.instance
          .parse(fileName: 't.csv', bytes: _csv(rows));

  FilledButton execButton(WidgetTester t) =>
      t.widget<FilledButton>(find.byKey(const Key('importExecuteButton')));

  group('ファイル選択の二重実行防止', () {
    testWidgets('選択中の再タップで pickFiles は 1 回だけ、キャンセル後は操作可能に戻る',
        (tester) async {
      await pumpScreen(tester);
      await tester.tap(find.byKey(const Key('importPickButton')));
      await tester.pump();
      expect(picker.calls, 1);
      expect(find.text('ファイルを読み込み中…'), findsOneWidget);
      final btn = tester
          .widget<FilledButton>(find.byKey(const Key('importPickButton')));
      expect(btn.onPressed, isNull, reason: '処理中はボタン無効');

      // 無効ボタンへの追加タップ・内部経路の再実行ともに呼ばれない
      await tester.tap(find.byKey(const Key('importPickButton')),
          warnIfMissed: false);
      await tester.pump();
      expect(picker.calls, 1);

      picker.pending!.complete(null); // ユーザーがキャンセル
      await tester.pump();
      expect(find.text('ファイルを選択'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('importPickButton')))
              .onPressed,
          isNotNull);
      expect(tester.takeException(), isNull);

      // 復帰後は再選択できる
      await tester.tap(find.byKey(const Key('importPickButton')));
      await tester.pump();
      expect(picker.calls, 2);
      picker.pending!.complete(null);
      await tester.pump();
    });

    testWidgets('ピッカーが例外 / 不正ファイルでもエラー表示のうえ操作可能に戻る', (tester) async {
      await pumpScreen(tester);
      picker.throwOnNext = StateError('picker boom');
      await tester.tap(find.byKey(const Key('importPickButton')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('読み込みエラー'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('importPickButton')))
              .onPressed,
          isNotNull);

      // 拡張子が非対応のファイル → parse が FormatException
      await tester.tap(find.byKey(const Key('importPickButton')));
      await tester.pump();
      picker.pending!.complete(FilePickerResult([
        PlatformFile(
            name: 'bad.pdf', size: 3, bytes: Uint8List.fromList([1, 2, 3]))
      ]));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('読み込みエラー'), findsOneWidget);
      expect(find.text('ファイルを選択'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 正常ファイルならプレビューへ進める
      await tester.tap(find.byKey(const Key('importPickButton')));
      await tester.pump();
      picker.pending!.complete(FilePickerResult([
        PlatformFile(name: 'ok.csv', size: 1, bytes: _csv([_newRow]))
      ]));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('importExecuteButton')), findsOneWidget);
      expect(find.textContaining('読み込みエラー'), findsNothing);
    });
  });

  group('取り込み実行の二重実行防止（実サービス＋重複ダイアログで処理を保留）', () {
    testWidgets('処理中の再実行はサービスを再呼び出ししない / 成功後に操作可能へ戻る',
        (tester) async {
      await pumpScreen(tester);
      final st = stateOf(tester);
      final before = FakeBackend.customerCount;
      st.debugSetPreview(previewOf([_dupRow, _newRow]));
      await tester.pump();

      unawaited(st.debugExecute() as Future<void>);
      await tester.pump();
      await tester.pump();
      // 重複ダイアログで保留中
      expect(find.text('重複候補（行 2）'), findsOneWidget);
      expect(st.debugIsImporting, isTrue);
      expect(find.byKey(const Key('importProgress')), findsOneWidget);
      expect(execButton(tester).onPressed, isNull);

      // 内部経路から再実行しても即座に戻り、ダイアログも増えない
      await (st.debugExecute() as Future<void>);
      await (st.debugExecute() as Future<void>);
      await tester.pump();
      expect(find.text('重複候補（行 2）'), findsOneWidget);
      expect(FakeBackend.customerCount, before,
          reason: '保留中は新規行も書き込まれていない（再実行されていない）');

      // スキップを選ぶ → 2 行目が取り込まれ結果画面へ
      await tester.tap(find.text('スキップ'));
      await tester.pump();
      // Hive の実ファイル I/O は FakeAsync 外で完了させる
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(st.debugIsImporting, isFalse);
      expect(find.text('取り込みが完了しました'), findsOneWidget);
      expect(FakeBackend.customerCount, before + 1);
      final names = FakeBackend.allCustomers
          .map((c) => c.name)
          .toList()
        ..sort();
      expect(names.where((n) => n == 'ダミー 新規').length, 1,
          reason: '新規行はちょうど 1 回だけ保存');
      expect(
          tester
              .widget<ButtonStyleButton>(find
                  .ancestor(
                      of: find.text('顧客一覧へ戻る'),
                      matching: find.bySubtype<ButtonStyleButton>())
                  .first)
              .onPressed,
          isNotNull);
    });

    testWidgets('「中止」でも処理中表示が解除され、操作可能へ戻る', (tester) async {
      await pumpScreen(tester);
      final st = stateOf(tester);
      final before = FakeBackend.customerCount;
      st.debugSetPreview(previewOf([_dupRow, _newRow]));
      await tester.pump();
      unawaited(st.debugExecute() as Future<void>);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('中止'));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(st.debugIsImporting, isFalse);
      expect(find.textContaining('中止しました'), findsOneWidget);
      expect(FakeBackend.customerCount, before,
          reason: '中止時、後続行は保存されない');
    });
  });

  group('例外復帰（executeOverride で呼び出し回数を計測）', () {
    testWidgets('例外 → エラー表示・ボタン復帰・戻る可能 → 再実行 1 回だけ成功', (tester) async {
      int calls = 0;
      final gate = Completer<void>();
      bool shouldThrow = true;
      final screen = CustomerImportScreen(
        executeOverride: (p, {required resolveDuplicate, onProgress}) async {
          calls++;
          await gate.future;
          if (shouldThrow) throw StateError('save boom');
          return const CustomerImportResult(
              imported: 1,
              overwritten: 0,
              skipped: 0,
              errorCount: 0,
              aborted: false,
              errors: [],
              certAlerts: []);
        },
      );
      await pumpScreen(tester, screen: screen);
      final st = stateOf(tester);
      st.debugSetPreview(previewOf([_newRow]));
      await tester.pump();

      // 連打: タップ → 無効化 → 再タップ・内部再実行
      await tester.tap(find.byKey(const Key('importExecuteButton')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('importExecuteButton')),
          warnIfMissed: false);
      await tester.tap(find.byKey(const Key('importExecuteButton')),
          warnIfMissed: false);
      await (st.debugExecute() as Future<void>);
      await tester.pump();
      expect(calls, 1, reason: '処理中の連打でもサービスは 1 回');
      expect(find.text('取り込み中…'), findsOneWidget);

      // 失敗
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('取り込みエラー'), findsOneWidget);
      expect(st.debugIsImporting, isFalse);
      expect(execButton(tester).onPressed, isNotNull);
      expect(find.text('取り込み中…'), findsNothing);
      expect(find.byKey(const Key('importProgress')), findsNothing);
      expect(tester.takeException(), isNull);

      // 復帰後に再実行できる（合計 2 回）
      shouldThrow = false;
      await tester.tap(find.byKey(const Key('importExecuteButton')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('取り込みが完了しました'), findsOneWidget);
    });

    testWidgets('処理中は戻る操作（システム戻る・AppBar 矢印）を無効化し、完了後は戻れる',
        (tester) async {
      final gate = Completer<CustomerImportResult>();
      final results = <Object?>[];
      final screen = CustomerImportScreen(
        executeOverride: (p, {required resolveDuplicate, onProgress}) =>
            gate.future,
      );
      await pumpScreen(tester, screen: screen, popResults: results);
      final st = stateOf(tester);
      st.debugSetPreview(previewOf([_newRow]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('importExecuteButton')));
      await tester.pump();

      // AppBar の戻る矢印は無効
      final back = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.arrow_back));
      expect(back.onPressed, isNull);
      // システム戻る（Android 戻るキー / ブラウザ戻る相当）は PopScope が拒否
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CustomerImportScreen), findsOneWidget);
      expect(results, isEmpty);

      gate.complete(const CustomerImportResult(
          imported: 1,
          overwritten: 0,
          skipped: 0,
          errorCount: 0,
          aborted: false,
          errors: [],
          certAlerts: []));
      await tester.pumpAndSettle();
      expect(find.text('取り込みが完了しました'), findsOneWidget);

      // 完了後は戻れ、結果として「取り込みあり=true」が返る
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CustomerImportScreen), findsNothing);
      expect(results, [true]);
    });

    testWidgets('例外後は戻れる（戻り値 true で一覧再読込）', (tester) async {
      final results = <Object?>[];
      final screen = CustomerImportScreen(
        executeOverride: (p, {required resolveDuplicate, onProgress}) async =>
            throw StateError('x'),
      );
      await pumpScreen(tester, screen: screen, popResults: results);
      stateOf(tester).debugSetPreview(previewOf([_newRow]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('importExecuteButton')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('取り込みエラー'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CustomerImportScreen), findsNothing);
      // 途中保存の可能性があるため true（一覧を再読込させる）
      expect(results, [true]);
    });
  });
}
