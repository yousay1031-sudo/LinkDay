import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:linkday_app/models/slot_info.dart';
import 'package:linkday_app/widgets/slot_status_panel.dart';

/// Day 15 ブラウザ検証: 出席画面の「LINE応募」パネルは一覧の上に固定表示される。
/// 欠席が多い日にパネルが画面を占有し、下のカード・操作ボタンが見えなくなる
/// ことを防ぐ（高さ上限＋内部スクロール。情報は省略しない）。
void main() {
  final now = DateTime(2026, 10, 5, 12, 0);
  String? nameOf(String id) => '児童$id';

  List<SlotInfo> slots(int n) => List.generate(
        n,
        (i) => SlotInfo.fromMap('2026-10-05_a$i', {
          'dateKey': '2026-10-05',
          'sourceAbsent': 'a$i',
          'status': i.isEven ? 'open' : 'filled',
          'expiresAt': DateTime(2026, 10, 5, 15, 0),
          'notifiedList': const [1, 2],
          if (i.isOdd)
            'claimedBy': {
              'customerId': 'c$i',
              'claimedAt': DateTime(2026, 10, 5, 9, 7),
            },
        }),
      );

  Future<void> pump(WidgetTester t, Size size, int n) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          SlotStatusPanel(slots: slots(n), now: now, nameOf: nameOf),
          Expanded(
              child: ListView(
                  key: const Key('list'),
                  children: [
                    for (var i = 0; i < 30; i++)
                      SizedBox(
                          height: 100,
                          child: Text('card$i', key: Key('card$i'))),
                  ])),
        ]),
      ),
    ));
    await t.pump();
  }

  testWidgets('欠席が多い日でも、パネルは画面の約3割まで・一覧に十分な高さが残る(390x844)',
      (t) async {
    await pump(t, const Size(390, 844), 12);
    final panel = t.getSize(find.byKey(const Key('slotStatusPanel')));
    expect(panel.height, lessThanOrEqualTo(844 * 0.35),
        reason: 'パネルが画面を占有している: ${panel.height}');
    expect(t.getSize(find.byKey(const Key('list'))).height,
        greaterThan(844 * 0.5));
  });

  testWidgets('低い画面(390x500)でも一覧が操作できる高さを保つ', (t) async {
    await pump(t, const Size(390, 500), 12);
    expect(t.getSize(find.byKey(const Key('list'))).height,
        greaterThan(500 * 0.5));
  });

  testWidgets('上限を超えても全ての枠にスクロールで到達できる（省略しない）', (t) async {
    await pump(t, const Size(390, 844), 12);
    final last = find.byKey(const ValueKey('slotRow_2026-10-05_a11'),
        skipOffstage: false);
    expect(last, findsOneWidget);
    await t.ensureVisible(last);
    await t.pump();
    final scroll = t.getRect(find.byKey(const Key('slotRowsScroll')));
    final r = t.getRect(last);
    expect(r.top, greaterThanOrEqualTo(scroll.top - 1));
    expect(r.bottom, lessThanOrEqualTo(scroll.bottom + 1),
        reason: '最後の枠がパネル内で表示できる');
    // 全 12 件が描画ツリーに存在する（省略されていない）
    for (var i = 0; i < 12; i++) {
      expect(find.byKey(ValueKey('slotRow_2026-10-05_a$i'),
              skipOffstage: false),
          findsOneWidget);
    }
  });

  testWidgets('枠が少ない場合は従来どおりの高さ（上限に達しない）', (t) async {
    await pump(t, const Size(390, 844), 2);
    final panel = t.getSize(find.byKey(const Key('slotStatusPanel')));
    expect(panel.height, lessThan(160));
  });
}
