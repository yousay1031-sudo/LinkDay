import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';

import '../models/customer.dart';
import '../utils/kana_util.dart';
import 'customer_service.dart';

// ════════════════════════════════════════════════════════════════
// 顧客インポート仕様（正本: linkday_customer_sample.xlsx「顧客マスタ」A1:P11）
//
//  #  ヘッダー        → Customer フィールド
//  1  氏名            → name                (必須)
//  2  ふりがな        → nameKana            (任意: 空なら氏名で補完・カナ正規化)
//  3  生年月日        → birthday
//  4  性別            → gender ('男児'/'女児' に正規化)
//  5  電話番号        → phone
//  6  保護者氏名      → guardianName
//  7  保護者電話      → guardianPhone
//  8  LINE_ID         → lineUserId
//  9  受給者証番号    → recipientCertNumber (文字列のまま)
// 10  受給者証期限    → recipientCertExpiry
// 11  月間支給量      → monthlyAvailableDays (int, 既定 23)
// 12  定期利用曜日    → regularDays (List<int> 月=1..日=7)
// 13  送迎場所1       → transportLocations[0]
// 14  送迎場所2       → transportLocations[1]
// 15  送迎場所3       → transportLocations[2]
// 16  備考            → notes
// ════════════════════════════════════════════════════════════════

/// 正本ヘッダー（16列・順序固定）
const List<String> kCustomerImportHeaders = [
  '氏名',
  'ふりがな',
  '生年月日',
  '性別',
  '電話番号',
  '保護者氏名',
  '保護者電話',
  'LINE_ID',
  '受給者証番号',
  '受給者証期限',
  '月間支給量',
  '定期利用曜日',
  '送迎場所1',
  '送迎場所2',
  '送迎場所3',
  '備考',
];

/// Excel 側のシート名（これのみ解釈する）
const String kCustomerMasterSheetName = '顧客マスタ';

/// 受給者証期限アラート閾値（日）
const int kCertExpiryAlertDays = 30;

// ────────────────────────────────────────────────────────────────
// 列挙・結果モデル
// ────────────────────────────────────────────────────────────────

enum ImportFileType { xlsx, csv }

enum ImportEncoding { none, utf8Bom, utf8, shiftJis }

extension ImportEncodingLabel on ImportEncoding {
  String get label => switch (this) {
        ImportEncoding.none => '—',
        ImportEncoding.utf8Bom => 'UTF-8 (BOM)',
        ImportEncoding.utf8 => 'UTF-8',
        ImportEncoding.shiftJis => 'Shift_JIS',
      };
}

/// 重複判定キー種別
enum DuplicateMatchKind { certNumber, nameAndBirthday, nameOnly }

extension DuplicateMatchKindLabel on DuplicateMatchKind {
  String get label => switch (this) {
        DuplicateMatchKind.certNumber => '受給者証番号一致',
        DuplicateMatchKind.nameAndBirthday => '氏名+生年月日一致',
        DuplicateMatchKind.nameOnly => '氏名のみ一致',
      };
}

/// 重複候補
class DuplicateCandidate {
  final Customer existing;
  final DuplicateMatchKind kind;
  const DuplicateCandidate({required this.existing, required this.kind});
}

/// 受給者証期限アラート種別
enum CertAlertKind { expired, expiringSoon }

/// 解析済み 1 行
class ParsedCustomerRow {
  /// ファイル上の行番号（1 始まり・ヘッダーが 1 行目）
  final int rowNumber;

  /// 元のセル文字列（プレビュー表示用・16 列）
  final List<String> rawCells;

  /// 解析結果（必須エラー時は null）
  final Customer? customer;

  /// 行を取り込めない致命的エラー
  final List<String> errors;

  /// 取り込めるが注意が必要な警告
  final List<String> warnings;

  /// 重複候補（最優先キーのみ）
  final DuplicateCandidate? duplicate;

  const ParsedCustomerRow({
    required this.rowNumber,
    required this.rawCells,
    required this.customer,
    required this.errors,
    required this.warnings,
    this.duplicate,
  });

  bool get isValid => customer != null && errors.isEmpty;
  bool get hasDuplicate => duplicate != null;

