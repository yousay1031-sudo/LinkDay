import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/support_plan.dart';
import '../models/support_plan_form.dart';

/// 個別支援計画の印刷の中身（PDF とは別に持ち、テストで見出し・並び・文字を確かめる）。
///
/// 参考様式（別紙1-1）と同じ並びと見出し。A4 横。
/// 上の部分 → 方針（意向・総合的な支援の方針・長期目標・短期目標、右に支援の標準的な
/// 提供時間等）→ ○支援目標及び具体的な支援内容等（表）→ ※5領域 → 説明と同意。
/// 押印欄は付けない（参考様式は押印廃止）。
class PlanPrintData {
  final String title;

  /// 「利用児氏名：○○ ○○（2019年4月30日生：5歳0か月）」
  final String childLine;

  /// 「作成年月日：2026年5月1日」（未入力は手書き用の空欄）
  final String createdOnLine;

  /// 方針の欄（見出し, 文章）。様式の並び
  final List<(String, String)> policy;

  final String tableTitle;
  final List<String> tableHeaders;

  /// 支援の表の行（[tableHeaders] と同じ並び）。長い行は「（続き）」の行に分けてある
  final List<List<String>> tableRows;
  final String domainNote;

  final String explainedText;
  final String explainedDate;
  final String managerLine;
  final String agreedText;
  final String agreedDate;
  final String guardianSignLabel;

  const PlanPrintData({
    required this.title,
    required this.childLine,
    required this.createdOnLine,
    required this.policy,
    required this.tableTitle,
    required this.tableHeaders,
    required this.tableRows,
    required this.domainNote,
    required this.explainedText,
    required this.explainedDate,
    required this.managerLine,
    required this.agreedText,
    required this.agreedDate,
    required this.guardianSignLabel,
  });

  /// 手書き用の日付の空欄
  static const String blankDate = '　　　　年　　月　　日';

  static String dateJp(DateTime? d) =>
      d == null ? blankDate : '${d.year}年${d.month}月${d.day}日';

  /// 1 つの欄にこれより長い文章があれば「（続き）」の行に分ける（1 行が 1 枚に
  /// 収まらないと PDF を作れないため。表の文字の大きさでおおよそ半ページ分）
  static const int maxCellChars = 420;

  /// 生年月日と年齢（作成年月日の時点）
  static String birthAndAge(DateTime? birthday, DateTime? at) {
    if (birthday == null) return '生年月日：未登録';
    final b = '${birthday.year}年${birthday.month}月${birthday.day}日生';
    if (at == null) return b;
    var months = (at.year - birthday.year) * 12 + at.month - birthday.month;
    if (at.day < birthday.day) months--;
    if (months < 0) return b;
    return '$b：${months ~/ 12}歳${months % 12}か月';
  }

  factory PlanPrintData.from(SupportPlan p) {
    final rows = <List<String>>[];
    for (final r in p.rows) {
      final row = r.normalized();
      final cats = [
        for (final c in row.categories) SupportPlanForm.categoryLabel(c)
      ].join('\n');
      final content = [
        row.text(SupportPlanForm.rContent),
        if (row.usesDomains && row.domains.isNotEmpty)
          '【5領域】${row.domains.map(SupportPlanForm.domainLabel).join('／')}',
      ].where((s) => s.isNotEmpty).join('\n');
      final staff = [
        ...row.staff.map((s) => s.name),
        if (row.text(SupportPlanForm.rProvider).isNotEmpty)
          row.text(SupportPlanForm.rProvider),
      ].join('\n');
      final cells = [
        cats,
        row.text(SupportPlanForm.rGoal),
        content,
        row.text(SupportPlanForm.rPeriod),
        staff,
        row.text(SupportPlanForm.rNotes),
        row.usesDomains && row.priority != null ? '${row.priority}' : '',
      ];
      rows.addAll(splitLongRow(cells));
    }
    return PlanPrintData(
      title: SupportPlanForm.title,
      childLine:
          '${SupportPlanForm.childNameLabel}：${p.customerName}（${birthAndAge(p.birthday, p.createdOn)}）',
      createdOnLine: '${SupportPlanForm.createdOnLabel}：${dateJp(p.createdOn)}',
      policy: [
        for (final f in SupportPlanForm.policyFields) (f.label, p.text(f.key))
      ],
      tableTitle: SupportPlanForm.tableTitle,
      tableHeaders: [for (final c in SupportPlanForm.columns) c.label],
      tableRows: rows,
      domainNote: SupportPlanForm.domainNote,
      explainedText: SupportPlanForm.explainedText,
      explainedDate: dateJp(p.explainedOn),
      managerLine: '${SupportPlanForm.managerLabel}：${p.managerName}',
      agreedText: SupportPlanForm.agreedText,
      agreedDate: dateJp(p.agreedOn),
      guardianSignLabel: SupportPlanForm.guardianSignLabel,
    );
  }

