import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// 検証構成限定の「読込遅延」「読込失敗」注入。
///
/// 呼び出し側は必ず `if (VerifyConfig.enabled)` で囲む（通常ビルドでは
/// コンパイル時に消える）。値はブラウザの localStorage から呼び出しの都度
/// 読むため、画面を開く前後に puppeteer 等で切り替えられる。
///
///  - `flutter.verify_delay_ms` : 数値(ミリ秒)。各フックでこの時間待つ
///  - `flutter.verify_faults`   : カンマ区切りの名前。含まれるフックは例外を投げる
///
/// 設定例（ブラウザのコンソール）:
/// ```js
/// localStorage.setItem('flutter.verify_delay_ms', '2500');
/// localStorage.setItem('flutter.verify_faults', JSON.stringify('attendance'));
/// localStorage.removeItem('flutter.verify_faults'); // 「再試行」で成功させる
/// ```
class VerifyFaults {
  VerifyFaults._();

  static const String delayKey = 'verify_delay_ms';
  static const String faultsKey = 'verify_faults';

  /// フック名
  static const String attendance = 'attendance';
  static const String usage = 'usage';
  static const String weekly = 'weekly';
  static const String transport = 'transport';
  static const String settings = 'settings';

  /// 名前付きフック。遅延 → 故障の順に適用する。
  static Future<void> apply(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final delay = prefs.getInt(delayKey) ?? 0;
    if (delay > 0) {
      await Future<void>.delayed(Duration(milliseconds: delay));
      // 遅延中に切り替えられた故障設定を反映するため、読み直す
      await prefs.reload();
    }
    final faults = parseFaults(prefs.getString(faultsKey));
    if (faults.contains(name)) {
      throw StateError('[verify] 読込失敗を注入しました: $name');
    }
  }

  /// "a, b" → {a, b}
  static Set<String> parseFaults(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }
}
