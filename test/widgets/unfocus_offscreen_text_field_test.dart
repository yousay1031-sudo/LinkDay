// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/widgets/unfocus_offscreen_text_field.dart';

/// UnfocusOffscreenTextField: 入力中の欄がスクロールで画面の外へ出たらフォーカスを外す。
/// 画面の外から戻ってくるスクロール（キーボードが開いて欄を見える所まで動かすなど）では外さない。
void main() {
  final ctrls = List.generate(12, (i) => TextEditingController());
  final nodes = List.generate(12, (i) => FocusNode());

  Widget app() => MaterialApp(
        home: Scaffold(
          body: UnfocusOffscreenTextField(
            child: SingleChildScrollView(
              child: Column(children: [
                for (var i = 0; i < 12; i++)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: TextField(
                      key: Key('f$i'),
                      controller: ctrls[i],
                      focusNode: nodes[i],
                    ),
                  ),
              ]),
            ),
          ),
        ),
      );

  setUp(() {
    for (final c in ctrls) {
      c.clear();
    }
  });

  testWidgets('画面の外へ出るスクロールでフォーカスを外す（入力は残る）', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 300));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('f0')));
    await t.enterText(find.byKey(const Key('f0')), 'あいう');
    expect(nodes[0].hasFocus, isTrue);
    await t.drag(find.byType(SingleChildScrollView), const Offset(0, -500));
    await t.pumpAndSettle();
    expect(nodes[0].hasFocus, isFalse);
    expect(ctrls[0].text, 'あいう');
  });

  testWidgets('表示範囲の中でのスクロールではフォーカスを外さない', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 300));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('f1')));
    await t.drag(find.byType(SingleChildScrollView), const Offset(0, -30));
    await t.pumpAndSettle();
    expect(nodes[1].hasFocus, isTrue);
  });

  testWidgets('隠れた入力中の欄を、見える所までアニメーションで動かすときはフォーカスを外さない', (t) async {
    // 実機でキーボードが開いたときと同じ形: 欄が表示範囲の外（下）に隠れた後、
    // 欄を見せるためのスクロールが少しずつ進む
    t.view.physicalSize = const Size(400, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(app());
    final f = find.byKey(const Key('f6'));
    await t.tap(f);
    await t.pump();
    expect(nodes[6].hasFocus, isTrue);
    // 表示範囲が縮んで欄が完全に隠れる（スクロールは起きない）
    t.view.physicalSize = const Size(400, 300);
    await t.pump();
    expect(t.getRect(f).top, greaterThanOrEqualTo(300));
    expect(nodes[6].hasFocus, isTrue);
    // 欄を見せるスクロール（アニメーション）
    Scrollable.ensureVisible(nodes[6].context!,
        duration: const Duration(milliseconds: 300));
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 16)); // 実機と同じ細かさで進める
    }
    expect(nodes[6].hasFocus, isTrue, reason: '欄を見せる途中でキーボードを閉じてはいけない');
    expect(t.getRect(f).bottom, lessThanOrEqualTo(300));
  });

  testWidgets('キーボードが開いて欄が隠れ、見える所まで動くときはフォーカスを外さない', (t) async {
    t.view.physicalSize = const Size(400, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(app());
    // 画面の下の方の欄を選ぶ
    final f = find.byKey(const Key('f6'));
    expect(t.getRect(f).bottom, lessThan(600));
    expect(t.getRect(f).top, greaterThan(350));
    await t.tap(f);
    await t.pump();
    expect(nodes[6].hasFocus, isTrue);
    // キーボードが開く（下 300 が隠れる → 欄は表示範囲の完全に外）
    t.view.viewInsets = const FakeViewPadding(bottom: 300);
    await t.pumpAndSettle();
    expect(nodes[6].hasFocus, isTrue, reason: 'キーボードを開いた直後に閉じてはいけない');
    expect(t.getRect(f).bottom, lessThanOrEqualTo(300), reason: '欄が見える所まで動く');
  });
}
