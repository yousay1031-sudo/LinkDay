import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';

import '../models/customer.dart';
import 'customer_import_service.dart';

/// 顧客テンプレート生成 / エクスポート
///
/// 生成物は linkday_customer_sample.xlsx と同じ構造:
///   - 「顧客マスタ」シート: 16 列ヘッダー + データ
///   - 「📋 使い方」シート: 項目説明
class CustomerExportService {
  CustomerExportService._();
  static final CustomerExportService instance = CustomerExportService._();

  // ── サンプルデータ（正本ファイル「顧客マスタ」A2:P11 と同一）────────

  static final List<List<Object?>> kSampleRows = [
    ['山田 太郎', 'ヤマダ タロウ', DateTime(2015, 4, 12), '男児', '0155-20-1234', '山田 健一', '090-1234-5678', 'U1234567890abcdef01', '1234567890', DateTime(2026, 6, 30), 23, '月,水,金', '北海道帯広市東1条南3丁目', '帯広駅前', null, 'アレルギー：そば'],
    ['鈴木 花子', 'すずき はなこ', DateTime(2014, 7, 23), '女児', '0155-21-2345', '鈴木 美咲', '090-2345-6789', 'U2234567890abcdef02', '1234567891', DateTime(2027, 3, 31), 23, '火,木', '北海道帯広市西4条南10丁目', '緑ヶ丘公園前', '西帯広駅', null],
    ['田中 健太', 'タナカ ケンタ', DateTime(2016, 1, 8), '男児', '0155-22-3456', '田中 美穂', '090-3456-7890', 'U3334567890abcdef03', '1234567892', DateTime(2026, 6, 23), 20, '月,火,水,木,金', '北海道帯広市西11条南20丁目', null, null, '車椅子使用'],
    ['佐藤 美咲', 'サトウ ミサキ', DateTime(2013, 11, 15), '女児', '0155-23-4567', '佐藤 太一', '090-4567-8901', 'U4434567890abcdef04', '1234567893', DateTime(2027, 8, 31), 23, '水,金,土', '北海道帯広市稲田町西2線', '帯広の森運動公園', null, '送迎時は保護者立ち会い希望'],
    ['伊藤 大輝', 'いとう だいき', DateTime(2017, 5, 30), '男児', '0155-24-5678', '伊藤 真理子', '090-5678-9012', 'U5534567890abcdef05', '1234567894', DateTime(2027, 12, 31), 15, '月,木', '北海道帯広市南町南8線', '南公園', null, null],
    ['高橋 結衣', 'タカハシ ユイ', DateTime(2014, 2, 19), '女児', '0155-25-6789', '高橋 浩二', '090-6789-0123', 'U6634567890abcdef06', '1234567895', DateTime(2026, 7, 10), 23, '火,水,金', '北海道帯広市清流南町1丁目', '清流公園', 'イオン帯広店', '薬の服用あり（昼食後）'],
    ['渡辺 翔', 'ワタナベ ショウ', DateTime(2015, 9, 5), '男児', '0155-26-7890', '渡辺 千尋', '090-7890-1234', 'U7734567890abcdef07', '1234567896', DateTime(2027, 6, 30), 23, '月,火,木,土', '北海道帯広市西16条北1丁目', '西16条北児童公園', null, null],
    ['中村 あおい', 'なかむら あおい', DateTime(2016, 12, 28), '女児', '0155-27-8901', '中村 大輔', '090-8901-2345', 'U8834567890abcdef08', '1234567897', DateTime(2027, 9, 15), 23, '月,水,金', '北海道帯広市東6条南11丁目', '藤丸百貨店前', null, '雨天時は屋根のある場所で待機'],
    ['小林 蓮', 'コバヤシ レン', DateTime(2014, 6, 11), '男児', '0155-28-9012', '小林 由紀', '090-9012-3456', 'U9934567890abcdef09', '1234567898', DateTime(2027, 11, 30), 18, '火,木', '北海道帯広市西22条南3丁目', '西帯広小学校前', null, null],
    ['加藤 ひかり', 'カトウ ヒカリ', DateTime(2015, 3, 22), '女児', '0155-29-0123', '加藤 拓也', '090-0123-4567', 'U0034567890abcdef10', '1234567899', DateTime(2026, 7, 30), 23, '月,水,木,金,土', '北海道帯広市春駒通南8丁目', '緑南中学校前', 'とかちプラザ', '好物：唐揚げ'],
  ];

