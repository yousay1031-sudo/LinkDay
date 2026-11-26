import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/models/support_plan.dart';
import 'package:linkday_app/models/support_plan_form.dart';
import 'package:linkday_app/services/support_plan_pdf_service.dart';
import 'package:pdf/widgets.dart' as pw;

/// ステップ3 段階4: 個別支援計画の印刷（参考様式と同じ並びと見出し・A4 横・2 枚にわたる場合）
void main() {
  SupportPlanRow row(List<String> cats,
          {String goal = '架空の目標',
          String content = '架空の支援内容',
          List<String> domains = const [],
          List<PlanStaff> staff = const [],
          String provider = '',
          String period = '',
          String notes = '',
          int? priority}) =>
      SupportPlanRow(
        categories: cats,
        texts: {
          SupportPlanForm.rGoal: goal,
          SupportPlanForm.rContent: content,
          SupportPlanForm.rPeriod: period,
          SupportPlanForm.rProvider: provider,
          SupportPlanForm.rNotes: notes,
        },
        domains: domains,
        staff: staff,
        priority: priority,
      );

  final plan = SupportPlan(
    id: 'p1',
    customerId: 'c1',
    customerName: '架空 一郎',
    birthday: DateTime(2019, 4, 30),
    createdOn: DateTime(2024, 4, 30),
    managerName: '架空 管理者',
    texts: const {
      SupportPlanForm.kIntention: '架空の意向',
      SupportPlanForm.kPolicy: '架空の方針',
      SupportPlanForm.kLongTerm: '架空の長期目標',
      SupportPlanForm.kShortTerm: '架空の短期目標',
      SupportPlanForm.kStandardTime: '月・水曜日　14:30〜17:30',
    },
    rows: [
      // 様式と違う並びで選んでも、印刷は様式の並び（本人支援 → 移行支援）
      row(['transition', 'self'],
          goal: '架空の目標1',
          content: '架空の内容1',
          domains: ['social', 'health'],
          staff: const [PlanStaff(staffId: 's1', name: '架空 職員')],
          provider: '架空の事業所',
          period: '6か月後',
          notes: '架空の留意事項',
          priority: 1),
      // 本人支援でない行は 5 領域・優先順位を出さない
      row(['family'], domains: ['motor'], priority: 2, period: '3か月後'),
    ],
    explainedOn: DateTime(2024, 5, 1),
  );

  test('参考様式と同じ並びと見出し（文言はそのまま）', () {
    final d = PlanPrintData.from(plan);
    expect(d.lines, [
      '利用児氏名：架空 一郎（2019年4月30日生：5歳0か月）',
      '個別支援計画書',
      '作成年月日：2024年4月30日',
      '利用児及び家族の生活に対する意向', '架空の意向',
      '総合的な支援の方針', '架空の方針',
      '長期目標（内容・期間等）', '架空の長期目標',
      '短期目標（内容・期間等）', '架空の短期目標',
      '支援の標準的な提供時間等（曜日・頻度、時間）', '月・水曜日　14:30〜17:30',
      '○支援目標及び具体的な支援内容等',
      '項目',
      '支援目標\n（具体的な到達目標）',
      '支援内容\n（内容・支援の提供上のポイント・5領域（※）との関連性等）',
      '達成時期',
      '担当者\n提供機関',
      '留意事項\n（本人の役割を含む）',
      '優先順位',
      // 1 行目
      '本人支援\n移行支援',
      '架空の目標1',
      '架空の内容1\n【5領域】健康・生活／人間関係・社会性',
      '6か月後',
      '架空 職員\n架空の事業所',
      '架空の留意事項',
      '1',
      // 2 行目
      '家族支援', '架空の目標', '架空の支援内容', '3か月後', '', '', '',
      '※５領域の視点 ｢健康・生活｣、｢運動・感覚｣、｢認知・行動｣、｢言語・コミュニケーション｣、｢人間関係・社会性｣',
      '提供する支援内容について、本計画書に基づき説明しました。',
      '2024年5月1日',
      '児童発達支援管理責任者氏名：架空 管理者',
      '本計画書に基づき支援の説明を受け、内容に同意しました。',
      // 同意を得た日が無ければ手書き用の空欄
      PlanPrintData.blankDate,
      '（保護者署名）',
    ]);
    // 押印欄は付けない
    expect(d.lines.where((l) => l.contains('印')), isEmpty);
  });

  test('長い欄は「（続き）」の行に分ける（中身は欠けない）', () {
    final long = List.filled(80, '架空の長い支援内容の文。').join();
    final rows =
        PlanPrintData.splitLongRow(['本人支援', '目標', long, '', '', '', '1']);
    expect(rows.length, greaterThan(1));
    expect(rows.first.first, '本人支援');
    expect(rows.skip(1).every((r) => r.first == '（続き）'), isTrue);
    expect(rows.map((r) => r[2]).join(), long);
    expect(
        rows.every((r) => r[2].length <= PlanPrintData.maxCellChars), isTrue);
  });

  group('PDF', () {
    int pageCount(Uint8List b) => RegExp(r'/Type\s*/Page(?![s\w])')
        .allMatches(String.fromCharCodes(b))
        .length;

    Future<(pw.Font, pw.Font)> fonts() async {
      final path = Platform.environment['LINKDAY_PDF_FONT'];
      if (path != null && File(path).existsSync()) {
        final f = pw.Font.ttf(ByteData.sublistView(
            Uint8List.fromList(File(path).readAsBytesSync())));
        return (f, f);
      }
      return (pw.Font.helvetica(), pw.Font.helveticaBold());
    }

    void save(String name, Uint8List b) {
      final out = Platform.environment['LINKDAY_PDF_OUT'];
      if (out != null) File('$out/$name').writeAsBytesSync(b);
    }

    test('A4 横で 1 枚', () async {
      final (r, b) = await fonts();
      final bytes = await SupportPlanPdfService.buildPdf(
          PlanPrintData.from(plan),
          regular: r,
          bold: b);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(pageCount(bytes), 1);
      final box = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)')
          .firstMatch(String.fromCharCodes(bytes))!;
      expect(double.parse(box[1]!), greaterThan(double.parse(box[2]!)));
      save('plan.pdf', bytes);
    });

    test('行が多いと 2 枚以上にわたる。1 つの欄がとても長くても作れる', () async {
      final (r, b) = await fonts();
      final many = plan.copyWith(rows: [
        for (var i = 0; i < 14; i++)
          row([i.isEven ? 'self' : 'family'],
              goal: '架空の目標$i。' * 3,
              content: '架空の支援内容$i。' * 8,
              domains: ['health', 'motor'],
              priority: 1),
        row(['community'], content: List.filled(200, '架空のとても長い内容。').join()),
      ], texts: {
        ...plan.texts,
        SupportPlanForm.kPolicy: List.filled(120, '架空のとても長い方針。').join(),
      });
      final bytes = await SupportPlanPdfService.buildPdf(
          PlanPrintData.from(many),
          regular: r,
          bold: b);
      expect(pageCount(bytes), greaterThanOrEqualTo(2));
      save('plan_long.pdf', bytes);
    });
  });
}