  /// 長い欄のある行を、続きの行に分ける（1 つ目の項目の欄に「（続き）」）
  static List<List<String>> splitLongRow(List<String> cells) {
    final parts = [for (final c in cells) _chunks(c, maxCellChars)];
    final n = parts.map((p) => p.length).reduce((a, b) => a > b ? a : b);
    return [
      for (var i = 0; i < n; i++)
        [
          for (var c = 0; c < cells.length; c++)
            i < parts[c].length ? parts[c][i] : (c == 0 && i > 0 ? '（続き）' : ''),
        ]
    ];
  }

  static List<String> _chunks(String s, int max) {
    if (s.length <= max) return [s];
    final out = <String>[];
    var rest = s;
    while (rest.length > max) {
      // 改行・句点で切れるならそこで切る
      var cut = rest.lastIndexOf('\n', max);
      if (cut < max ~/ 2) cut = rest.lastIndexOf('。', max - 1) + 1;
      if (cut < max ~/ 2) cut = max;
      out.add(rest.substring(0, cut).trimRight());
      rest = rest.substring(cut).trimLeft();
    }
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  /// 印刷に出る文字を上から順に並べたもの（テスト用）
  List<String> get lines => [
        childLine,
        title,
        createdOnLine,
        for (final (label, text) in policy) ...[label, text],
        tableTitle,
        ...tableHeaders,
        for (final r in tableRows) ...r,
        domainNote,
        explainedText,
        explainedDate,
        managerLine,
        agreedText,
        agreedDate,
        guardianSignLabel,
      ];
}

/// 個別支援計画の PDF（A4 横）を作り、印刷画面を開く。
class SupportPlanPdfService {
  SupportPlanPdfService._();

  /// 方針の欄の文章がこれより長いときは、様式の配置（長期・短期目標の右に提供時間）を
  /// やめて、1 欄ずつ全幅で出す（ページをまたいで続けられるように）
  static const int _compactLimit = 600;