  CertAlertKind? get certAlert {
    final c = customer;
    if (c == null) return null;
    final days = c.certExpiryDaysLeft;
    if (days == null) return null;
    if (days < 0) return CertAlertKind.expired;
    if (days < kCertExpiryAlertDays) return CertAlertKind.expiringSoon;
    return null;
  }

  ParsedCustomerRow withDuplicate(DuplicateCandidate? d) => ParsedCustomerRow(
        rowNumber: rowNumber,
        rawCells: rawCells,
        customer: customer,
        errors: errors,
        warnings: warnings,
        duplicate: d,
      );
}

/// ファイル解析結果（プレビュー用）
class ImportPreview {
  final String fileName;
  final ImportFileType fileType;
  final ImportEncoding encoding;
  final List<String> headers;
  final List<ParsedCustomerRow> rows;

  /// ヘッダーが正本と一致しない列（警告表示用）
  final List<String> headerWarnings;

  const ImportPreview({
    required this.fileName,
    required this.fileType,
    required this.encoding,
    required this.headers,
    required this.rows,
    required this.headerWarnings,
  });

  int get totalRows => rows.length;
  int get validRows => rows.where((r) => r.isValid).length;
  int get errorRows => rows.where((r) => !r.isValid).length;
  int get duplicateRows => rows.where((r) => r.isValid && r.hasDuplicate).length;
  int get expiredCount =>
      rows.where((r) => r.certAlert == CertAlertKind.expired).length;
  int get expiringSoonCount =>
      rows.where((r) => r.certAlert == CertAlertKind.expiringSoon).length;
}

/// 重複時の処理
enum DuplicateAction { overwrite, skip, abort }

/// 取り込み実行結果
class CustomerImportResult {
  final int imported;
  final int overwritten;
  final int skipped;
  final int errorCount;
  final bool aborted;

  /// (行番号, 理由)
  final List<(int, String)> errors;

  /// 受給者証期限アラート（取り込み・上書きした行のみ）
  final List<(ParsedCustomerRow, CertAlertKind)> certAlerts;

  const CustomerImportResult({
    required this.imported,
    required this.overwritten,
    required this.skipped,
    required this.errorCount,
    required this.aborted,
    required this.errors,
    required this.certAlerts,
  });
}

// ────────────────────────────────────────────────────────────────
// サービス本体
// ────────────────────────────────────────────────────────────────

class CustomerImportService {
  CustomerImportService._();
  static final CustomerImportService instance = CustomerImportService._();

  // ── 公開 API ─────────────────────────────────────────────────

  /// ファイルバイト列を解析してプレビューを生成する（拡張子で自動分岐）
  ImportPreview parse({
    required String fileName,
    required Uint8List bytes,
    List<Customer>? existingCustomers,
  }) {
    final lower = fileName.toLowerCase();
    final existing = existingCustomers ??
        CustomerService.instance.getAllCustomers(includeInactive: true);

    if (lower.endsWith('.xlsx') || lower.endsWith('.xlsm')) {
      final table = _readXlsx(bytes);
      return _buildPreview(
        fileName: fileName,
        fileType: ImportFileType.xlsx,
        encoding: ImportEncoding.none,
        table: table,
        existing: existing,
      );
    }
    if (lower.endsWith('.csv') || lower.endsWith('.txt')) {
      final (table, enc) = _readCsv(bytes);
      return _buildPreview(
        fileName: fileName,
        fileType: ImportFileType.csv,
        encoding: enc,
        table: table,
        existing: existing,
      );
    }
    throw FormatException('対応していないファイル形式です: $fileName（.xlsx / .csv のみ）');
  }

