import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// アプリの版（pubspec.yaml の `version:`）。手で書かない。
///
/// `flutter build web`（`flutter run` も）は pubspec.yaml の version から
/// `version.json`（{"version":"1.0.0","build_number":"6",...}）を自動で作り、
/// index.html と同じ場所に置く。ここではそれを同じ配信元から読む（外部への通信ではない）。
/// URL はハッシュ形式（既定）なので、ページの URL を基準に `version.json` を解決すれば
/// index.html と同じ場所になる。
///
/// Web 以外・読めないときは null（画面では「（不明）」と出す）。
class AppVersion {
  AppVersion._();

  static Future<String?>? _cached;

  /// テスト用: version.json を返す通信（設定すると Web 以外でも読む）
  @visibleForTesting
  static http.Client? debugClient;

  /// 版を読む（一度読んだら同じ結果を使う）
  static Future<String?> load() => _cached ??= _load();

  @visibleForTesting
  static void debugReset() {
    _cached = null;
    debugClient = null;
  }

  static Future<String?> _load() async {
    final client = debugClient;
    if (client == null && !kIsWeb) return null;
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(Uri.base.resolve('version.json'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body);
      return j is Map ? label(j['version'], j['build_number']) : null;
    } catch (e) {
      debugPrint('[AppVersion] version.json を読めませんでした: $e');
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// pubspec.yaml と同じ書き方（1.0.0+6）にする。版が無ければ null。
  static String? label(Object? version, Object? buildNumber) {
    if (version is! String || version.isEmpty) return null;
    if (buildNumber is String && buildNumber.isNotEmpty) {
      return '$version+$buildNumber';
    }
    return version;
  }
}
