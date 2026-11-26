import 'kana_util.dart';

/// 児童を探す検索（氏名・ふりがなの一部で絞り込む）。
///
/// 空白（全角・半角）は無視する。ふりがなは、ひらがな・カタカナ・半角カナのどれで
/// 打っても同じに扱う（保存されているふりがなはカタカナ）。
class NameSearch {
  NameSearch._();

  static String _norm(String s) =>
      KanaUtil.hiraganaToKatakana(KanaUtil.normalizeKana(s))
          .replaceAll(RegExp(r'[\s　]'), '')
          .toLowerCase();

  /// [query] が空なら常に true
  static bool matches(String query, {required String name, String? kana}) {
    final q = _norm(query);
    if (q.isEmpty) return true;
    if (_norm(name).contains(q)) return true;
    return kana != null && _norm(kana).contains(q);
  }
}
