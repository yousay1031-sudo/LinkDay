import 'fs_values.dart';

/// 自分の書き込みの「遅れて届いた折り返し」を見分ける。
///
/// 保存すると画面用の内容（キャッシュ）はすぐ新しい内容にし、保存先へは待たずに送る。
/// 保存先の購読（snapshots）は書き込みごとに、その時点の内容を後から届ける。
/// 続けて 2 回保存すると「1 回目の内容」が 2 回目の保存の後に届き、他の端末の変更と
/// 区別できずにキャッシュを 1 回目の内容に戻してしまっていた（次の折り返しで直るが、
/// その間は古い内容が見える）。
///
/// 送った内容を順に覚えておき、届いた内容が「まだ折り返しの届いていない、
/// 最後ではない自分の書き込み」と同じなら古い折り返しとして無視する。
/// どれとも同じでなければ他の端末の変更として扱う。
class PendingEchoes {
  final List<Map<String, dynamic>> _sent = [];

  /// 覚えておく数の上限（送信に失敗して折り返しが来ない場合に増え続けないように）
  static const int _max = 50;

  /// 保存先へ送った内容（正規化したもの）を覚える
  void add(Map<String, dynamic> normalized) {
    _sent.add(normalized);
    if (_sent.length > _max) _sent.removeAt(0);
  }

  /// 届いた内容が、自分の古い書き込みの折り返しなら true（無視してよい）
  bool isStaleEcho(Map<String, dynamic> normalized) {
    final i = _sent.indexWhere((s) => fsChangedFields(s, normalized).isEmpty);
    if (i < 0) return false; // 自分の書き込みではない（他の端末の変更など）
    final isLatest = i == _sent.length - 1;
    _sent.removeRange(0, i + 1); // ここまでの折り返しは届いた
    return !isLatest;
  }

  bool get isEmpty => _sent.isEmpty;

  void clear() => _sent.clear();
}
