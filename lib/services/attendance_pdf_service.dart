import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/attendance_record.dart';
import '../models/customer.dart';
import '../services/attendance_service.dart';
import '../services/customer_service.dart';

/// PDF 出力サービス
/// サービス提供実績記録票（A4縦）を生成し、Web で印刷プレビューを表示する。
///
/// NOTE: printing パッケージの Wasm 警告は既知の問題のため無視してください。
///   JS ビルドが通れば Web では正常に動作します。
class AttendancePdfService {
  AttendancePdfService._();
  static final AttendancePdfService instance = AttendancePdfService._();

  /// 事業所名（将来は設定画面から取得予定）
  static const String facilityName = 'LinkDay';

  // ── 公開メソッド ─────────────────────────────────────────────

  /// 指定日のサービス提供実績記録票 PDF を生成し印刷プレビューを開く
  Future<void> printAttendanceSheet(DateTime date) async {
    final items = _buildItems(date);
    final doc = await _buildDocument(date, items);
    await Printing.layoutPdf(
      onLayout: (format) async => doc.save(),
      name: 'サービス提供実績記録票_${_dateFileName(date)}.pdf',
    );
  }

  // ── 内部実装 ────────────────────────────────────────────────

  List<_RecordWithCustomer> _buildItems(DateTime date) {
    final records = AttendanceService.instance.getRecordsByDate(date);
    final allCustomers = CustomerService.instance.getAllCustomers();
    final customerMap = <String, Customer>{
      for (final c in allCustomers) c.id: c,
    };
    return records.map((r) {
      return _RecordWithCustomer(
        record: r,
        customer: customerMap[r.customerId],
      );
    }).toList()
      ..sort((a, b) => a.record.customerName.compareTo(b.record.customerName));
  }

  Future<pw.Document> _buildDocument(
    DateTime date,
    List<_RecordWithCustomer> items,
  ) async {
    final doc = pw.Document();

    final font = await PdfGoogleFonts.notoSansJPRegular();
    final boldFont = await PdfGoogleFonts.notoSansJPBold();

    final base = pw.TextStyle(font: font, fontSize: 9);
    final bold = pw.TextStyle(font: boldFont, fontSize: 9);
    final title = pw.TextStyle(
      font: boldFont,
      fontSize: 14,
      fontWeight: pw.FontWeight.bold,
    );
    final header = pw.TextStyle(
      font: boldFont,
      fontSize: 8,
      fontWeight: pw.FontWeight.bold,
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        build: (context) => [
          // タイトル
          pw.Center(
            child: pw.Text('サービス提供実績記録票', style: title),
          ),
          pw.SizedBox(height: 8),

          // ヘッダー情報
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('事業所名: $facilityName', style: base),
              pw.Text('日付: ${_dateJP(date)}', style: base),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Divider(thickness: 0.5),
          pw.SizedBox(height: 8),

          // メインテーブル
          pw.Table(
            border: pw.TableBorder.all(
              color: PdfColors.grey400,
              width: 0.5,
            ),
            columnWidths: const {
              0: pw.FlexColumnWidth(2.8), // 氏名
              1: pw.FlexColumnWidth(2.5), // 受給者証番号
              2: pw.FlexColumnWidth(1.4), // 状態
              3: pw.FlexColumnWidth(1.4), // 入室
              4: pw.FlexColumnWidth(1.4), // 退室
              5: pw.FlexColumnWidth(1.4), // 提供時間
              6: pw.FlexColumnWidth(2.5), // 欠席理由
            },
            children: [
              // ヘッダー行
              pw.TableRow(
                decoration: const pw.BoxDecoration(
                  color: PdfColors.blueGrey100,
                ),
                children: [
                  _cell('氏名', style: header),
                  _cell('受給者証番号', style: header),
                  _cell('状態', style: header),
                  _cell('入室時刻', style: header),
                  _cell('退室時刻', style: header),
                  _cell('提供時間', style: header),
                  _cell('欠席理由', style: header),
                ],
              ),
              // データ行
              for (final item in items) _buildDataRow(item, base),
            ],
          ),

          pw.SizedBox(height: 12),

          // 集計
          pw.Row(
            children: [
              pw.Text('合計: ${items.length}名', style: bold),
              pw.SizedBox(width: 16),
              pw.Text(
                '利用: ${_countUtilized(items)}名',
                style: base,
              ),
              pw.SizedBox(width: 16),
              pw.Text(
                '欠席: ${_countAbsent(items)}名',
                style: base,
              ),
            ],
          ),

          pw.SizedBox(height: 20),

          // 備考欄
          pw.Text('備考', style: bold),
          pw.SizedBox(height: 4),
          pw.Container(
            height: 56,
            decoration: pw.BoxDecoration(
              border:
                  pw.Border.all(color: PdfColors.grey400, width: 0.5),
            ),
          ),

          pw.SizedBox(height: 16),

          // 署名欄
          pw.Row(
            children: [
              _signatureBox('管理者確認', bold, base),
              pw.SizedBox(width: 12),
              _signatureBox('記録者', bold, base),
              pw.SizedBox(width: 12),
              _signatureBox('保護者確認', bold, base),
            ],
          ),
        ],
      ),
    );
    return doc;
  }

  pw.TableRow _buildDataRow(_RecordWithCustomer item, pw.TextStyle style) {
    final r = item.record;
    final c = item.customer;
    final bgColor = r.status == AttendanceStatus.absent
        ? PdfColors.red50
        : PdfColors.white;

    return pw.TableRow(
      decoration: pw.BoxDecoration(color: bgColor),
      children: [
        _cell(r.customerName, style: style),
        _cell(c?.recipientCertNumber ?? '—', style: style),
        _cell(r.statusLabel, style: style),
        _cell(r.checkInTime != null ? _time(r.checkInTime!) : '', style: style),
        _cell(
            r.checkOutTime != null ? _time(r.checkOutTime!) : '', style: style),
        _cell(r.serviceTimeLabel ?? '', style: style),
        _cell(r.absenceReason ?? '', style: style),
      ],
    );
  }

  pw.Widget _cell(String text, {required pw.TextStyle style}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(text, style: style),
    );
  }

  pw.Widget _signatureBox(
    String label,
    pw.TextStyle labelStyle,
    pw.TextStyle baseStyle,
  ) {
    return pw.Expanded(
      child: pw.Container(
        height: 44,
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
        ),
        child: pw.Padding(
          padding: const pw.EdgeInsets.all(4),
          child: pw.Text(label, style: labelStyle),
        ),
      ),
    );
  }

  int _countUtilized(List<_RecordWithCustomer> items) => items
      .where((i) =>
          i.record.status == AttendanceStatus.present ||
          i.record.status == AttendanceStatus.departed)
      .length;

  int _countAbsent(List<_RecordWithCustomer> items) => items
      .where((i) => i.record.status == AttendanceStatus.absent)
      .length;

  String _dateFileName(DateTime d) =>
      DateFormat('yyyyMMdd').format(d);

  String _dateJP(DateTime d) =>
      '${d.year}年${d.month}月${d.day}日';

  String _time(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

class _RecordWithCustomer {
  final AttendanceRecord record;
  final Customer? customer;
  const _RecordWithCustomer({required this.record, this.customer});
}
