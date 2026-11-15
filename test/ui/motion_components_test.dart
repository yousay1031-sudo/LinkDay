import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/widgets/motion/app_spinner.dart';
import 'package:linkday_app/widgets/motion/press_scale.dart';
import 'package:linkday_app/widgets/motion/skeleton.dart';
import 'package:linkday_app/widgets/motion/staggered.dart';
import 'package:linkday_app/widgets/motion/state_switcher.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(body: child),
      ),
    );

/// total 件のリストを StaggerScope 内に作る（全件を build させるため Column）
Widget _list(int total, {int build = 12}) => StaggerScope(
      child: SingleChildScrollView(
        child: Column(children: [
          for (int i = 0; i < build; i++)
            StaggeredItem(
              key: ValueKey('item$i'),
              index: i,
              total: total,
              child: SizedBox(height: 10, child: Text('項目$i')),
            ),
        ]),
      ),
    );

bool _animates(WidgetTester t, int i) => t
    .state<State<StaggeredItem>>(find.byKey(ValueKey('item$i')))
    // ignore: invalid_use_of_visible_for_testing_member
    .let((s) => (s as dynamic).debugAnimates as bool);

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// フレームを細かく進める（AnimationController はフレームごとに進むため）
Future<void> _advance(WidgetTester t, Duration d) async {
  final n = d.inMilliseconds ~/ 16 + 1;
  for (int i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('StaggeredItem', () {
    test('50 件以下は全件、51 件以上は先頭 10 件のみ演出', () {
      expect(AppMotion.shouldStagger(49, 50), isTrue);
      expect(AppMotion.shouldStagger(10, 51), isFalse);
      expect(AppMotion.shouldStagger(9, 51), isTrue);
    });

    test('入場シーケンス合計は 600ms 以内', () {
      expect(
          AppMotion.staggerTotal <= const Duration(milliseconds: 600), isTrue);
    });

    testWidgets('50 件: 11 件目も演出 / 51 件: 11 件目は即時表示', (t) async {
      await t.pumpWidget(_app(_list(50)));
      expect(_animates(t, 10), isTrue);
      await t.pump(const Duration(seconds: 1));
      await t.pumpWidget(_app(const SizedBox()));
      await t.pumpWidget(_app(_list(51)));
      expect(_animates(t, 9), isTrue);
      expect(_animates(t, 10), isFalse);
      expect(_animates(t, 11), isFalse);
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('遅延は index 9 で頭打ちし、600ms 以内に全件不透明', (t) async {
      await t.pumpWidget(_app(_list(12)));
      await _advance(
          t, AppMotion.staggerTotal + const Duration(milliseconds: 20));
      for (final o in t.widgetList<Opacity>(find.byType(Opacity))) {
        expect(o.opacity, 1.0);
      }
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'ticker が残らない');
    });

    testWidgets('通常の再ビルドでは再演出しない', (t) async {
      await t.pumpWidget(_app(_list(5)));
      await _advance(t, const Duration(milliseconds: 700));
      await t.pumpWidget(_app(_list(5))); // 同じ木で再ビルド
      await t.pump();
      expect(find.byType(Opacity), findsNothing, reason: '完了後は素の子');
      expect(t.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('窓が閉じた後に現れた要素は演出しない', (t) async {
      await t.pumpWidget(_app(_list(30, build: 3)));
      await t.pump(const Duration(seconds: 1));
      await t.pumpWidget(_app(_list(30, build: 6)));
      expect(_animates(t, 4), isFalse);
    });

    testWidgets('reduce-motion では演出しない', (t) async {
      await t.pumpWidget(_app(_list(5), reduced: true));
      expect(_animates(t, 0), isFalse);
      expect(find.byType(Opacity), findsNothing, reason: '最初から最終状態');
    });
  });

  group('reduce-motion で無限アニメ停止', () {
    testWidgets('SkeletonPulse・AppSpinner は通常時ループ、reduce で静止', (t) async {
      await t.pumpWidget(_app(const Column(children: [
        SkeletonPulse(child: SizedBox(width: 10, height: 10)),
        SizedBox(width: 20, height: 20, child: AppSpinner()),
      ])));
      await t.pump(const Duration(milliseconds: 100));
      expect(t.binding.hasScheduledFrame, isTrue, reason: '通常モーションでは動く');

      await t.pumpWidget(_app(
          const Column(children: [
            SkeletonPulse(child: SizedBox(width: 10, height: 10)),
            SizedBox(width: 20, height: 20, child: AppSpinner()),
          ]),
          reduced: true));
      await t.pump();
      expect(
          t
              .widget<CircularProgressIndicator>(
                  find.byType(CircularProgressIndicator))
              .value,
          AppSpinner.staticValue);
      await t.pump(const Duration(milliseconds: 100));
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'reduce で全停止');
    });
  });

  group('StateSwitcher / AnimatedCount', () {
    Widget sw(String name, {bool reduced = false}) => _app(
          StateSwitcher(stateKey: name, child: Text('確定: $name')),
          reduced: reduced,
        );

    testWidgets('切替途中でも確定者名が読める（不透明度 0.7 以上）・旧表示は即消去', (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(sw('山田'));
      await t.pumpWidget(sw('佐藤'));
      for (final ms in [0, 16, 100, 200]) {
        await t.pump(Duration(milliseconds: ms == 0 ? 0 : 16));
        expect(find.text('確定: 佐藤'), findsOneWidget);
        expect(find.text('確定: 山田'), findsNothing, reason: '旧表示を残さない');
        final fades = t.widgetList<FadeTransition>(find.ancestor(
            of: find.text('確定: 佐藤'), matching: find.byType(FadeTransition)));
        for (final f in fades) {
          expect(f.opacity.value >= 0.7, isTrue);
        }
        expect(find.bySemanticsLabel(RegExp('確定:')), findsOneWidget,
            reason: '読み上げ重複なし');
      }
      await t.pump(AppMotion.normal);
      h.dispose();
    });

    testWidgets('reduce-motion では即時置換', (t) async {
      await t.pumpWidget(sw('山田', reduced: true));
      await t.pumpWidget(sw('佐藤', reduced: true));
      expect(find.text('確定: 佐藤'), findsOneWidget);
      expect(t.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('AnimatedCount は途中値を作らず最終値のみ', (t) async {
      await t.pumpWidget(_app(const AnimatedCount(value: 3)));
      await t.pumpWidget(_app(const AnimatedCount(value: 12)));
      for (int i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
        final texts =
            t.widgetList<Text>(find.byType(Text)).map((e) => e.data).toList();
        expect(texts, ['12']);
      }
    });
  });

  group('PressableScale', () {
    int taps = 0;
    Widget btn({bool enabled = true, bool reduced = false}) => _app(
          Center(
            child: PressableScale(
              key: const Key('ps'),
              enabled: enabled,
              child: ElevatedButton(
                onPressed: enabled ? () => taps++ : null,
                child: const Text('押す'),
              ),
            ),
          ),
          reduced: reduced,
        );
    bool pressed(WidgetTester t) =>
        // ignore: invalid_use_of_visible_for_testing_member
        (t.state(find.byKey(const Key('ps'))) as dynamic).debugIsPressed
            as bool;
    double scale(WidgetTester t) =>
        t.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

    setUp(() => taps = 0);

    testWidgets('タップ: 押下中だけ縮み、離すと戻り、タップは届く', (t) async {
      await t.pumpWidget(btn());
      final g = await t.startGesture(t.getCenter(find.text('押す')));
      await t.pump();
      expect(scale(t), AppMotion.cardPressedScale);
      await g.up();
      await t.pump(AppMotion.fast);
      expect(scale(t), 1.0);
      expect(taps, 1);
    });

    testWidgets('ポインターキャンセル・ドラッグ開始で押下が残らない', (t) async {
      await t.pumpWidget(btn());
      final g = await t.startGesture(t.getCenter(find.text('押す')));
      await t.pump();
      await g.cancel();
      await t.pump();
      expect(pressed(t), isFalse);

      final g2 = await t.startGesture(t.getCenter(find.text('押す')));
      await t.pump();
      await g2.moveBy(const Offset(0, 40));
      await t.pump();
      expect(pressed(t), isFalse, reason: 'スクロール開始で解除');
      await g2.up();
    });

    testWidgets('押下中に disabled になっても縮んだまま残らない', (t) async {
      await t.pumpWidget(btn());
      final g = await t.startGesture(t.getCenter(find.text('押す')));
      await t.pump();
      await t.pumpWidget(btn(enabled: false));
      expect(pressed(t), isFalse);
      expect(scale(t), 1.0);
      await g.up();
      await t.pumpWidget(btn(enabled: false));
      await t.tap(find.text('押す'));
      await t.pump();
      expect(scale(t), 1.0);
      expect(taps, 0);
    });

    testWidgets('キーボード（Tab→Enter / Space）で操作できる', (t) async {
      await t.pumpWidget(btn());
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pump(const Duration(milliseconds: 300));
      expect(taps, 2);
      expect(scale(t), 1.0);
    });

    testWidgets('reduce-motion では縮めない（タップは届く）', (t) async {
      await t.pumpWidget(btn(reduced: true));
      final g = await t.startGesture(t.getCenter(find.text('押す')));
      await t.pump();
      expect(scale(t), 1.0);
      await g.up();
      expect(taps, 1);
    });
  });
}
