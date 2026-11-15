/// 非同期読込の「最新の依頼」だけを採用するための世代カウンタ。
///
/// 日付や週を素早く切り替えたとき、先に始めた遅い読込の結果が
/// 後から届いて新しい画面を上書きするのを防ぐ。
///
/// ```dart
/// final token = _seq.begin();
/// final data = await load();
/// if (!mounted || !_seq.isCurrent(token)) return; // 古い結果は捨てる
/// ```
class LoadSequencer {
  int _generation = 0;

  /// 新しい読込を開始し、その世代番号を返す（以前の世代はすべて無効になる）
  int begin() => ++_generation;

  /// [token] が最新の読込か
  bool isCurrent(int token) => token == _generation;

  /// 進行中の読込をすべて無効にする（dispose 時など）
  void invalidate() => _generation++;
}
