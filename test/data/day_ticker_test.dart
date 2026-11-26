import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/day_ticker.dart';

/// ステップ3 段階5: 画面を開いたまま 0 時をまたいだら知らせる
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(DayTicker.instance.debugReset);

  test('0 時を過ぎるとタイマーで知らせる（日付が変わらなければ知らせない）', () async {
    final start = DateTime.now();
    // 「今」を 0 時の 0.5 秒前にする（タイマーは 0 時の 2 秒後に確かめる）
    final offset = DateTime(2026, 9, 17).difference(start) -
        const Duration(milliseconds: 500);
    DayTicker.instance.now = () => DateTime.now().add(offset);
    var calls = 0;
    void l() => calls++;
    DayTicker.instance.addListener(l);
    addTearDown(() => DayTicker.instance.removeListener(l));
    DayTicker.instance.ensureStarted();
    expect(DayTicker.instance.today, DateTime(2026, 9, 16));
    DayTicker.instance.check();
    expect(calls, 0);
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(calls, 1);
    expect(DayTicker.instance.today, DateTime(2026, 9, 17));
  });
}
