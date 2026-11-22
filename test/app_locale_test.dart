// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/app_locale.dart';

/// 手直し2: 日付・時刻の選択画面などの標準部品を日本語にする（アプリと同じ設定で確かめる）
Widget _app(Widget Function(BuildContext) child) => MaterialApp(
      locale: AppLocale.locale,
      supportedLocales: AppLocale.supportedLocales,
      localizationsDelegates: AppLocale.delegates,
      home: Scaffold(body: Builder(builder: child)),
    );

void main() {
  testWidgets('日付の選択画面が日本語（年月・曜日・ボタン）', (t) async {
    await t.pumpWidget(_app((context) => TextButton(
          onPressed: () => showDatePicker(
            context: context,
            initialDate: DateTime(2026, 11, 22),
            firstDate: DateTime(2020),
            lastDate: DateTime(2030),
          ),
          child: const Text('開く'),
        )));
    await t.tap(find.text('開く'));
    await t.pumpAndSettle();
    expect(find.textContaining('2026年11月'), findsWidgets);
    expect(find.textContaining('November'), findsNothing);
    expect(find.textContaining('Sun'), findsNothing);
    expect(find.text('キャンセル'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    // 曜日の見出し（日〜土）
    for (final d in ['日', '月', '火', '水', '木', '金', '土']) {
      expect(find.text(d), findsWidgets, reason: '曜日 $d');
    }
  });

  testWidgets('週の始まりは日曜日（英語の既定と同じ。変わらない）', (t) async {
    late int ja;
    await t.pumpWidget(_app((context) {
      ja = MaterialLocalizations.of(context).firstDayOfWeekIndex;
      return const SizedBox();
    }));
    late int en;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      en = MaterialLocalizations.of(context).firstDayOfWeekIndex;
      return const SizedBox();
    })));
    expect(ja, 0, reason: '0 = 日曜日');
    expect(en, 0);
  });

  testWidgets('時刻の選択画面が日本語', (t) async {
    await t.pumpWidget(_app((context) => TextButton(
          onPressed: () => showTimePicker(
            context: context,
            initialTime: const TimeOfDay(hour: 10, minute: 0),
          ),
          child: const Text('開く'),
        )));
    await t.tap(find.text('開く'));
    await t.pumpAndSettle();
    expect(find.text('キャンセル'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.textContaining('Select time'), findsNothing);
  });

  testWidgets('戻るボタンの読み上げ・ツールチップが日本語', (t) async {
    late String back;
    await t.pumpWidget(_app((context) {
      back = MaterialLocalizations.of(context).backButtonTooltip;
      return const SizedBox();
    }));
    expect(back, '戻る');
  });
}
