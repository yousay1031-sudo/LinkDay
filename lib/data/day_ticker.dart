import 'dart:async';

import 'package:flutter/widgets.dart';

/// 日付が変わったことを知らせる（画面を開いたまま 0 時をまたいだとき・
/// アプリに戻ったとき）。期限の知らせなど、今日の日付で計算するものが聞く。
class DayTicker extends ChangeNotifier with WidgetsBindingObserver {
  DayTicker._();
  static final DayTicker instance = DayTicker._();

  /// テスト用: 今の時刻を差し替える
  DateTime Function() now = DateTime.now;

  Timer? _timer;
  DateTime? _day;
  bool _started = false;

  /// 今日（0 時）
  DateTime get today {
    final n = now();
    return DateTime(n.year, n.month, n.day);
  }

  /// 聞く側が最初に呼ぶ（何度呼んでもよい）
  void ensureStarted() {
    if (_started) return;
    _started = true;
    _day = today;
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final n = now();
    final next = DateTime(n.year, n.month, n.day + 1);
    // 0 時を少し過ぎてから確かめる（端末の時計のずれを吸収）。
    // 一番外側の zone で作る: 画面のテスト（時計を進めない偽の zone）で、翌日まで
    // 残るタイマーが「終わっていないタイマー」として扱われないように。動きは同じ。
    _timer = Zone.root
        .createTimer(next.difference(n) + const Duration(seconds: 2), () {
      check();
      _schedule();
    });
  }

  /// 日付が変わっていれば知らせる
  void check() {
    final t = today;
    if (_day != t) {
      _day = t;
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      check();
      _schedule();
    }
  }

  @visibleForTesting
  void debugReset() {
    _timer?.cancel();
    _timer = null;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _started = false;
    _day = null;
    now = DateTime.now;
  }
}