  /// 「📋 使い方」シート内容（正本ファイルと同一）
  static const List<List<String?>> kGuideRows = [
    ['LinkDay 顧客一括登録用 サンプルデータ', null, null],
    [null, null, null],
    ['項目', '説明', '例'],
    ['氏名', '顧客（児童）の氏名（必須）', '山田 太郎'],
    ['ふりがな', '氏名のふりがな（カナ・ひらがなどちらでもOK）', 'ヤマダ タロウ / やまだ たろう'],
    ['生年月日', 'yyyy/mm/dd形式', '2015/04/12'],
    ['性別', '男児 / 女児', '男児'],
    ['電話番号', 'ハイフンあり', '0155-20-1234'],
    ['保護者氏名', '送迎連絡時の宛先', '山田 健一'],
    ['保護者電話', '携帯番号', '090-1234-5678'],
    ['LINE_ID', 'LINE通知用のユーザーID（U〜から始まる33文字）', 'U1234567890...'],
    ['受給者証番号', '10桁の数字', '1234567890'],
    ['受給者証期限', '有効期限。30日以内になるとアプリ内でアラート表示', '2027/03/31'],
    ['月間支給量', '1ヶ月の利用可能日数（通常23日）', '23'],
    ['定期利用曜日', 'カンマ区切り。月,火,水,木,金,土から選択', '月,水,金'],
    ['送迎場所1〜3', '迎え・送り場所。3箇所まで登録可', '北海道帯広市西4条南10丁目'],
    ['備考', 'アレルギー・配慮事項など', 'アレルギー：そば'],
    [null, null, null],
    ['【テストデータの特徴】', null, null],
    ['・ふりがな', '山田/田中などはカナ、鈴木/伊藤/中村などはひらがな（自動変換テスト用）', null],
    ['・受給者証期限', '山田・田中・高橋は30日以内（アラートテスト用）', null],
    ['・住所', '北海道帯広市内の実在エリア（ルート最適化テスト用）', null],
    ['・定期曜日', '週1日〜週5日まで多様（スケジュール表示テスト用）', null],
  ];

  // ── 公開 API ─────────────────────────────────────────────────

  /// サンプル付きテンプレート（xlsx）
  Uint8List buildTemplateXlsx({bool withSample = true}) =>
      _buildXlsx(withSample ? kSampleRows : const []);

  /// サンプル付きテンプレート（CSV, UTF-8 BOM）
  Uint8List buildTemplateCsv({bool withSample = true}) =>
      _buildCsv(withSample ? kSampleRows : const []);

  /// 登録中の利用者をエクスポート（xlsx）
  Uint8List exportCustomersXlsx(List<Customer> customers) =>
      _buildXlsx(customers.map(customerToRow).toList());

  /// 登録中の利用者をエクスポート（CSV, UTF-8 BOM）
  Uint8List exportCustomersCsv(List<Customer> customers) =>
      _buildCsv(customers.map(customerToRow).toList());

  /// Customer → 16 列
  static List<Object?> customerToRow(Customer c) {
    String? loc(int i) => i < c.transportLocations.length ? c.transportLocations[i] : null;
    const labels = {1: '月', 2: '火', 3: '水', 4: '木', 5: '金', 6: '土', 7: '日'};
    return [
      c.name,
      c.nameKana,
      c.birthday,
      c.gender,
      c.phone,
      c.guardianName,
      c.guardianPhone,
      c.lineUserId,
      c.recipientCertNumber,
      c.recipientCertExpiry,
      c.monthlyAvailableDays,
      c.regularDays.map((d) => labels[d] ?? '').where((s) => s.isNotEmpty).join(','),
      loc(0),
      loc(1),
      loc(2),
      c.notes,
    ];
  }

