import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/daily_journal.dart';
import 'daily_journal_service.dart';

/// 業務日誌の印刷の中身（PDF とは別に持ち、テストで中身と並びを確かめる）。
///
/// 1 日 1 枚: 日付・事業所名・職員・利用者と入退室時間・内容・備考・記入者。
class JournalPrintData {
  final String title;
  final String dateLabel;
  final String facilityName;
  final List<String> staffNames;

  /// 利用者の表の見出し
  static const List<String> attendanceHeaders = ['氏名', '入室', '退室', '状態'];

  /// 利用者の表の行（[attendanceHeaders] と同じ並び）
  final List<List<String>> attendanceRows;
  final List<String> activities;
  final String note;

  /// 記入者（最後に保存した担当者と時刻）
  final String writer;

  const JournalPrintData({
    required this.title,
    required this.dateLabel,
    required this.facilityName,
    required this.staffNames,
    required this.attendanceRows,
    required this.activities,
    required this.note,
    required this.writer,
  });

  static const List<String> _weekdays = ['月', '火', '水', '木', '金', '土', '日'];

  static String dateJp(DateTime d) =>
      '${d.year}年${d.month}月${d.day}日（${_weekdays[d.weekday - 1]}）';

  /// 保存済みの日誌と、その日の出席の記録から作る
  factory JournalPrintData.from({
    required DailyJournal journal,
    required List<JournalAttendanceRow> attendance,
    required String facilityName,
  }) {
    final at = journal.updatedAt;
    final who = (journal.updatedByStaffName ?? '').trim();
    return JournalPrintData(
      title: '業務日誌',
      dateLabel: dateJp(journal.date),
      facilityName: facilityName.trim(),
      staffNames: [for (final s in journal.staff) s.name],
      attendanceRows: [
        for (final r in attendance) [r.name, r.inText, r.outText, r.statusText]
      ],
      activities: List<String>.from(journal.activities),
      note: journal.note,
      writer: [
        if (who.isNotEmpty) who,
        if (at != null) DateFormat('M月d日 HH:mm').format(at),
      ].join('　'),
    );
  }

  /// 印刷に出る文字を上から順に並べたもの（テスト用）
  List<String> get lines => [
        title,
        '日付　$dateLabel',
        '事業所名　$facilityName',
        '今日いた職員',
        staffNames.isEmpty ? '（なし）' : staffNames.join('、'),
        '利用者の入退室時間',
        ...attendanceHeaders,
        for (final r in attendanceRows) ...r,
        'その日の内容',
        activities.isEmpty ? '（なし）' : activities.join('、'),
        '備考',
        note.isEmpty ? '（なし）' : note,
        '記入者　$writer',
      ];
}

/// 業務日誌の PDF（A4 縦・1 日 1 枚）を作り、印刷画面を開く。
class DailyJournalPdfService {
  DailyJournalPdfService._();

  /// PDF を作る。フォントは呼び出し側が渡す（テストでは差し替える）。
  /// 中身は 1 枚に収まる量を想定するが、備考が非常に長いなど収まらない場合は
  /// 切らずに 2 枚目へ続ける。
  static Future<Uint8List> buildPdf(
    JournalPrintData d, {
    required pw.Font regular,
    required pw.Font bold,
  }) async {
    final doc = pw.Document(title: '${d.title} ${d.dateLabel}');
    final base = pw.TextStyle(font: regular, fontSize: 10);
    final small = pw.TextStyle(font: regular, fontSize: 9);
    final head = pw.TextStyle(font: bold, fontSize: 11);
    final th = pw.TextStyle(font: bold, fontSize: 9);
    final titleStyle = pw.TextStyle(font: bold, fontSize: 16);

    pw.Widget section(String label, pw.Widget child) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(height: 10),
            pw.Text(label, style: head),
            pw.SizedBox(height: 4),
            child,
          ],
        );

    pw.Widget box(String text) => pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey500, width: 0.5),
          ),
          child: pw.Text(text, style: base),
        );

    pw.Widget cell(String t, pw.TextStyle s) => pw.Padding(
        padding: const pw.EdgeInsets.all(4), child: pw.Text(t, style: s));

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.symmetric(horizontal: 36, vertical: 32),
      build: (context) => [
        pw.Center(child: pw.Text(d.title, style: titleStyle)),
        pw.SizedBox(height: 8),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('日付　${d.dateLabel}', style: base),
            pw.Text('事業所名　${d.facilityName}', style: base),
          ],
        ),
        pw.Divider(thickness: 0.5),
        section('今日いた職員',
            box(d.staffNames.isEmpty ? '（なし）' : d.staffNames.join('、'))),
        section(
          '利用者の入退室時間',
          d.attendanceRows.isEmpty
              ? box('（この日の出席の記録はありません）')
              : pw.Table(
                  border:
                      pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
                  columnWidths: const {
                    0: pw.FlexColumnWidth(3),
                    1: pw.FlexColumnWidth(1.2),
                    2: pw.FlexColumnWidth(1.2),
                    3: pw.FlexColumnWidth(3),
                  },
                  children: [
                    pw.TableRow(
                      decoration:
                          const pw.BoxDecoration(color: PdfColors.grey200),
                      children: [
                        for (final h in JournalPrintData.attendanceHeaders)
                          cell(h, th)
                      ],
                    ),
                    for (final r in d.attendanceRows)
                      pw.TableRow(
                          children: [for (final c in r) cell(c, small)]),
                  ],
                ),
        ),
        section('その日の内容',
            box(d.activities.isEmpty ? '（なし）' : d.activities.join('、'))),
        // 備考は長くなりうるので、ページをまたいで続けられる形で置く（枠に入れると
        // 1 枚に収まらないときに続けられない）
        pw.SizedBox(height: 10),
        pw.Text('備考', style: head),
        pw.SizedBox(height: 4),
        pw.Text(d.note.isEmpty ? '（なし）' : d.note,
            style: base, overflow: pw.TextOverflow.span),
        pw.Divider(thickness: 0.5, color: PdfColors.grey500),
        pw.SizedBox(height: 12),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('記入者　${d.writer}', style: base),
        ),
      ],
    ));
    return doc.save();
  }

  /// 印刷画面を開く（フォントは今ある PDF と同じく Google のフォント配信から取る）
  static Future<void> printJournal(JournalPrintData d, DateTime date) async {
    final regular = await PdfGoogleFonts.notoSansJPRegular();
    final bold = await PdfGoogleFonts.notoSansJPBold();
    final bytes = await buildPdf(d, regular: regular, bold: bold);
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: '業務日誌_${DateFormat('yyyyMMdd').format(date)}.pdf',
    );
  }
}
