import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:linkday_app/theme/app_motion.dart';
import 'package:linkday_app/utils/load_sequencer.dart';
import 'package:linkday_app/widgets/motion/skeleton.dart';
import 'package:linkday_app/widgets/motion/skeleton_gate.dart';

/// SkeletonGate のタイミング仕様と境界条件。
///
/// 通常モーション（フェードあり・パルスあり）で検証する。pumpAndSettle は
/// 骨格のパルス（無限ループ）が回っている間は使わず、明示的な pump(duration) で進める。
const _skeletonKey = Key('testSkeleton');
const _contentText = '内容';

Widget _skeleton() => const SkeletonPulse(
      child: SizedBox(key: _skeletonKey, width: 100, height: 40),
    );

/// 骨格が「見えている」か（猶予中は Opacity 0 で置かれているので区別する）
bool _skeletonVisible(WidgetTester tester) {
  final f = find.byKey(_skeletonKey);
  if (f.evaluate().isEmpty) return false;
  final opacities = tester.widgetList<Opacity>(
      find.ancestor(of: f, matching: find.byType(Opacity)));
  return opacities.every((o) => o.opacity > 0);
}

class _Harness extends StatefulWidget {
  final bool initialLoading;
  final bool reduced;
  const _Harness({this.initialLoading = true, this.reduced = false});

  @override
  State<_Harness> createState() => HarnessState();
}

class HarnessState extends State<_Harness> {
  late bool loading = widget.initialLoading;
  String? error;
  Object? contentKey = 'A';
  String content = _contentText;
  int builds = 0;
  int retries = 0;

  void set(
      {bool? loading,
      String? error,
      bool clearError = false,
      Object? key,
      String? content}) {
    setState(() {
      if (loading != null) this.loading = loading;
      if (clearError) this.error = null;
      if (error != null) this.error = error;
      if (key != null) contentKey = key;
      if (content != null) this.content = content;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: widget.reduced),
        child: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: SkeletonGate(
              loading: loading,
              errorMessage: error,
              contentKey: contentKey,
              onRetry: () {
                retries++;
                set(loading: true, clearError: true);
              },
              skeleton: _skeleton(),
              builder: (_) {
                builds++;
                return Text(content);
              },
            ),
          ),
        ),
      ),
    );
  }
}

HarnessState _state(WidgetTester tester) =>
    tester.state<HarnessState>(find.byType(_Harness));