  // ── 内部: XLSX ───────────────────────────────────────────────

  Uint8List _buildXlsx(List<List<Object?>> dataRows) {
    final excel = Excel.createExcel();
    // 既定シート "Sheet1" を「顧客マスタ」にリネーム
    final defaultName = excel.getDefaultSheet();
    if (defaultName != null && defaultName != kCustomerMasterSheetName) {
      excel.rename(defaultName, kCustomerMasterSheetName);
    }
    final master = excel[kCustomerMasterSheetName];

    final headerStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#FFE0B2'),
      horizontalAlign: HorizontalAlign.Center,
    );
    for (int c = 0; c < kCustomerImportHeaders.length; c++) {
      final idx = CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0);
      master.updateCell(idx, TextCellValue(kCustomerImportHeaders[c]), cellStyle: headerStyle);
    }
    for (int r = 0; r < dataRows.length; r++) {
      final row = dataRows[r];
      for (int c = 0; c < kCustomerImportHeaders.length; c++) {
        final v = c < row.length ? row[c] : null;
        final idx = CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1);
        final cv = _toCellValue(v);
        if (cv != null) master.updateCell(idx, cv);
      }
    }
    // 列幅
    const widths = <double>[14, 16, 12, 6, 14, 14, 14, 24, 14, 12, 10, 16, 30, 20, 18, 28];
    for (int c = 0; c < widths.length; c++) {
      master.setColumnWidth(c, widths[c]);
    }

    // 使い方シート
    final guide = excel['📋 使い方'];
    for (int r = 0; r < kGuideRows.length; r++) {
      for (int c = 0; c < kGuideRows[r].length; c++) {
        final v = kGuideRows[r][c];
        if (v == null) continue;
        final idx = CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r);
        final isTitle = r == 0 || r == 2 || v.startsWith('【');
        guide.updateCell(idx, TextCellValue(v),
            cellStyle: isTitle ? CellStyle(bold: true) : null);
      }
    }
    guide.setColumnWidth(0, 16);
    guide.setColumnWidth(1, 52);
    guide.setColumnWidth(2, 30);

    final bytes = excel.encode();
    if (bytes == null) throw StateError('Excel エンコードに失敗しました');
    debugPrint('[CustomerExport] xlsx built: rows=${dataRows.length}, bytes=${bytes.length}');
    return Uint8List.fromList(bytes);
  }

  CellValue? _toCellValue(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return DateCellValue.fromDateTime(v);
    if (v is int) return IntCellValue(v);
    if (v is double) return DoubleCellValue(v);
    final s = v.toString();
    return s.isEmpty ? null : TextCellValue(s);
  }

  // ── 内部: CSV ────────────────────────────────────────────────

  Uint8List _buildCsv(List<List<Object?>> dataRows) {
    String fmt(Object? v) {
      if (v == null) return '';
      if (v is DateTime) {
        return '${v.year}/${v.month.toString().padLeft(2, '0')}/${v.day.toString().padLeft(2, '0')}';
      }
      return v.toString();
    }

    final rows = <List<String>>[
      List<String>.from(kCustomerImportHeaders),
      ...dataRows.map((r) => List<String>.generate(
          kCustomerImportHeaders.length, (i) => i < r.length ? fmt(r[i]) : '')),
    ];
    final csv = const ListToCsvConverter(eol: '\r\n').convert(rows);
    final body = utf8.encode(csv);
    final out = Uint8List(body.length + 3);
    out[0] = 0xEF;
    out[1] = 0xBB;
    out[2] = 0xBF;
    out.setRange(3, out.length, body);
    debugPrint('[CustomerExport] csv built: rows=${dataRows.length}, bytes=${out.length}');
    return out;
  }
}
