import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/customer.dart';
import '../models/weekly_schedule.dart';

/// 週間利用計画表 PDF 出力サービス
/// A4 横（landscape）で1枚に収める。
///
/// NOTE: printing パッケージの Wasm 警告は既知問題のため無視してください。
class WeeklySchedulePdfService {
  WeeklySchedulePdfService._();
  static final WeeklySchedulePdfService instance =
      WeeklySchedulePdfService._();

  /// 事業所名（将来は設定画面から取得予定）
  static const String facilityName = 'LinkDay';

  // 曜日ラベル（列ヘッダー）
  static const List<String> _dayLabels = ['月', '火', '水', '木', '金', '土', '日'];

  // ── 公開メソッド ─────────────────────────────────────────────

  /// 週間利用計画表 PDF を生成し印刷プレビューを開く
  Future<void> printWeeklySchedule(
    WeeklySchedule schedule,
    List<Customer> customers,
  ) async {
    final doc = await _buildDocument(schedule, customers);
    await Printing.layoutPdf(
      onLayout: (format) async => doc.save(),
      name: '週間利用計画表_${schedule.weekKey}.pdf',
    );
  }

  // ── 内部実装 ─────────────────────────────────────────────────

  Future<pw.Document> _buildDocument(
    WeeklySchedule schedule,
    List<Customer> customers,
  ) async {
    final doc = pw.Document();

    final font = await PdfGoogleFonts.notoSansJPRegular();
    final boldFont = await PdfGoogleFonts.notoSansJPBold();

    final baseStyle = pw.TextStyle(font: font, fontSize: 8);
    final boldStyle = pw.TextStyle(
      font: boldFont,
      fontSize: 8,
      fontWeight: pw.FontWeight.bold,
    );
    final titleStyle = pw.TextStyle(
      font: boldFont,
      fontSize: 13,
      fontWeight: pw.FontWeight.bold,
    );
    final headerStyle = pw.TextStyle(
      font: boldFont,
      fontSize: 7.5,
      fontWeight: pw.FontWeight.bold,
    );
    final cellStyle = pw.TextStyle(font: font, fontSize: 7);
    final cellBoldStyle = pw.TextStyle(
      font: boldFont,
      fontSize: 7,
      fontWeight: pw.FontWeight.bold,
    );

    // アクティブ顧客リスト（週間計画に登場する顧客を優先、残りは氏名順）
    final allCustomerIds = schedule.allCustomerIds;
    final customerMap = <String, Customer>{
      for (final c in customers) c.id: c,
    };
    // 週間計画に含まれる顧客（氏名順）
    final scheduleCustomers = allCustomerIds
        .map((id) => customerMap[id])
        .whereType<Customer>()
        .toList()
      ..sort((a, b) => a.nameKana.compareTo(b.nameKana));

    // 今週の利用日数マップ
    final usageMap = schedule.usageByCustomer();

    // 週の月曜〜日曜の日付リスト（PDF 列ヘッダー用）
    final weekDates = List.generate(
      7,
      (i) => schedule.weekStartDate.add(Duration(days: i)),
    );

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // ── タイトル行 ──────────────────────────────────
              pw.Center(
                child: pw.Text('週間利用計画表', style: titleStyle),
              ),
              pw.SizedBox(height: 6),

              // ── 週情報 ──────────────────────────────────────
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    '期間: ${_weekRangeText(schedule.weekStartDate)}',
                    style: baseStyle,
                  ),
                  pw.Text(
                    '事業所: $facilityName',
                    style: baseStyle,
                  ),
                  pw.Text(
                    '出力日: ${_todayJP()}',
                    style: baseStyle,
                  ),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Divider(thickness: 0.5),
              pw.SizedBox(height: 4),

              // ── メインテーブル ───────────────────────────────
              pw.Table(
                border: pw.TableBorder.all(
                  color: PdfColors.grey400,
                  width: 0.5,
                ),
                columnWidths: const {
                  0: pw.FlexColumnWidth(2.6), // 氏名
                  1: pw.FlexColumnWidth(1.4), // 月
                  2: pw.FlexColumnWidth(1.4), // 火
                  3: pw.FlexColumnWidth(1.4), // 水
                  4: pw.FlexColumnWidth(1.4), // 木
                  5: pw.FlexColumnWidth(1.4), // 金
                  6: pw.FlexColumnWidth(1.4), // 土
                  7: pw.FlexColumnWidth(1.4), // 日
                  8: pw.FlexColumnWidth(1.0), // 週合計
                },
                children: [
                  // ── ヘッダー行（曜日 + 日付）
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                      color: PdfColors.blueGrey100,
                    ),
                    children: [
                      _headerCell('氏名', headerStyle),
                      for (int i = 0; i < 7; i++)
                        _headerCell(
                          '${_dayLabels[i]}\n${_shortDate(weekDates[i])}',
                          headerStyle,
                        ),
                      _headerCell('週計', headerStyle),
                    ],
                  ),

                  // ── データ行（顧客ごと）
                  for (final customer in scheduleCustomers)
                    _buildCustomerRow(
                      customer,
                      schedule,
                      usageMap[customer.id] ?? 0,
                      cellStyle,
                      cellBoldStyle,
                      boldStyle,
                    ),

