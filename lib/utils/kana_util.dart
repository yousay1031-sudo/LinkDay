/// ふりがな変換ユーティリティ
/// ひらがな ↔ カタカナ変換、半角カナ → 全角カナ変換などを提供する
class KanaUtil {
  KanaUtil._();

  // ── Unicode 範囲定数 ──────────────────────────────────────────────
  static const int _hiraganaStart = 0x3041; // ぁ
  static const int _hiraganaEnd = 0x3096;   // ゖ
  static const int _katakanaStart = 0x30A1; // ァ
  static const int _hiraganaToKatakanaDiff = 0x60; // カタカナ = ひらがな + 0x60

  // 半角カナ → 全角カナ変換マップ
  static const Map<String, String> _halfToFullKana = {
    'ｦ': 'ヲ', 'ｧ': 'ァ', 'ｨ': 'ィ', 'ｩ': 'ゥ', 'ｪ': 'ェ', 'ｫ': 'ォ',
    'ｬ': 'ャ', 'ｭ': 'ュ', 'ｮ': 'ョ', 'ｯ': 'ッ', 'ｰ': 'ー',
    'ｱ': 'ア', 'ｲ': 'イ', 'ｳ': 'ウ', 'ｴ': 'エ', 'ｵ': 'オ',
    'ｶ': 'カ', 'ｷ': 'キ', 'ｸ': 'ク', 'ｹ': 'ケ', 'ｺ': 'コ',
    'ｻ': 'サ', 'ｼ': 'シ', 'ｽ': 'ス', 'ｾ': 'セ', 'ｿ': 'ソ',
    'ﾀ': 'タ', 'ﾁ': 'チ', 'ﾂ': 'ツ', 'ﾃ': 'テ', 'ﾄ': 'ト',
    'ﾅ': 'ナ', 'ﾆ': 'ニ', 'ﾇ': 'ヌ', 'ﾈ': 'ネ', 'ﾉ': 'ノ',
    'ﾊ': 'ハ', 'ﾋ': 'ヒ', 'ﾌ': 'フ', 'ﾍ': 'ヘ', 'ﾎ': 'ホ',
    'ﾏ': 'マ', 'ﾐ': 'ミ', 'ﾑ': 'ム', 'ﾒ': 'メ', 'ﾓ': 'モ',
    'ﾔ': 'ヤ', 'ﾕ': 'ユ', 'ﾖ': 'ヨ',
    'ﾗ': 'ラ', 'ﾘ': 'リ', 'ﾙ': 'ル', 'ﾚ': 'レ', 'ﾛ': 'ロ',
    'ﾜ': 'ワ', 'ﾝ': 'ン', 'ﾞ': '゛', 'ﾟ': '゜',
    // 半角カナ濁音・半濁音の結合パターン（先に処理）
    'ｶﾞ': 'ガ', 'ｷﾞ': 'ギ', 'ｸﾞ': 'グ', 'ｹﾞ': 'ゲ', 'ｺﾞ': 'ゴ',
    'ｻﾞ': 'ザ', 'ｼﾞ': 'ジ', 'ｽﾞ': 'ズ', 'ｾﾞ': 'ゼ', 'ｿﾞ': 'ゾ',
    'ﾀﾞ': 'ダ', 'ﾁﾞ': 'ヂ', 'ﾂﾞ': 'ヅ', 'ﾃﾞ': 'デ', 'ﾄﾞ': 'ド',
    'ﾊﾞ': 'バ', 'ﾋﾞ': 'ビ', 'ﾌﾞ': 'ブ', 'ﾍﾞ': 'ベ', 'ﾎﾞ': 'ボ',
    'ﾊﾟ': 'パ', 'ﾋﾟ': 'ピ', 'ﾌﾟ': 'プ', 'ﾍﾟ': 'ペ', 'ﾎﾟ': 'ポ',
    'ｳﾞ': 'ヴ',
  };

  /// ひらがな → カタカナ変換
  /// 例: "たろう" → "タロウ"
  static String hiraganaToKatakana(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (rune >= _hiraganaStart && rune <= _hiraganaEnd) {
        buffer.writeCharCode(rune + _hiraganaToKatakanaDiff);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// カタカナ → ひらがな変換
  /// 例: "タロウ" → "たろう"
  static String katakanaToHiragana(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (rune >= _katakanaStart &&
          rune <= _katakanaStart + (_hiraganaEnd - _hiraganaStart)) {
        buffer.writeCharCode(rune - _hiraganaToKatakanaDiff);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// ふりがなを全角カタカナに正規化する
  ///
  /// 処理内容:
  /// 1. 半角カナ濁音・半濁音の結合パターン（2文字）を全角に変換
  /// 2. 残りの半角カナ（1文字）を全角に変換
  /// 3. ひらがなをカタカナに変換
  /// 4. 余分な空白を除去
  ///
  /// 例: "たろう" → "タロウ"
  ///     "ﾀﾛｳ"   → "タロウ"
  ///     "タロウ"  → "タロウ"（変化なし）
  static String normalizeKana(String text) {
    if (text.isEmpty) return text;

    // Step 1: 半角カナ（濁音・半濁音の2文字結合パターン）を先に処理
    String result = text;
    // 2文字パターンを先に置換（ｶﾞ→ガ など）
    final twoCharPatterns = _halfToFullKana.entries
        .where((e) => e.key.length == 2)
        .toList();
    for (final entry in twoCharPatterns) {
      result = result.replaceAll(entry.key, entry.value);
    }

    // Step 2: 残りの半角カナ（1文字）を全角に変換
    final oneCharPatterns = _halfToFullKana.entries
        .where((e) => e.key.length == 1)
        .toList();
    for (final entry in oneCharPatterns) {
      result = result.replaceAll(entry.key, entry.value);
    }

    // Step 3: ひらがな → カタカナ変換
    result = hiraganaToKatakana(result);

    // Step 4: 余分な空白を除去（前後のみ。中間スペースは保持）
    result = result.trim();

    return result;
  }

  /// 文字列がカタカナのみで構成されているか検証
  static bool isKatakana(String text) {
    if (text.isEmpty) return false;
    return RegExp(r'^[ァ-ヶーｦ-ﾟ\s　]+$').hasMatch(text);
  }

  /// 文字列がひらがな・カタカナ・半角カナのいずれかを含むか
  static bool containsKana(String text) {
    return RegExp(r'[ぁ-んァ-ヶｦ-ﾟ]').hasMatch(text);
  }
}
