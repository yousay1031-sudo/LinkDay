// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// アプリの表示言語（日本語に固定）。
///
/// 日付・時刻の選択画面、戻るボタンの読み上げ、コピー／貼り付けのメニューなど
/// Flutter の標準部品の文言と日付の書式を日本語にする。これが無いと標準部品は
/// 英語（Sun, Nov 22 / November 2026 など）になる。
class AppLocale {
  AppLocale._();

  static const Locale locale = Locale('ja', 'JP');

  static const List<Locale> supportedLocales = [locale];

  /// Flutter 3.50 で material.dart と同じく material_ui への移行予定として非推奨
  /// （アプリ全体が material.dart のままなので、それに揃える）
  // ignore: deprecated_member_use
  static const List<LocalizationsDelegate<dynamic>> delegates =
      // ignore: deprecated_member_use
      GlobalMaterialLocalizations.delegates;
}