                  // ── 日別合計行
                  _buildDailyTotalRow(schedule, boldStyle),
                ],
              ),

              pw.Spacer(),

              // ── フッター ────────────────────────────────────
              pw.Divider(thickness: 0.5),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(facilityName, style: boldStyle),
                  pw.Text(
                    'ページ 1 / 1',
                    style: pw.TextStyle(font: font, fontSize: 7),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );

    return doc;
  }

  // ── 行ビルダー ────────────────────────────────────────────────

  pw.TableRow _buildCustomerRow(
    Customer customer,
    WeeklySchedule schedule,
    int weeklyUsage,
    pw.TextStyle cellStyle,
    pw.TextStyle cellBoldStyle,
    pw.TextStyle boldStyle,
  ) {
    // 月間バッジテキスト
    final used = customer.currentMonthUsedDays;
    final available = customer.monthlyAvailableDays;
    final monthBadge = '$used/$available';

    return pw.TableRow(
      children: [
        // 氏名列
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(customer.name, style: cellBoldStyle),
              pw.Text(
                '今月 $monthBadge日',
                style: pw.TextStyle(
                  font: cellStyle.font,
                  fontSize: 6,
                  color: PdfColors.grey600,
                ),
              ),
            ],
          ),
        ),
        // 月〜日（7列）
        for (int dow = 1; dow <= 7; dow++)
          _buildDayCell(customer.id, schedule, dow, cellStyle, cellBoldStyle),
        // 週合計列
        pw.Padding(
          padding: const pw.EdgeInsets.all(3),
          child: pw.Center(
            child: pw.Text(
              '$weeklyUsage',
              style: boldStyle,
            ),
          ),
        ),
      ],
    );
  }

  pw.Widget _buildDayCell(
    String customerId,
    WeeklySchedule schedule,
    int dayOfWeek,
    pw.TextStyle cellStyle,
    pw.TextStyle cellBoldStyle,
  ) {
    final slot = schedule.slotForDay(dayOfWeek);
    final entry = slot?.findEntry(customerId);

    if (entry == null) {
      return pw.SizedBox();
    }

    // ステータスに応じた表示
    PdfColor bgColor;
    String icon;
    String timeText;

    switch (entry.status) {
      case ScheduleStatus.planned:
        bgColor = PdfColors.green50;
        icon = '✓';
        timeText = _entryTimeText(entry);
        break;
      case ScheduleStatus.additional:
        bgColor = PdfColors.blue50;
        icon = '＋';
        timeText = _entryTimeText(entry);
        break;
      case ScheduleStatus.cancelled:
        bgColor = PdfColors.grey100;
        icon = '×';
        timeText = '';
        break;
    }

    return pw.Container(
      color: bgColor,
      padding: const pw.EdgeInsets.all(2),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          pw.Text(
            icon,
            style: pw.TextStyle(
              font: cellBoldStyle.font,
              fontSize: 9,
              color: entry.status == ScheduleStatus.cancelled
                  ? PdfColors.grey
                  : entry.status == ScheduleStatus.additional
                      ? PdfColors.blue700
                      : PdfColors.green700,
            ),
          ),
          if (timeText.isNotEmpty)
            pw.Text(
              timeText,
              style: pw.TextStyle(
                font: cellStyle.font,
                fontSize: 6,
                color: PdfColors.grey700,
              ),
            ),
        ],
      ),
    );
  }

  pw.TableRow _buildDailyTotalRow(
    WeeklySchedule schedule,
    pw.TextStyle boldStyle,
  ) {
    return pw.TableRow(
      decoration: const pw.BoxDecoration(
        color: PdfColors.blueGrey50,
      ),
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          child: pw.Text('日計', style: boldStyle),
        ),
        for (int dow = 1; dow <= 7; dow++) ...[
          pw.Padding(
            padding: const pw.EdgeInsets.all(2),
            child: pw.Center(
              child: pw.Text(
                '${schedule.slotForDay(dow)?.activeCount ?? 0}名',
                style: boldStyle,
              ),
            ),
          ),
        ],
        pw.SizedBox(),
      ],
    );
  }

  // ── セルヘルパー ─────────────────────────────────────────────

  pw.Widget _headerCell(String text, pw.TextStyle style) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      child: pw.Center(
        child: pw.Text(text, style: style, textAlign: pw.TextAlign.center),
      ),
    );
  }

  // ── フォーマットヘルパー ──────────────────────────────────────

  String _entryTimeText(ScheduleEntry entry) {
    if (entry.plannedStartTime != null && entry.plannedEndTime != null) {
      return '${entry.plannedStartTime}-${entry.plannedEndTime}';
    }
    if (entry.plannedStartTime != null) {
      return entry.plannedStartTime!;
    }
    return '';
  }

  String _weekRangeText(DateTime monday) {
    final sunday = monday.add(const Duration(days: 6));
    final start = '${monday.year}年${monday.month}月${monday.day}日';
    final end = sunday.month == monday.month
        ? '${sunday.day}日'
        : '${sunday.month}月${sunday.day}日';
    return '$start〜$end';
  }

  String _shortDate(DateTime d) {
    return '${d.month}/${d.day}';
  }

  String _todayJP() {
    final now = DateTime.now();
    return DateFormat('yyyy年M月d日').format(now);
  }
}