  /// 取り込み実行
  ///
  /// [resolveDuplicate] は重複行ごとに呼ばれ、ユーザーの選択を返す。
  /// null を返した場合はスキップ扱い（既定値 = 誤上書き防止）。
  Future<CustomerImportResult> execute(
    ImportPreview preview, {
    required Future<DuplicateAction?> Function(ParsedCustomerRow row) resolveDuplicate,
  }) async {
    int imported = 0, overwritten = 0, skipped = 0, errorCount = 0;
    bool aborted = false;
    final errors = <(int, String)>[];
    final alerts = <(ParsedCustomerRow, CertAlertKind)>[];

    for (final row in preview.rows) {
      if (aborted) {
        skipped++;
        continue;
      }
      final c = row.customer;
      if (c == null || row.errors.isNotEmpty) {
        errorCount++;
        for (final e in row.errors) {
          errors.add((row.rowNumber, e));
        }
        continue;
      }

      try {
        final dup = row.duplicate;
        if (dup != null) {
          final action = await resolveDuplicate(row) ?? DuplicateAction.skip;
          switch (action) {
            case DuplicateAction.abort:
              aborted = true;
              skipped++;
              continue;
            case DuplicateAction.skip:
              skipped++;
              debugPrint('[CustomerImport] row ${row.rowNumber} skipped '
                  '(dup ${dup.kind.label}: ${dup.existing.name})');
              continue;
            case DuplicateAction.overwrite:
              // 既存 ID を維持して上書き。createdAt / currentMonthUsedDays / isActive は既存を保持。
              //
              // Day 10 Fix: Day 8 で解決済みの送迎場所座標を保持する。
              // 以前は transportLocationLats/Lngs/Status を引き継がず、
              // 上書きインポートで解決済み座標が全消失していた（致命）。
              // 住所文字列が一致する送迎場所のみ座標を引き継ぐ
              // （住所が変わった場合は再ジオコーディングが必要なため未解決に戻す）。
              final carried = _carryOverTransportCoords(
                existing: dup.existing,
                incoming: c,
              );
              final merged = Customer(
                id: dup.existing.id,
                name: c.name,
                nameKana: c.nameKana,
                birthday: c.birthday,
                gender: c.gender,
                phone: c.phone,
                lineUserId: c.lineUserId,
                guardianName: c.guardianName,
                guardianPhone: c.guardianPhone,
                recipientCertNumber: c.recipientCertNumber,
                recipientCertExpiry: c.recipientCertExpiry,
                monthlyAvailableDays: c.monthlyAvailableDays,
                currentMonthUsedDays: dup.existing.currentMonthUsedDays,
                regularDays: List<int>.from(c.regularDays),
                transportLocations: List<String>.from(c.transportLocations),
                notes: c.notes,
                createdAt: dup.existing.createdAt,
                updatedAt: DateTime.now(),
                isActive: true,
                transportLocationLats: carried.lats,
                transportLocationLngs: carried.lngs,
                transportLocationStatus: carried.status,
                transportLocationFormatted: carried.formatted,
                transportLocationTypes: carried.types,
              );
              await CustomerService.instance.updateCustomer(merged);
              overwritten++;
              debugPrint('[CustomerImport] row ${row.rowNumber} overwritten '
                  '(id=${merged.id}, ${dup.kind.label})');
          }
        } else {
          await CustomerService.instance.addCustomer(c);
          imported++;
        }
        final alert = row.certAlert;
        if (alert != null) alerts.add((row, alert));
      } catch (e) {
        errorCount++;
        errors.add((row.rowNumber, '保存エラー: $e'));
      }
    }

    debugPrint('[CustomerImport] done: imported=$imported, overwritten=$overwritten, '
        'skipped=$skipped, errors=$errorCount, aborted=$aborted');
    return CustomerImportResult(
      imported: imported,
      overwritten: overwritten,
      skipped: skipped,
      errorCount: errorCount,
      aborted: aborted,
      errors: errors,
      certAlerts: alerts,
    );
  }

  // ── 読み込み: XLSX ───────────────────────────────────────────

  /// 「顧客マスタ」シートのみ解釈。無ければ先頭シート。
  List<List<Object?>> _readXlsx(Uint8List bytes) {
    final excel = Excel.decodeBytes(bytes);
    Sheet? sheet = excel.sheets[kCustomerMasterSheetName];
    if (sheet == null) {
      // 絵文字付き等の揺れを許容: 「顧客マスタ」を含むシート名
      for (final name in excel.sheets.keys) {
        if (name.contains('顧客マスタ')) {
          sheet = excel.sheets[name];
          break;
        }
      }
    }
    sheet ??= excel.sheets.values.isNotEmpty ? excel.sheets.values.first : null;
    if (sheet == null) {
      throw const FormatException('シートが見つかりません');
    }
    debugPrint('[CustomerImport] xlsx sheet="${sheet.sheetName}", '
        'rows=${sheet.maxRows}, cols=${sheet.maxColumns}');

    final table = <List<Object?>>[];
    for (final row in sheet.rows) {
      table.add(row.map<Object?>((cell) => _cellToObject(cell?.value)).toList());
    }
    return table;
  }