void main() {
  test('採用したタイミング値（変更時はこのテストと報告を更新すること）', () {
    expect(AppMotion.skeletonShowDelay, const Duration(milliseconds: 120));
    expect(AppMotion.skeletonMinDisplay, const Duration(milliseconds: 250));
    // 骨格の最低表示はフェードイン（fast）より長いこと（出たと認識できる）
    expect(AppMotion.skeletonMinDisplay > AppMotion.fast, isTrue);
  });

  group('SkeletonGate: 即時完了', () {
    testWidgets('loading=false で生成 → 骨格を一切出さず即内容', (tester) async {
      await tester.pumpWidget(const _Harness(initialLoading: false));
      expect(find.text(_contentText), findsOneWidget);
      expect(find.byKey(_skeletonKey), findsNothing);
    });

    testWidgets('猶予(120ms)内に完了 → 骨格は一度も見えず、フェードなしで内容', (tester) async {
      await tester.pumpWidget(const _Harness());
      expect(_skeletonVisible(tester), isFalse, reason: '猶予中は骨格を見せない');
      expect(find.text(_contentText), findsNothing);

      await tester.pump(const Duration(milliseconds: 80));
      expect(_skeletonVisible(tester), isFalse);
      _state(tester).set(loading: false);
      await tester.pump();
      // 次のフレームで内容が完全不透明（フェード待ちゼロ）
      expect(find.text(_contentText), findsOneWidget);
      final fades = tester.widgetList<FadeTransition>(find.ancestor(
          of: find.text(_contentText), matching: find.byType(FadeTransition)));
      for (final f in fades) {
        expect(f.opacity.value, 1.0);
      }
      // 以後、骨格は出てこない（タイマー残存なし）
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(_skeletonKey), findsNothing);
    });
  });

  group('SkeletonGate: 遅い完了', () {
    testWidgets('120ms 経過で骨格表示、最低 250ms は残す', (tester) async {
      await tester.pumpWidget(const _Harness());
      await tester.pump(const Duration(milliseconds: 121));
      await tester.pump(AppMotion.fast); // フェードイン完了
      expect(_skeletonVisible(tester), isTrue);

      // 骨格表示（t=120ms）から約 151ms 後に完了 → 残り約 99ms は骨格のまま
      _state(tester).set(loading: false);
      await tester.pump();
      expect(find.text(_contentText), findsNothing, reason: '最低表示時間内');
      await tester.pump(const Duration(milliseconds: 95));
      expect(find.text(_contentText), findsNothing);
      await tester.pump(const Duration(milliseconds: 5)); // t=371 > 120+250
      expect(find.text(_contentText), findsOneWidget);
      await tester.pump(AppMotion.normal);
      expect(find.byKey(_skeletonKey), findsNothing, reason: 'クロスフェード後に骨格は外れる');
    });

    testWidgets('最低表示時間を過ぎてからの完了は追加待機ゼロ', (tester) async {
      await tester.pumpWidget(const _Harness());
      await tester.pump(const Duration(milliseconds: 121));
      await tester.pump(const Duration(milliseconds: 1000));
      _state(tester).set(loading: false);
      await tester.pump();
      expect(find.text(_contentText), findsOneWidget);
    });
  });

  group('SkeletonGate: エラーと再試行', () {
    testWidgets('エラーは最低表示時間を待たずに即表示', (tester) async {
      await tester.pumpWidget(const _Harness());
      await tester.pump(const Duration(milliseconds: 130)); // 骨格が出た直後
      _state(tester).set(loading: false, error: '読み込みに失敗しました');
      await tester.pump();
      expect(find.text('読み込みに失敗しました'), findsOneWidget);
      expect(find.byKey(const Key('errorRetryButton')), findsOneWidget);
      // エラーは「読込中」と区別される（骨格は退場中で操作対象外）
      await tester.pump(AppMotion.normal);
      await tester.pump(const Duration(milliseconds: 300)); // 残タイマー消化
      expect(find.byKey(_skeletonKey), findsNothing);
    });

    testWidgets('再試行 → 骨格の手順をやり直し、成功で内容', (tester) async {
      await tester.pumpWidget(const _Harness());
      _state(tester).set(loading: false, error: '失敗');
      await tester.pump();
      expect(find.text('失敗'), findsOneWidget);

      await tester.tap(find.byKey(const Key('errorRetryButton')));
      await tester.pump();
      expect(_state(tester).retries, 1);
      expect(find.text('失敗'), findsNothing);
      await tester.pump(const Duration(milliseconds: 121));
      await tester.pump(AppMotion.fast);
      expect(_skeletonVisible(tester), isTrue);

      await tester.pump(const Duration(milliseconds: 300));
      _state(tester).set(loading: false);
      await tester.pump();
      expect(find.text(_contentText), findsOneWidget);
    });
  });

  group('SkeletonGate: 再取得と対象変更', () {
    testWidgets('同じ contentKey の再取得では内容を残し、更新中バーだけ出す', (tester) async {
      await tester.pumpWidget(const _Harness(initialLoading: false));
      _state(tester).set(loading: true);
      await tester.pump();
      expect(find.text(_contentText), findsOneWidget, reason: '既存内容を残す');
      expect(find.byKey(_skeletonKey), findsNothing);

      await tester.pump(const Duration(milliseconds: 130));
      expect(find.byKey(const Key('skeletonGateRefreshing')), findsOneWidget);
      expect(find.text(_contentText), findsOneWidget);
      expect(find.byKey(_skeletonKey), findsNothing, reason: '全面骨格に戻さない');

      _state(tester).set(loading: false, content: '更新後');
      await tester.pump();
      expect(find.text('更新後'), findsOneWidget);
      expect(find.byKey(const Key('skeletonGateRefreshing')), findsNothing);
    });

    testWidgets('短い再取得では更新中バーも出さない（点滅防止）', (tester) async {
      await tester.pumpWidget(const _Harness(initialLoading: false));
      _state(tester).set(loading: true);
      await tester.pump(const Duration(milliseconds: 50));
      _state(tester).set(loading: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('skeletonGateRefreshing')), findsNothing);
    });

    testWidgets('contentKey が変わったら旧対象の内容を見せない', (tester) async {
      await tester.pumpWidget(const _Harness(initialLoading: false));
      expect(find.text(_contentText), findsOneWidget);
      _state(tester).set(loading: true, key: 'B');
      await tester.pump();
      // 次のフレームで即座に外れる（フェードアウトで残さない）
      expect(find.text(_contentText), findsNothing,
          reason: '旧日付の内容を新日付として出さない');
      await tester.pump(const Duration(milliseconds: 130));
      expect(_skeletonVisible(tester), isTrue);
    });

    testWidgets('対象変更中に古い非同期結果が届いても無視される（LoadSequencer）', (tester) async {
      await tester.pumpWidget(const _Harness(initialLoading: false));
      final st = _state(tester);
      final seq = LoadSequencer();
      final slowA = Completer<String>();
      final fastB = Completer<String>();

      Future<void> load(Object key, Completer<String> c) async {
        final token = seq.begin();
        st.set(loading: true, key: key);
        final r = await c.future;
        if (!seq.isCurrent(token)) return; // 古い結果は捨てる
        st.set(loading: false, content: r);
      }

      unawaited(load('A2', slowA));
      await tester.pump(const Duration(milliseconds: 10));
      unawaited(load('B', fastB));
      fastB.complete('Bの内容');
      await tester.pump();
      await tester.pump(AppMotion.normal);
      expect(find.text('Bの内容'), findsOneWidget);

      slowA.complete('Aの内容（古い）');
      await tester.pump();
      await tester.pump(AppMotion.normal);
      expect(find.text('Aの内容（古い）'), findsNothing);
      expect(find.text('Bの内容'), findsOneWidget);
    });
  });

  group('SkeletonGate: dispose とアクセシビリティ', () {
    testWidgets('骨格表示中・猶予中に dispose してもタイマーや例外が残らない', (tester) async {
      await tester.pumpWidget(const _Harness());
      await tester.pump(const Duration(milliseconds: 50)); // 猶予タイマー稼働中
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const _Harness());
      await tester.pump(const Duration(milliseconds: 130)); // 最低表示タイマー稼働中
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      // テスト終了時に保留タイマーがあれば flutter_test が失敗させる
    });

    testWidgets('猶予中の見えない骨格は Ticker を止めている', (tester) async {
      await tester.pumpWidget(const _Harness());
      final tm = tester.widget<TickerMode>(find
          .ancestor(
              of: find.byKey(_skeletonKey), matching: find.byType(TickerMode))
          .first);
      expect(tm.enabled, isFalse);
    });

    testWidgets('骨格→内容の切替中、旧表示（骨格）は操作・読み上げの対象外', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const _Harness());
      await tester.pump(const Duration(milliseconds: 121));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.bySemanticsLabel('読み込み中'), findsOneWidget);
      _state(tester).set(loading: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50)); // クロスフェード途中
      expect(find.byKey(_skeletonKey), findsOneWidget, reason: '退場中');
      expect(find.bySemanticsLabel('読み込み中'), findsNothing,
          reason: '退場中の骨格は読み上げない');
      handle.dispose();
    });
  });

  group('SkeletonGate: reduce-motion', () {
    testWidgets('フェードなしで即切替・パルス停止（タイミング規則は同じ）', (tester) async {
      await tester.pumpWidget(const _Harness(reduced: true));
      await tester.pump(const Duration(milliseconds: 121));
      await tester.pump();
      expect(_skeletonVisible(tester), isTrue);
      // パルスが止まっている: 何もしなくても次のフレームが要求されない
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.pump(const Duration(milliseconds: 300));
      _state(tester).set(loading: false);
      await tester.pump();
      expect(find.text(_contentText), findsOneWidget);
      expect(find.byKey(_skeletonKey), findsNothing, reason: 'クロスフェードなし');
    });
  });
}
