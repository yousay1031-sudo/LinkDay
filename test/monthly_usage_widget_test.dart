import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:linkday_app/services/monthly_usage_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:linkday_app/widgets/monthly_usage_chip.dart';

/// Day 9: 残日数 UI（チップ / 警告バナー / カレンダー / 数値サマリー）
///
/// MonthlyUsage は immutable な値オブジェクトなので Hive 不要で検証できる。
void main() {
  MonthlyUsage usage({
    int available = 23,
    int actual = 12,
    int planned = 0,
    Map<int, DayUsageKind> kinds = const {},
    bool fallback = false,
    int? raw,
    DateTime? month,
  }) =>
      MonthlyUsage(
        customerId: 'c1',
        customerName: '田中 健太',
        month: month ?? DateTime(2026, 10),
        available: available,
        usedActual: actual,
        plannedRemaining: planned,
        dayKinds: kinds,
        availableFallback: fallback,
        rawAvailable: raw ?? available,
      );

  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ));

  group('MonthlyUsageChip', () {
    testWidgets('残日数ラベルが「今月 12/23日（残11）」形式で表示される', (tester) async {
      await pump(tester, MonthlyUsageChip(usage: usage()));
      expect(tester.takeException(), isNull);
      expect(find.text('今月 12/23日（残11）'), findsOneWidget);
    });

    testWidgets('compact では「12/23日」のみ', (tester) async {
      await pump(tester, MonthlyUsageChip(usage: usage(), compact: true));
      expect(find.text('12/23日'), findsOneWidget);
    });

    testWidgets('色分け: 残>5 は通常色（secondary）', (tester) async {
      final u = usage(available: 23, actual: 10); // 残 13
      expect(MonthlyUsageChip.colorFor(u), AppColors.secondary);
      await pump(tester, MonthlyUsageChip(usage: u));
      expect(tester.takeException(), isNull);
    });

    testWidgets('色分け: 残1〜5 は橙（warning）', (tester) async {
      for (final actual in [18, 22]) {
        final u = usage(available: 23, actual: actual); // 残 5 / 残 1
        expect(MonthlyUsageChip.colorFor(u), AppColors.warning,
            reason: '実績$actual');
      }
    });

    testWidgets('色分け: 残0以下は赤（error）', (tester) async {
      for (final actual in [23, 25]) {
        final u = usage(available: 23, actual: actual); // 残 0 / 残 -2
        expect(MonthlyUsageChip.colorFor(u), AppColors.error,
            reason: '実績$actual');
      }
    });

    testWidgets('見込み超過時は警告アイコンが表示される', (tester) async {
      // 残は 11 あるが、予定を含めると超過（12 + 15 = 27 > 23）
      final u = usage(available: 23, actual: 12, planned: 15);
      expect(u.isOverProjected, isTrue);
      await pump(tester, MonthlyUsageChip(usage: u));
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('超過していなければ警告アイコンは出ない', (tester) async {
      final u = usage(available: 23, actual: 12, planned: 5);
      expect(u.isOverProjected, isFalse);
      await pump(tester, MonthlyUsageChip(usage: u));
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });
  });

  group('OverProjectedBanner', () {
    testWidgets('超過時に制度上の案内文が表示される', (tester) async {
      final u = usage(available: 23, actual: 20, planned: 6); // 26 → 超過3日
      await pump(tester, OverProjectedBanner(usage: u));
      expect(tester.takeException(), isNull);
      expect(
          find.textContaining('今月の支給日数を超過する見込みです'), findsOneWidget);
      expect(find.textContaining('利用者負担となる可能性があります'), findsOneWidget);
      expect(find.textContaining('超過 3日'), findsOneWidget);
    });

    testWidgets('超過していなければ何も描画しない', (tester) async {
      final u = usage(available: 23, actual: 5, planned: 2);
      await pump(tester, OverProjectedBanner(usage: u));
      expect(find.textContaining('超過する見込み'), findsNothing);
    });
  });

  group('MonthlyUsageCalendar', () {
    testWidgets('当月の日数分セルが描画され、凡例が揃う', (tester) async {
      final u = usage(kinds: {
        1: DayUsageKind.actual,
        2: DayUsageKind.planned,
        3: DayUsageKind.absent,
        for (int d = 4; d <= 31; d++) d: DayUsageKind.none,
      });
      await pump(tester,
          MonthlyUsageCalendar(usage: u, today: DateTime(2026, 10, 15)));
      expect(tester.takeException(), isNull);
      // 凡例
      expect(find.text('実績'), findsOneWidget);
      expect(find.text('予定'), findsOneWidget);
      expect(find.text('欠席'), findsOneWidget);
      expect(find.text('今日'), findsOneWidget);
      // 曜日ヘッダー（月曜始まり）
      expect(find.text('月'), findsOneWidget);
      expect(find.text('日'), findsOneWidget);
      // 日付セル（10月は31日）
      expect(find.text('31'), findsOneWidget);
    });

    testWidgets('うるう年2月は29日まで描画される', (tester) async {
      final u = usage(month: DateTime(2024, 2), actual: 0);
      await pump(tester,
          MonthlyUsageCalendar(usage: u, today: DateTime(2024, 2, 10)));
      expect(tester.takeException(), isNull);
      expect(find.text('29'), findsOneWidget);
      expect(find.text('30'), findsNothing);
    });

    testWidgets('平年2月は28日まで', (tester) async {
      final u = usage(month: DateTime(2026, 2), actual: 0);
      await pump(tester,
          MonthlyUsageCalendar(usage: u, today: DateTime(2026, 2, 10)));
      expect(find.text('28'), findsOneWidget);
      expect(find.text('29'), findsNothing);
    });
  });

  group('MonthlyUsageStats', () {
    testWidgets('5 指標（支給量/実績/今後予定/実績残/見込み残）が表示される', (tester) async {
      final u = usage(available: 23, actual: 11, planned: 5);
      await pump(tester, MonthlyUsageStats(usage: u));
      expect(tester.takeException(), isNull);
      expect(find.text('支給量'), findsOneWidget);
      expect(find.text('実績'), findsOneWidget);
      expect(find.text('今後予定'), findsOneWidget);
      expect(find.text('実績残'), findsOneWidget);
      expect(find.text('見込み残'), findsOneWidget);
      expect(find.text('見込み合計'), findsOneWidget);
      // 値: 23 / 11 / 5 / 12 / 7 / 16
      expect(find.text('23'), findsOneWidget);
      expect(find.text('11'), findsOneWidget);
      expect(find.text('12'), findsOneWidget); // 実績残
      expect(find.text('7'), findsOneWidget); // 見込み残
      expect(find.text('16'), findsOneWidget); // 見込み合計
    });

    testWidgets('支給量フォールバック時に注記が出る', (tester) async {
      final u = usage(available: 23, actual: 0, fallback: true, raw: 0);
      await pump(tester, MonthlyUsageStats(usage: u));
      expect(find.textContaining('設定値0→既定'), findsOneWidget);
    });

    testWidgets('超過時に見込み残へ超過日数の注記が出る', (tester) async {
      final u = usage(available: 10, actual: 8, planned: 4); // 12 → 超過2
      await pump(tester, MonthlyUsageStats(usage: u));
      expect(find.text('超過2日'), findsOneWidget);
    });
  });
}