  /// excel 4.x の CellValue → Dart 値（DateTime / num / String / null）
  Object? _cellToObject(CellValue? v) {
    if (v == null) return null;
    return switch (v) {
      TextCellValue() => v.value.text ?? v.toString(),
      IntCellValue() => v.value,
      DoubleCellValue() => v.value,
      DateCellValue() => v.asDateTimeLocal(),
      DateTimeCellValue() => v.asDateTimeLocal(),
      TimeCellValue() => v.toString(),
      BoolCellValue() => v.value,
      FormulaCellValue() => v.formula,
    };
  }

  // ── 読み込み: CSV ────────────────────────────────────────────

  /// UTF-8 BOM / UTF-8 / Shift_JIS を自動判定して CSV を読む
  (List<List<Object?>>, ImportEncoding) _readCsv(Uint8List bytes) {
    final (text, enc) = decodeTextAuto(bytes);
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rows = const CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
    ).convert(normalized);
    final table = rows
        .map<List<Object?>>((r) => r.map<Object?>((c) => c).toList())
        .where((r) => r.any((c) => (c?.toString().trim().isNotEmpty ?? false)))
        .toList();
    debugPrint('[CustomerImport] csv encoding=${enc.label}, rows=${table.length}');
    return (table, enc);
  }

  /// 文字コード自動判定デコード（公開: テスト・他機能用）
  static (String, ImportEncoding) decodeTextAuto(Uint8List bytes) {
    // 1) UTF-8 BOM
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return (utf8.decode(bytes.sublist(3)), ImportEncoding.utf8Bom);
    }
    // 2) 厳密 UTF-8
    try {
      return (utf8.decode(bytes, allowMalformed: false), ImportEncoding.utf8);
    } on FormatException {
      // fallthrough
    }
    // 3) Shift_JIS (CP932)
    try {
      return (shiftJis.decode(bytes), ImportEncoding.shiftJis);
    } catch (_) {
      // 4) 最後の手段: 寛容な UTF-8
      return (utf8.decode(bytes, allowMalformed: true), ImportEncoding.utf8);
    }
  }

  // ── プレビュー構築 ───────────────────────────────────────────

  ImportPreview _buildPreview({
    required String fileName,
    required ImportFileType fileType,
    required ImportEncoding encoding,
    required List<List<Object?>> table,
    required List<Customer> existing,
  }) {
    if (table.isEmpty) {
      throw const FormatException('ファイルにデータがありません');
    }

    final headerRow = table.first.map((c) => _str(c) ?? '').toList();
    final colIndex = _resolveColumns(headerRow);
    final headerWarnings = <String>[];
    for (int i = 0; i < kCustomerImportHeaders.length; i++) {
      if (!colIndex.containsKey(i)) {
        headerWarnings.add('列「${kCustomerImportHeaders[i]}」がヘッダーに見つかりません');
      }
    }

    final rows = <ParsedCustomerRow>[];
    for (int r = 1; r < table.length; r++) {
      final raw = table[r];
      // 完全空行はスキップ
      if (raw.every((c) => (_str(c) ?? '').isEmpty)) continue;
      rows.add(_parseRow(rowNumber: r + 1, raw: raw, colIndex: colIndex));
    }

    // 重複判定（既存 + ファイル内の先行行）
    final withDup = _attachDuplicates(rows, existing);

    return ImportPreview(
      fileName: fileName,
      fileType: fileType,
      encoding: encoding,
      headers: headerRow,
      rows: withDup,
      headerWarnings: headerWarnings,
    );
  }

  /// ヘッダー行から「正本列番号 → 実ファイル列番号」を解決
  /// ヘッダーが読めない場合は位置ベース（0..15）にフォールバック
  Map<int, int> _resolveColumns(List<String> headerRow) {
    final map = <int, int>{};
    String norm(String s) => s
        .replaceAll(RegExp(r'[\s　]+'), '')
        .replaceAll('＿', '_')
        .replaceAll('ＩＤ', 'ID')
        .toUpperCase();

    final aliases = <int, List<String>>{
      0: ['氏名', '名前', '児童名', '利用者名'],
      1: ['ふりがな', 'フリガナ', 'よみ', 'ヨミ', 'カナ'],
      2: ['生年月日', '誕生日'],
      3: ['性別'],
      4: ['電話番号', '電話', 'TEL'],
      5: ['保護者氏名', '保護者名', '保護者'],
      6: ['保護者電話', '保護者電話番号', '保護者TEL', '緊急連絡先'],
      7: ['LINE_ID', 'LINEID', 'LINE'],
      8: ['受給者証番号', '受給者証'],
      9: ['受給者証期限', '受給者証有効期限', '有効期限', '期限'],
      10: ['月間支給量', '支給量', '支給日数'],
      11: ['定期利用曜日', '利用曜日', '曜日'],
      12: ['送迎場所1', '送迎場所１', '送迎場所', '住所'],
      13: ['送迎場所2', '送迎場所２'],
      14: ['送迎場所3', '送迎場所３'],
      15: ['備考', 'メモ', '注意事項'],
    };

    final normHeaders = headerRow.map(norm).toList();
    for (final entry in aliases.entries) {
      for (final alias in entry.value) {
        final idx = normHeaders.indexOf(norm(alias));
        if (idx >= 0 && !map.containsValue(idx)) {
          map[entry.key] = idx;
          break;
        }
      }
    }
    // ヘッダーがほぼ一致しない → 位置ベース
    if (map.length < 3) {
      map.clear();
      for (int i = 0; i < kCustomerImportHeaders.length && i < headerRow.length; i++) {
        map[i] = i;
      }
      debugPrint('[CustomerImport] header mismatch → positional mapping');
    }
    return map;
  }

  // ── 行解析 ───────────────────────────────────────────────────

  ParsedCustomerRow _parseRow({
    required int rowNumber,
    required List<Object?> raw,
    required Map<int, int> colIndex,
  }) {
    final errors = <String>[];
    final warnings = <String>[];

    Object? cell(int logical) {
      final idx = colIndex[logical];
      if (idx == null || idx >= raw.length) return null;
      return raw[idx];
    }

    String? text(int logical) => _str(cell(logical));

    final rawCells = List<String>.generate(
      kCustomerImportHeaders.length,
      (i) => _displayStr(cell(i)),
    );

    // 1. 氏名（必須）
    final name = text(0);
    if (name == null || name.isEmpty) {
      errors.add('氏名が空です');
      return ParsedCustomerRow(
        rowNumber: rowNumber,
        rawCells: rawCells,
        customer: null,
        errors: errors,
        warnings: warnings,
      );
    }

    // 2. ふりがな（空なら氏名で補完・カナ正規化）
    var kana = text(1) ?? '';
    if (kana.isEmpty) {
      kana = name;
      warnings.add('ふりがなが空のため氏名で補完しました');
    }
    kana = KanaUtil.normalizeKana(kana);

    // 3. 生年月日
    final birthday = parseDate(cell(2));
    if (birthday == null && (text(2)?.isNotEmpty ?? false)) {
      warnings.add('生年月日「${text(2)}」を解釈できません');
    }

    // 4. 性別
    final gender = normalizeGender(text(3));
    if (gender == null && (text(3)?.isNotEmpty ?? false)) {
      warnings.add('性別「${text(3)}」を解釈できません');
    }

    // 5-7. 電話・保護者
    final phone = text(4);
    final guardianName = text(5);
    final guardianPhone = text(6);
    if ((guardianName ?? '').isEmpty && (guardianPhone ?? '').isEmpty) {
      warnings.add('保護者氏名・保護者電話がどちらも空です');
    }

    // 8. LINE_ID（形式は警告のみ）
    final lineId = text(7);
    if (lineId != null && lineId.isNotEmpty && !isValidLineUserId(lineId)) {
      warnings.add('LINE_ID の形式が標準（U + 32桁英数字）と異なります');
    }

    // 9. 受給者証番号（文字列のまま。数値セルの "1234567890.0" を補正）
    final certNumber = normalizeCertNumber(cell(8));
    if (certNumber != null && !RegExp(r'^\d{10}$').hasMatch(certNumber)) {
      warnings.add('受給者証番号が10桁数字ではありません');
    }

    // 10. 受給者証期限
    final certExpiry = parseDate(cell(9));
    if (certExpiry == null && (text(9)?.isNotEmpty ?? false)) {
      warnings.add('受給者証期限「${text(9)}」を解釈できません');
    }

    // 11. 月間支給量
    int monthly = 23;
    final monthlyRaw = cell(10);
    if (monthlyRaw != null && (_str(monthlyRaw) ?? '').isNotEmpty) {
      final parsed = parseInt(monthlyRaw);
      if (parsed == null) {
        warnings.add('月間支給量「${_str(monthlyRaw)}」を解釈できないため 23 を使用');
      } else {
        monthly = parsed;
      }
    }

    // 12. 定期利用曜日
    final regularDays = parseRegularDays(text(11));
    if (regularDays.isEmpty && (text(11)?.isNotEmpty ?? false)) {
      warnings.add('定期利用曜日「${text(11)}」を解釈できません');
    }

    // 13-15. 送迎場所（文字列のまま保存。geocode は Day 8）
    final locations = <String>[
      for (final i in [12, 13, 14])
        if ((text(i) ?? '').isNotEmpty) text(i)!,
    ];
    if (locations.isEmpty) {
      warnings.add('送迎場所1 が空です');
    }

    // 16. 備考
    final notes = text(15);

    final customer = Customer(
      name: name,
      nameKana: kana,
      birthday: birthday,
      gender: gender,
      phone: phone,
      lineUserId: lineId,
      guardianName: guardianName,
      guardianPhone: guardianPhone,
      recipientCertNumber: certNumber,
      recipientCertExpiry: certExpiry,
      monthlyAvailableDays: monthly,
      regularDays: regularDays,
      transportLocations: locations,
      notes: notes,
    );

    return ParsedCustomerRow(
      rowNumber: rowNumber,
      rawCells: rawCells,
      customer: customer,
      errors: errors,
      warnings: warnings,
    );
  }

  // ── 重複判定 ─────────────────────────────────────────────────

  List<ParsedCustomerRow> _attachDuplicates(
    List<ParsedCustomerRow> rows,
    List<Customer> existing,
  ) {
    final byCert = <String, Customer>{};
    final byNameBirthday = <String, Customer>{};
    final byName = <String, Customer>{};
    for (final c in existing) {
      final cert = c.recipientCertNumber;
      if (cert != null && cert.isNotEmpty) byCert.putIfAbsent(cert, () => c);
      final nb = _nameBirthdayKey(c.name, c.birthday);
      if (nb != null) byNameBirthday.putIfAbsent(nb, () => c);
      byName.putIfAbsent(_normName(c.name), () => c);
    }

    final result = <ParsedCustomerRow>[];
    for (final row in rows) {
      final c = row.customer;
      if (c == null) {
        result.add(row);
        continue;
      }
      DuplicateCandidate? dup;
      final cert = c.recipientCertNumber;
      if (cert != null && cert.isNotEmpty && byCert.containsKey(cert)) {
        dup = DuplicateCandidate(existing: byCert[cert]!, kind: DuplicateMatchKind.certNumber);
      } else {
        final nb = _nameBirthdayKey(c.name, c.birthday);
        if (nb != null && byNameBirthday.containsKey(nb)) {
          dup = DuplicateCandidate(
              existing: byNameBirthday[nb]!, kind: DuplicateMatchKind.nameAndBirthday);
        } else if (byName.containsKey(_normName(c.name))) {
          dup = DuplicateCandidate(
              existing: byName[_normName(c.name)]!, kind: DuplicateMatchKind.nameOnly);
          debugPrint('[CustomerImport] row ${row.rowNumber}: 氏名のみ一致 "${c.name}"');
        }
      }
      result.add(row.withDuplicate(dup));
    }
    return result;
  }

  static String _normName(String s) => s.replaceAll(RegExp(r'[\s　]+'), '');

  // ── Day 10 Fix: 上書きインポート時の座標引き継ぎ ──────────────────
  //
  // Day 8 で解決した送迎場所座標（resolved / manual）は、
  // 上書きインポートで失われてはならない（再ジオコーディングは
  // API コストと誤採用リスクを伴うため）。
  //
  // 引き継ぎ条件: 送迎場所の住所文字列が正規化後に一致すること。
  //   - 一致     → 既存の lat/lng/status/formatted/types をそのまま引き継ぐ
  //   - 不一致   → 住所が変わったので未解決（unresolved）にする
  //
  // 既存側の住所リストに対して「同じ住所を探す」方式のため、
  // 送迎場所1〜3 の並び順が変わっても座標は正しく追従する。
  static ({
    List<double?> lats,
    List<double?> lngs,
    List<String> status,
    List<String?> formatted,
    List<String?> types,
  }) _carryOverTransportCoords({
    required Customer existing,
    required Customer incoming,
  }) {
    String normAddr(String s) =>
        s.replaceAll(RegExp(r'[\s　]+'), '').trim().toLowerCase();

    // 既存の「住所 → 解決情報」インデックス（解決済みのみ対象）
    final byAddr = <String, ({
      double? lat,
      double? lng,
      String status,
      String? formatted,
      String? types,
    })>{};
    for (int i = 0; i < existing.transportLocations.length; i++) {
      final addr = normAddr(existing.transportLocations[i]);
      if (addr.isEmpty) continue;
      if (!existing.isTransportResolved(i)) continue; // 未解決は引き継がない
      byAddr.putIfAbsent(
        addr,
        () => (
          lat: existing.transportLocationLats[i],
          lng: existing.transportLocationLngs[i],
          status: existing.transportLocationStatus[i],
          formatted: existing.transportFormatted(i),
          types: (i < existing.transportLocationTypes.length)
              ? existing.transportLocationTypes[i]
              : null,
        ),
      );
    }

    final n = incoming.transportLocations.length;
    final lats = List<double?>.filled(n, null, growable: true);
    final lngs = List<double?>.filled(n, null, growable: true);
    final status =
        List<String>.filled(n, Customer.locUnresolved, growable: true);
    final formatted = List<String?>.filled(n, null, growable: true);
    final types = List<String?>.filled(n, null, growable: true);

    int carriedCount = 0;
    for (int i = 0; i < n; i++) {
      final addr = normAddr(incoming.transportLocations[i]);
      if (addr.isEmpty) continue;
      final hit = byAddr[addr];
      if (hit == null) continue;
      lats[i] = hit.lat;
      lngs[i] = hit.lng;
      status[i] = hit.status;
      formatted[i] = hit.formatted;
      types[i] = hit.types;
      carriedCount++;
    }

    if (carriedCount > 0) {
      debugPrint('[CustomerImport] 座標引き継ぎ: ${existing.name} '
          '$carriedCount/$n 件の解決済み座標を保持');
    }

    return (
      lats: lats,
      lngs: lngs,
      status: status,
      formatted: formatted,
      types: types,
    );
  }

  static String? _nameBirthdayKey(String name, DateTime? b) {
    if (b == null) return null;
    return '${_normName(name)}|${b.year}-${b.month}-${b.day}';
  }

  // ── 値パーサ（公開 static: テスト対象）────────────────────────

  static String? _str(Object? v) {
    if (v == null) return null;
    if (v is DateTime) {
      return '${v.year}/${v.month.toString().padLeft(2, '0')}/${v.day.toString().padLeft(2, '0')}';
    }
    if (v is double && v == v.roundToDouble()) return v.toInt().toString();
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  static String _displayStr(Object? v) => _str(v) ?? '';

  /// 日付パース: DateTime / Excel シリアル値 / "yyyy/mm/dd" / "yyyy-mm-dd" / "yyyy年m月d日" / "yyyymmdd"
  static DateTime? parseDate(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return DateTime(v.year, v.month, v.day);
    if (v is num) return _fromExcelSerial(v.toDouble());
    final s = v.toString().trim();
    if (s.isEmpty) return null;

    // 数値文字列（Excel シリアル or yyyymmdd）
    final asNum = double.tryParse(s);
    if (asNum != null) {
      if (s.length == 8 && !s.contains('.')) {
        final y = int.parse(s.substring(0, 4));
        final m = int.parse(s.substring(4, 6));
        final d = int.parse(s.substring(6, 8));
        if (m >= 1 && m <= 12 && d >= 1 && d <= 31) return DateTime(y, m, d);
      }
      return _fromExcelSerial(asNum);
    }

    final m = RegExp(r'^(\d{4})[/\-.年]\s*(\d{1,2})[/\-.月]\s*(\d{1,2})日?').firstMatch(s);
    if (m != null) {
      final y = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      final d = int.parse(m.group(3)!);
      if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) return DateTime(y, mo, d);
      return null;
    }
    try {
      final dt = DateTime.parse(s);
      return DateTime(dt.year, dt.month, dt.day);
    } catch (_) {
      return null;
    }
  }

  static DateTime? _fromExcelSerial(double serial) {
    // Excel 1900 日付系: 1899-12-30 起点
    if (serial < 1 || serial > 2958465) return null;
    final base = DateTime(1899, 12, 30);
    final dt = base.add(Duration(days: serial.floor()));
    return DateTime(dt.year, dt.month, dt.day);
  }

  static int? parseInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.round();
    final s = v.toString().trim().replaceAll(RegExp(r'[日,]'), '');
    final d = double.tryParse(s);
    return d?.round();
  }

  /// 性別の揺れを '男児' / '女児' に正規化
  static String? normalizeGender(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().toUpperCase();
    if (s.isEmpty) return null;
    const male = {'男児', '男', '男性', '男子', 'M', 'MALE', 'BOY', '♂'};
    const female = {'女児', '女', '女性', '女子', 'F', 'FEMALE', 'GIRL', '♀'};
    if (male.contains(s)) return '男児';
    if (female.contains(s)) return '女児';
    if (s.startsWith('男')) return '男児';
    if (s.startsWith('女')) return '女児';
    return null;
  }

  /// 受給者証番号: 文字列のまま。数値セル由来の ".0" や指数表記を補正。
  static String? normalizeCertNumber(Object? v) {
    if (v == null) return null;
    if (v is int) return v.toString();
    if (v is double) {
      if (v == v.roundToDouble()) return v.toInt().toString();
      return v.toString();
    }
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    final d = double.tryParse(s);
    if (d != null && s.contains(RegExp(r'[eE.]')) && d == d.roundToDouble()) {
      return d.toInt().toString();
    }
    return s;
  }

  /// LINE user id: 'U' + 32 桁の 16 進英数字（計 33 文字）
  static bool isValidLineUserId(String s) =>
      RegExp(r'^U[0-9a-fA-F]{32}$').hasMatch(s.trim());

  /// 定期利用曜日: 「月,水,金」「月、水、金」「月水金」「月曜・水曜」「Mon,Wed」等 → [1,3,5]
  static List<int> parseRegularDays(String? raw) {
    if (raw == null) return const [];
    var s = raw.trim();
    if (s.isEmpty) return const [];
    const dayMap = <String, int>{
      '月': 1, '火': 2, '水': 3, '木': 4, '金': 5, '土': 6, '日': 7,
    };
    const en = <String, int>{
      'MON': 1, 'TUE': 2, 'WED': 3, 'THU': 4, 'FRI': 5, 'SAT': 6, 'SUN': 7,
    };
    final result = <int>{};

    // 「曜日」「曜」を除去して 1 文字キーに揃える
    s = s.replaceAll('曜日', '').replaceAll('曜', '');

    // 区切りで分割（カンマ・読点・中黒・スペース・スラッシュ）
    final parts = s.split(RegExp(r'[,、・/／\s　]+')).where((p) => p.isNotEmpty);
    for (final p in parts) {
      final up = p.toUpperCase();
      if (en.containsKey(up.length >= 3 ? up.substring(0, 3) : up)) {
        result.add(en[up.substring(0, 3)]!);
        continue;
      }
      final n = int.tryParse(p);
      if (n != null && n >= 1 && n <= 7) {
        result.add(n);
        continue;
      }
      // 「月水金」のような連結表記 → 1 文字ずつ
      for (final ch in p.split('')) {
        final d = dayMap[ch];
        if (d != null) result.add(d);
      }
    }
    final list = result.toList()..sort();
    return list;
  }
}