  static Future<Uint8List> buildPdf(
    PlanPrintData d, {
    required pw.Font regular,
    required pw.Font bold,
  }) async {
    final doc = pw.Document(title: '${d.title} ${d.childLine}');
    final base = pw.TextStyle(font: regular, fontSize: 8.5, lineSpacing: 1.5);
    final head = pw.TextStyle(font: bold, fontSize: 8.5);
    final title = pw.TextStyle(font: bold, fontSize: 15);
    const border = PdfColors.grey700;

    pw.Widget cell(String t, pw.TextStyle s,
            {PdfColor? bg, pw.Alignment? align}) =>
        pw.Container(
          color: bg,
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(t, style: s),
        );

    // ── 方針
    final policy = d.policy;
    String textOf(int i) => i < policy.length ? policy[i].$2 : '';
    final compact = policy.length == 5 &&
        [2, 3, 4].every((i) => textOf(i).length <= _compactLimit);
    pw.TableRow policyRow(String label, String text) => pw.TableRow(children: [
          cell(label, head, bg: PdfColors.grey200),
          cell(text, base),
        ]);
    final policyWidgets = <pw.Widget>[];
    // 意向・総合的な支援の方針（長ければ続きの行に分ける）
    final fullRows = <pw.TableRow>[];
    for (var i = 0; i < (compact ? 2 : policy.length); i++) {
      final chunks = PlanPrintData.splitLongRow([policy[i].$1, policy[i].$2]);
      for (final c in chunks) {
        fullRows.add(policyRow(c[0] == '（続き）' ? '（続き）' : c[0], c[1]));
      }
    }
    policyWidgets.add(pw.Table(
      border: pw.TableBorder.all(color: border, width: 0.6),
      columnWidths: const {
        0: pw.FixedColumnWidth(110),
        1: pw.FlexColumnWidth()
      },
      children: fullRows,
    ));
    if (compact) {
      // 様式の配置: 左に長期目標・短期目標、右に支援の標準的な提供時間等
      policyWidgets.add(pw.Table(
        border: pw.TableBorder.all(color: border, width: 0.6),
        columnWidths: const {
          0: pw.FixedColumnWidth(110),
          1: pw.FlexColumnWidth(3),
          2: pw.FixedColumnWidth(110),
          3: pw.FlexColumnWidth(2),
        },
        children: [
          pw.TableRow(children: [
            cell(policy[2].$1, head, bg: PdfColors.grey200),
            cell(policy[2].$2, base),
            cell(policy[4].$1, head, bg: PdfColors.grey200),
            cell(policy[4].$2, base),
          ]),
          pw.TableRow(children: [
            cell(policy[3].$1, head, bg: PdfColors.grey200),
            cell(policy[3].$2, base),
            cell('', base),
            cell('', base),
          ]),
        ],
      ));
    }

    // ── 支援の表
    final table = pw.Table(
      border: pw.TableBorder.all(color: border, width: 0.6),
      columnWidths: const {
        0: pw.FixedColumnWidth(58), // 項目
        1: pw.FlexColumnWidth(3), // 支援目標
        2: pw.FlexColumnWidth(4.2), // 支援内容
        3: pw.FixedColumnWidth(46), // 達成時期
        4: pw.FlexColumnWidth(1.6), // 担当者・提供機関
        5: pw.FlexColumnWidth(2.4), // 留意事項
        6: pw.FixedColumnWidth(30), // 優先順位
      },
      children: [
        // 見出しの行は 2 枚目以降にも出す
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            for (final h in d.tableHeaders)
              cell(h, head, align: pw.Alignment.center),
          ],
        ),
        for (final r in d.tableRows)
          pw.TableRow(children: [
            for (var i = 0; i < r.length; i++)
              cell(r[i], i == 0 ? head : base,
                  align: i == 6 ? pw.Alignment.topCenter : null),
          ]),
      ],
    );

    // ── 説明と同意（署名欄。押印欄は付けない）
    pw.Widget signBox(String text, String date, String who) => pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(6),
            decoration: pw.BoxDecoration(
                border: pw.Border.all(color: border, width: 0.6)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(text, style: base),
                pw.SizedBox(height: 6),
                pw.Text(date, style: base),
                pw.SizedBox(height: 10),
                pw.Text(who, style: base),
              ],
            ),
          ),
        );

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      build: (context) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(flex: 5, child: pw.Text(d.childLine, style: base)),
            pw.Expanded(
                flex: 3,
                child: pw.Center(child: pw.Text(d.title, style: title))),
            pw.Expanded(
              flex: 4,
              child: pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text(d.createdOnLine, style: base)),
            ),
          ],
        ),
        pw.SizedBox(height: 6),
        ...policyWidgets,
        pw.SizedBox(height: 8),
        pw.Text(d.tableTitle, style: head),
        pw.SizedBox(height: 3),
        table,
        pw.SizedBox(height: 3),
        pw.Text(d.domainNote, style: base),
        pw.SizedBox(height: 8),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            signBox(d.explainedText, d.explainedDate, d.managerLine),
            pw.SizedBox(width: 10),
            signBox(d.agreedText, d.agreedDate,
                '${d.guardianSignLabel}　　　　　　　　　　　　　　　　　　'),
          ],
        ),
      ],
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('${context.pageNumber} / ${context.pagesCount}',
            style: base),
      ),
    ));
    return doc.save();
  }

  /// 印刷画面を開く（フォントは今ある PDF と同じく Google のフォント配信から取る）
  static Future<void> printPlan(PlanPrintData d, SupportPlan p) async {
    final regular = await PdfGoogleFonts.notoSansJPRegular();
    final bold = await PdfGoogleFonts.notoSansJPBold();
    final bytes = await buildPdf(d, regular: regular, bold: bold);
    final c = p.createdOn;
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: '個別支援計画書_${p.customerName}'
          '${c == null ? '' : '_${c.year}${c.month.toString().padLeft(2, '0')}${c.day.toString().padLeft(2, '0')}'}.pdf',
    );
  }
}
