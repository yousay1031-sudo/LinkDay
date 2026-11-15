import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:linkday_app/screens/weekly_schedule_screen.dart';
import 'package:linkday_app/theme/app_theme.dart';

/// Day 15 ブラウザ検証: 390px の週間画面で曜日ストリップの日付が
/// 「11/1」「6」のように折り返していた。1 行で表示されることを固定する。
void main() {
  Future<void> pump(WidgetTester t, double width, DateTime weekStart) async {
    await t.binding.setSurfaceSize(Size(width, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: _Host(weekStart: weekStart),
    ));
    await t.pump();
  }

  // 2 桁月 × 2 桁日（最長）を含む週: 11/10(月)〜11/16(日)
  final longWeek = DateTime(2025, 11, 10);

  for (final w in [360.0, 390.0, 1280.0]) {
    testWidgets('幅${w.toInt()}px: 全7日の日付が1行で、数字も欠けない', (t) async {
      await pump(t, w, longWeek);
      for (var i = 0; i < 7; i++) {
        final d = longWeek.add(Duration(days: i));
        final f = find.byKey(Key('weeklyDayDate$i'));
        expect(find.descendant(of: f, matching: find.byType(Text)),
            findsNothing); // Key は Text 自身
        final text = t.widget<Text>(f);
        expect(text.data, '${d.month}/${d.day}', reason: '日付の文字列は欠落しない');
        final style = DefaultTextStyle.of(t.element(f))
            .style
            .merge(text.style);
        final h = t.getSize(f).height;
        expect(h, lessThanOrEqualTo(style.fontSize! * (style.height ?? 1.6) + 1),
            reason: '${text.data} が複数行に折り返している (height=$h)');
        // タブのセル内に収まっている（クリップ・はみ出しなし）
        final tabRect = t.getRect(find.byType(Tab).at(i));
        final textRect = t.getRect(f);
        expect(textRect.left, greaterThanOrEqualTo(tabRect.left));
        expect(textRect.right, lessThanOrEqualTo(tabRect.right));
      }
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('人数バッジが付いても日付は1行のまま（390px）', (t) async {
    await pump(t, 390, longWeek);
    expect(find.text('12'), findsOneWidget);
    final f = find.byKey(const Key('weeklyDayDate1'));
    expect(t.getSize(f).height, lessThan(20));
  });
}

class _Host extends StatefulWidget {
  final DateTime weekStart;
  const _Host({required this.weekStart});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final TabController c = TabController(length: 7, vsync: this);
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: WeeklyDayTabBar(
          controller: c,
          weekStart: widget.weekStart,
          countForDay: (d) => d == 2 ? 12 : (d == 4 ? 3 : 0),
        ),
      );
}
