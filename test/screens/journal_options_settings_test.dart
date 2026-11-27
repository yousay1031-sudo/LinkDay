@Timeout(Duration(seconds: 90))
library;

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:linkday_app/widgets/journal_activity_options_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ3 段階2: 設定の「業務日誌の内容の選択肢」
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(FakeBackend.detach);

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return v;
      })) as T;

  Future<List<String>?> stored() async {
    final b = FakeBackend.current;
    final d = (await b.db
            .collection(FsPaths.facilities)
            .doc(b.facilityId)
            .collection(FsPaths.settings)
            .doc(FsPaths.settingsDocId)
            .get())
        .data();
    final v = d?['journalActivityOptions'];
    return v is List ? v.cast<String>() : null;
  }

  Future<void> open(WidgetTester t) async {
    await io(t, FakeBackend.attachWithStaff);
    await t.binding.setSurfaceSize(const Size(820, 1400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: JournalActivityOptionsSection()))));
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  testWidgets('初期値の 11 個が並び、足す・消す・並べ替えがその場で保存される', (t) async {
    await open(t);
    expect(find.byKey(const Key('journalOption_外遊び')), findsOneWidget);
    expect(find.byKey(const Key('journalOption_個別の活動')), findsOneWidget);

    await t.enterText(find.byKey(const Key('journalOptionInput')), ' 読み聞かせ ');
    await tap(t, find.byKey(const Key('journalOptionAdd')));
    expect((await io(t, stored))!.last, '読み聞かせ');

    // 同じ名前は足せない
    await t.enterText(find.byKey(const Key('journalOptionInput')), '外遊び');
    await tap(t, find.byKey(const Key('journalOptionAdd')));
    expect(find.text('「外遊び」はもうあります'), findsOneWidget);

    // 消す（確かめてから）
    await tap(t, find.byKey(const Key('journalOptionRemove_調理')));
    expect(find.text('「調理」を消しますか'), findsOneWidget);
    await tap(t, find.text('消す'));
    expect((await io(t, stored))!.contains('調理'), isFalse);

    // 並べ替え（2 番目を上へ）
    await tap(
        t,
        find.descendant(
            of: find.byKey(const Key('journalOption_室内遊び')),
            matching: find.byTooltip('上へ')));
    final s = (await io(t, stored))!;
    expect(s.take(2), ['室内遊び', '外遊び']);
    expect(SettingsService.instance.getSettings().journalActivityOptions, s);
  });

  // アプリのテーマ（ボタンの最小サイズが横幅いっぱい）でも「足す」が描かれて押せる
  for (final w in const [1280.0, 820.0, 530.0]) {
    testWidgets('幅 ${w.toInt()}・アプリのテーマ: 「足す」が入力欄の右に見えて押せる', (t) async {
      await io(t, FakeBackend.attachWithStaff);
      await t.binding.setSurfaceSize(Size(w, 1400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme
              .copyWith(visualDensity: VisualDensity.compact),
          home: const Scaffold(
              body: SingleChildScrollView(
                  child: JournalActivityOptionsSection()))));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '描けないボタンがない');
      final add = find.byKey(const Key('journalOptionAdd'));
      expect(add.hitTestable(), findsOneWidget);
      final r = t.getRect(add);
      final input = t.getRect(find.byKey(const Key('journalOptionInput')));
      expect(r.height, greaterThanOrEqualTo(48));
      expect(r.width, greaterThanOrEqualTo(48));
      expect(r.left, greaterThanOrEqualTo(input.right));
      expect(r.right, lessThanOrEqualTo(w));
      await t.enterText(find.byKey(const Key('journalOptionInput')), '読み聞かせ');
      await tap(t, add);
      expect((await io(t, stored))!.last, '読み聞かせ');
    });
  }

  testWidgets('押す場所は高さ 48 以上', (t) async {
    await open(t);
    expect(t.getSize(find.byKey(const Key('journalOption_外遊び'))).height,
        greaterThanOrEqualTo(48));
    expect(t.getSize(find.byKey(const Key('journalOptionAdd'))).height,
        greaterThanOrEqualTo(48));
    expect(t.takeException(), isNull);
  });
}
