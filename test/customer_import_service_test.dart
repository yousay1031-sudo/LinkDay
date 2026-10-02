import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/services/customer_export_service.dart';
import 'package:linkday_app/services/customer_import_service.dart';
import 'package:linkday_app/services/customer_service.dart';

/// Day 7: 顧客インポート（Excel/CSV）サービステスト
///
/// 正本: test/fixtures/linkday_customer_sample.xlsx（顧客マスタ A1:P11）
void main() {
  late Directory tmp;
  final svc = CustomerImportService.instance;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('linkday_import_');
    Hive.init(tmp.path);
    Hive.registerAdapter(CustomerAdapter());
    await CustomerService.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  Future<void> clearBox() async {
    final box = Hive.box<Customer>('customers');
    await box.clear();
  }

  // ── 値パーサ ────────────────────────────────────────────────

  group('parsers', () {
    test('定期利用曜日「月,水,金」→ [1,3,5]', () {
      expect(CustomerImportService.parseRegularDays('月,水,金'), [1, 3, 5]);
    });
    test('定期利用曜日の揺れ（読点・連結・曜日付き・英語）', () {
      expect(CustomerImportService.parseRegularDays('月、水、金'), [1, 3, 5]);
      expect(CustomerImportService.parseRegularDays('月水金'), [1, 3, 5]);
      expect(CustomerImportService.parseRegularDays('月曜・水曜日・金曜'), [1, 3, 5]);
      expect(CustomerImportService.parseRegularDays('Mon, Wed, Fri'), [1, 3, 5]);
      expect(CustomerImportService.parseRegularDays('月,火,水,木,金,土,日'),
          [1, 2, 3, 4, 5, 6, 7]);
      expect(CustomerImportService.parseRegularDays(''), isEmpty);
      expect(CustomerImportService.parseRegularDays(null), isEmpty);
    });
    test('性別の正規化', () {
      expect(CustomerImportService.normalizeGender('男児'), '男児');
      expect(CustomerImportService.normalizeGender('女児'), '女児');
      expect(CustomerImportService.normalizeGender('男'), '男児');
      expect(CustomerImportService.normalizeGender('女性'), '女児');
      expect(CustomerImportService.normalizeGender('M'), '男児');
      expect(CustomerImportService.normalizeGender('f'), '女児');
      expect(CustomerImportService.normalizeGender('不明'), isNull);
      expect(CustomerImportService.normalizeGender(''), isNull);
    });
    test('日付: DateTime / Excel シリアル / 文字列各種', () {
      expect(CustomerImportService.parseDate(DateTime(2015, 4, 12, 9)),
          DateTime(2015, 4, 12));
      expect(CustomerImportService.parseDate(46203), DateTime(2026, 6, 30));
      expect(CustomerImportService.parseDate('46203'), DateTime(2026, 6, 30));
      expect(CustomerImportService.parseDate('2026/06/30'), DateTime(2026, 6, 30));
      expect(CustomerImportService.parseDate('2026-6-30'), DateTime(2026, 6, 30));
      expect(CustomerImportService.parseDate('2026年6月30日'), DateTime(2026, 6, 30));
      expect(CustomerImportService.parseDate('20260630'), DateTime(2026, 6, 30));
      expect(CustomerImportService.parseDate('abc'), isNull);
    });
    test('受給者証番号は文字列のまま（数値セル由来の .0 は補正）', () {
      expect(CustomerImportService.normalizeCertNumber('1234567890'), '1234567890');
      expect(CustomerImportService.normalizeCertNumber(1234567890.0), '1234567890');
      expect(CustomerImportService.normalizeCertNumber('0012345678'), '0012345678');
    });
    test('LINE_ID 形式', () {
      expect(CustomerImportService.isValidLineUserId('U${'a' * 32}'), isTrue);
      expect(CustomerImportService.isValidLineUserId('U1234567890abcdef01'), isFalse);
    });
  });

  // ── XLSX（正本ファイル）─────────────────────────────────────

  group('xlsx (linkday_customer_sample.xlsx)', () {
    late ImportPreview preview;

    setUp(() async {
      await clearBox();
      final bytes =
          File('test/fixtures/linkday_customer_sample.xlsx').readAsBytesSync();
      preview = svc.parse(
        fileName: 'linkday_customer_sample.xlsx',
        bytes: bytes,
        existingCustomers: const [],
      );
    });

    test('ヘッダー16列が正本と一致・10行すべて有効', () {
      expect(preview.fileType, ImportFileType.xlsx);
      expect(preview.headers, kCustomerImportHeaders);
      expect(preview.headerWarnings, isEmpty);
      expect(preview.totalRows, 10);
      expect(preview.validRows, 10);
      expect(preview.errorRows, 0);
      expect(preview.duplicateRows, 0);
    });

    test('山田太郎の 16 フィールドが想定どおり', () {
      final c = preview.rows.first.customer!;
      expect(c.name, '山田 太郎');
      expect(c.nameKana, 'ヤマダ タロウ');
      expect(c.birthday, DateTime(2015, 4, 12));
      expect(c.gender, '男児');
      expect(c.phone, '0155-20-1234');
      expect(c.guardianName, '山田 健一');
      expect(c.guardianPhone, '090-1234-5678');
      expect(c.lineUserId, 'U1234567890abcdef01');
      expect(c.recipientCertNumber, '1234567890');
      expect(c.recipientCertExpiry, DateTime(2026, 6, 30));
      expect(c.monthlyAvailableDays, 23);
      expect(c.regularDays, [1, 3, 5]);
      expect(c.transportLocations, ['北海道帯広市東1条南3丁目', '帯広駅前']);
      expect(c.notes, 'アレルギー：そば');
    });

    test('ひらがな ふりがな はカタカナに正規化、月間支給量 int、送迎場所3件', () {
      final suzuki = preview.rows[1].customer!;
      expect(suzuki.nameKana, 'スズキ ハナコ');
      expect(suzuki.transportLocations.length, 3);
      final tanaka = preview.rows[2].customer!;
      expect(tanaka.monthlyAvailableDays, 20);
      expect(tanaka.regularDays, [1, 2, 3, 4, 5]);
      expect(tanaka.transportLocations, ['北海道帯広市西11条南20丁目']);
      expect(tanaka.notes, '車椅子使用');
    });

    test('受給者証期限アラート: 期限 < 今日 → expired、残り < 30日 → expiringSoon', () {
      // 期限判定は実行日依存のため、ロジックを日付で直接検証
      final today = DateTime.now();
      for (final row in preview.rows) {
        final c = row.customer!;
        final exp = c.recipientCertExpiry!;
        final days = DateTime(exp.year, exp.month, exp.day)
            .difference(DateTime(today.year, today.month, today.day))
            .inDays;
        if (days < 0) {
          expect(row.certAlert, CertAlertKind.expired, reason: c.name);
        } else if (days < kCertExpiryAlertDays) {
          expect(row.certAlert, CertAlertKind.expiringSoon, reason: c.name);
        } else {
          expect(row.certAlert, isNull, reason: c.name);
        }
      }
      // 正本の説明どおり: 田中健太(2026/06/23)・山田太郎(2026/06/30) は
      // 2026/07/01 以降は必ず expired
      final tanaka = preview.rows[2].customer!;
      final yamada = preview.rows[0].customer!;
      expect(tanaka.recipientCertExpiry, DateTime(2026, 6, 23));
      expect(yamada.recipientCertExpiry, DateTime(2026, 6, 30));
      if (today.isAfter(DateTime(2026, 6, 30))) {
        expect(preview.rows[2].certAlert, CertAlertKind.expired);
        expect(preview.rows[0].certAlert, CertAlertKind.expired);
      }
    });

    test('execute: 10件取り込み → Hive に永続化、重複なし', () async {
      final result = await svc.execute(preview,
          resolveDuplicate: (_) async => DuplicateAction.skip);
      expect(result.imported, 10);
      expect(result.overwritten, 0);
      expect(result.skipped, 0);
      expect(result.errorCount, 0);
      expect(result.aborted, isFalse);
      final all = CustomerService.instance.getAllCustomers();
      expect(all.length, 10);
      expect(all.map((c) => c.name), contains('加藤 ひかり'));
    });
  });

  // ── CSV ─────────────────────────────────────────────────────

  group('csv', () {
    setUp(clearBox);

    test('UTF-8 BOM', () {
      final bytes = File('test/fixtures/sample_utf8_bom.csv').readAsBytesSync();
      final p = svc.parse(fileName: 'sample.csv', bytes: bytes, existingCustomers: const []);
      expect(p.fileType, ImportFileType.csv);
      expect(p.encoding, ImportEncoding.utf8Bom);
      expect(p.headers, kCustomerImportHeaders);
      expect(p.validRows, 10);
      expect(p.rows.first.customer!.name, '山田 太郎');
      expect(p.rows.first.customer!.birthday, DateTime(2015, 4, 12));
      expect(p.rows.first.customer!.regularDays, [1, 3, 5]);
      expect(p.rows.first.customer!.recipientCertNumber, '1234567890');
    });

    test('Shift_JIS', () {
      final bytes = File('test/fixtures/sample_sjis.csv').readAsBytesSync();
      final p = svc.parse(fileName: 'sample_sjis.csv', bytes: bytes, existingCustomers: const []);
      expect(p.encoding, ImportEncoding.shiftJis);
      expect(p.headers, kCustomerImportHeaders);
      expect(p.validRows, 10);
      expect(p.rows[9].customer!.name, '加藤 ひかり');
      expect(p.rows[9].customer!.notes, '好物：唐揚げ');
      expect(p.rows[9].customer!.regularDays, [1, 3, 4, 5, 6]);
    });

    test('列数が少ない CSV・氏名空行はエラーとして継続', () {
      const csv = '氏名,ふりがな,生年月日,性別\r\n'
          'テスト 一郎,てすと いちろう,2016/01/01,男\r\n'
          ',,2016/01/01,女\r\n'
          'テスト 花子,,2017/02/02,F\r\n';
      final bytes = utf8Bytes(csv);
      final p = svc.parse(fileName: 'short.csv', bytes: bytes, existingCustomers: const []);
      expect(p.totalRows, 3);
      expect(p.validRows, 2);
      expect(p.errorRows, 1);
      expect(p.rows[1].errors, contains('氏名が空です'));
      expect(p.rows[0].customer!.nameKana, 'テスト イチロウ');
      expect(p.rows[0].customer!.gender, '男児');
      expect(p.rows[2].customer!.gender, '女児');
      expect(p.rows[2].warnings, contains('ふりがなが空のため氏名で補完しました'));
      expect(p.headerWarnings.length, 12); // 16 - 4
    });
  });

  // ── 重複判定 ────────────────────────────────────────────────

  group('duplicates', () {
    setUp(clearBox);

    test('優先順: 受給者証番号 > 氏名+生年月日 > 氏名のみ', () {
      final existing = [
        Customer(id: 'id-cert', name: '別名 太郎', nameKana: 'ベツメイ タロウ',
            recipientCertNumber: '1234567890'),
        Customer(id: 'id-nb', name: '鈴木 花子', nameKana: 'スズキ ハナコ',
            birthday: DateTime(2014, 7, 23)),
        Customer(id: 'id-name', name: '田中 健太', nameKana: 'タナカ ケンタ',
            birthday: DateTime(2000, 1, 1)),
      ];
      final bytes = File('test/fixtures/linkday_customer_sample.xlsx').readAsBytesSync();
      final p = svc.parse(fileName: 's.xlsx', bytes: bytes, existingCustomers: existing);
      expect(p.duplicateRows, 3);
      expect(p.rows[0].duplicate!.kind, DuplicateMatchKind.certNumber);
      expect(p.rows[0].duplicate!.existing.id, 'id-cert');
      expect(p.rows[1].duplicate!.kind, DuplicateMatchKind.nameAndBirthday);
      expect(p.rows[1].duplicate!.existing.id, 'id-nb');
      expect(p.rows[2].duplicate!.kind, DuplicateMatchKind.nameOnly);
      expect(p.rows[2].duplicate!.existing.id, 'id-name');
      expect(p.rows[3].duplicate, isNull);
    });

    test('上書き時は既存 ID を維持 / スキップ / 中止 が選択どおり反映', () async {
      final existing = Customer(
        id: 'keep-this-id',
        name: '山田 太郎',
        nameKana: 'ヤマダ タロウ',
        recipientCertNumber: '1234567890',
        currentMonthUsedDays: 7,
        notes: '旧備考',
      );
      await CustomerService.instance.addCustomer(existing);
      await CustomerService.instance.addCustomer(Customer(
          id: 'suzuki-id', name: '鈴木 花子', nameKana: 'スズキ ハナコ',
          recipientCertNumber: '1234567891'));
      await CustomerService.instance.addCustomer(Customer(
          id: 'tanaka-id', name: '田中 健太', nameKana: 'タナカ ケンタ',
          recipientCertNumber: '1234567892'));

      final bytes = File('test/fixtures/linkday_customer_sample.xlsx').readAsBytesSync();
      final p = svc.parse(fileName: 's.xlsx', bytes: bytes);
      expect(p.duplicateRows, 3);

      // 山田=上書き, 鈴木=スキップ, 田中=中止（以降は全てスキップ）
      final r = await svc.execute(p, resolveDuplicate: (row) async {
        switch (row.customer!.name) {
          case '山田 太郎':
            return DuplicateAction.overwrite;
          case '鈴木 花子':
            return DuplicateAction.skip;
          default:
            return DuplicateAction.abort;
        }
      });
      expect(r.overwritten, 1);
      expect(r.aborted, isTrue);
      expect(r.imported, 0); // 中止前に非重複行はなかった（行1〜3が先頭）
      expect(r.skipped, 9); // 鈴木 + 田中(中止) + 残り7件

      final yamada = CustomerService.instance.getCustomerById('keep-this-id');
      expect(yamada, isNotNull);
      expect(yamada!.notes, 'アレルギー：そば'); // 上書きされた
      expect(yamada.currentMonthUsedDays, 7); // 当月利用日数は維持
      expect(yamada.regularDays, [1, 3, 5]);
      expect(CustomerService.instance.getAllCustomers().length, 3);
    });

    // ── Day 10 回帰: 上書きインポートで Day 8 座標が消えない ──────
    //
    // 旧実装は merged Customer に transportLocationLats/Lngs/Status を
    // 渡しておらず、上書きインポートで解決済み座標が全消失していた。
    test('Day 10 回帰: 上書きインポートで解決済み座標（resolved/manual）が保持される',
        () async {
      // 山田は fixture 上 ['北海道帯広市東1条南3丁目', '帯広駅前'] の2件
      final existing = Customer(
        id: 'keep-coords',
        name: '山田 太郎',
        nameKana: 'ヤマダ タロウ',
        recipientCertNumber: '1234567890',
        transportLocations: ['北海道帯広市東1条南3丁目', '帯広駅前'],
      );
      // 送迎場所0 = 自動採用、送迎場所1 = 手動確定
      existing.setTransportCoord(0, 42.9231, 143.1960, Customer.locResolved,
          formatted: '日本、北海道帯広市東1条南3丁目', types: ['premise']);
      existing.setTransportCoord(1, 42.9178, 143.2010, Customer.locManual);
      await CustomerService.instance.addCustomer(existing);

      final bytes =
          File('test/fixtures/linkday_customer_sample.xlsx').readAsBytesSync();
      final p = svc.parse(fileName: 's.xlsx', bytes: bytes);
      await svc.execute(p, resolveDuplicate: (row) async =>
          row.customer!.name == '山田 太郎'
              ? DuplicateAction.overwrite
              : DuplicateAction.skip);

      final after = CustomerService.instance.getCustomerById('keep-coords');
      expect(after, isNotNull);
      // 住所が一致する送迎場所の座標・status・根拠が引き継がれている
      expect(after!.isTransportResolved(0), isTrue,
          reason: '送迎場所1の解決済み座標が消えている（退行）');
      expect(after.transportCoord(0)!.lat, closeTo(42.9231, 1e-6));
      expect(after.transportCoord(0)!.lng, closeTo(143.1960, 1e-6));
      expect(after.transportStatus(0), Customer.locResolved);
      expect(after.transportFormatted(0), '日本、北海道帯広市東1条南3丁目');
      expect(after.transportTypes(0), ['premise']);

      expect(after.isTransportResolved(1), isTrue,
          reason: '手動確定（manual）座標が消えている（退行）');
      expect(after.transportStatus(1), Customer.locManual);
      expect(after.transportCoord(1)!.lat, closeTo(42.9178, 1e-6));
    });

    test('Day 10 回帰: 住所が変わった送迎場所は未解決に戻る（古い座標を使い回さない）',
        () async {
      final existing = Customer(
        id: 'addr-changed',
        name: '山田 太郎',
        nameKana: 'ヤマダ タロウ',
        recipientCertNumber: '1234567890',
        // fixture とは異なる住所に座標が付いている状態
        transportLocations: ['北海道帯広市西99条南99丁目'],
      );
      existing.setTransportCoord(0, 42.1111, 143.1111, Customer.locResolved);
      await CustomerService.instance.addCustomer(existing);

      final bytes =
          File('test/fixtures/linkday_customer_sample.xlsx').readAsBytesSync();
      final p = svc.parse(fileName: 's.xlsx', bytes: bytes);
      await svc.execute(p, resolveDuplicate: (row) async =>
          row.customer!.name == '山田 太郎'
              ? DuplicateAction.overwrite
              : DuplicateAction.skip);

      final after = CustomerService.instance.getCustomerById('addr-changed');
      expect(after, isNotNull);
      // 新住所には古い座標を引き継がない
      expect(after!.transportLocations, ['北海道帯広市東1条南3丁目', '帯広駅前']);
      expect(after.isTransportResolved(0), isFalse);
      expect(after.transportStatus(0), Customer.locUnresolved);
      expect(after.transportCoord(0), isNull);
    });

    test('null（ダイアログ閉じ）は既定でスキップ', () async {
      await CustomerService.instance.addCustomer(Customer(
          id: 'x', name: '山田 太郎', nameKana: 'ヤマダ タロウ',
          recipientCertNumber: '1234567890'));
      final bytes = File('test/fixtures/linkday_customer_sample.xlsx').readAsBytesSync();
      final p = svc.parse(fileName: 's.xlsx', bytes: bytes);
      final r = await svc.execute(p, resolveDuplicate: (_) async => null);
      expect(r.skipped, 1);
      expect(r.imported, 9);
    });
  });

  // ── テンプレート / エクスポート往復 ──────────────────────────

  group('export', () {
    setUp(clearBox);

    test('テンプレート xlsx は正本と同じ構造で再取り込み可能', () {
      final bytes = CustomerExportService.instance.buildTemplateXlsx();
      final p = svc.parse(fileName: 't.xlsx', bytes: bytes, existingCustomers: const []);
      expect(p.headers, kCustomerImportHeaders);
      expect(p.validRows, 10);
      expect(p.rows[0].customer!.recipientCertExpiry, DateTime(2026, 6, 30));
      expect(p.rows[0].customer!.regularDays, [1, 3, 5]);
    });

    test('テンプレート csv (UTF-8 BOM) 再取り込み', () {
      final bytes = CustomerExportService.instance.buildTemplateCsv();
      expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      final p = svc.parse(fileName: 't.csv', bytes: bytes, existingCustomers: const []);
      expect(p.encoding, ImportEncoding.utf8Bom);
      expect(p.validRows, 10);
    });

    test('登録中データのエクスポート → 再取り込みで全フィールド一致', () async {
      final src = Customer(
        name: '往復 太郎', nameKana: 'オウフク タロウ', birthday: DateTime(2015, 1, 2),
        gender: '男児', phone: '0155-00-0000', guardianName: '往復 父',
        guardianPhone: '090-0000-0000', lineUserId: 'U${'b' * 32}',
        recipientCertNumber: '0000000001', recipientCertExpiry: DateTime(2030, 12, 31),
        monthlyAvailableDays: 21, regularDays: [2, 4], transportLocations: ['A', 'B', 'C'],
        notes: 'メモ',
      );
      final bytes = CustomerExportService.instance.exportCustomersXlsx([src]);
      final p = svc.parse(fileName: 'e.xlsx', bytes: bytes, existingCustomers: const []);
      final c = p.rows.single.customer!;
      expect(c.name, src.name);
      expect(c.nameKana, src.nameKana);
      expect(c.birthday, src.birthday);
      expect(c.gender, src.gender);
      expect(c.phone, src.phone);
      expect(c.guardianName, src.guardianName);
      expect(c.guardianPhone, src.guardianPhone);
      expect(c.lineUserId, src.lineUserId);
      expect(c.recipientCertNumber, src.recipientCertNumber);
      expect(c.recipientCertExpiry, src.recipientCertExpiry);
      expect(c.monthlyAvailableDays, 21);
      expect(c.regularDays, [2, 4]);
      expect(c.transportLocations, ['A', 'B', 'C']);
      expect(c.notes, 'メモ');
    });
  });
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
