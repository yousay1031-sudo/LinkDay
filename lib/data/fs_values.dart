/// Firestore に置く値の変換（全コレクション共通）。
///
/// 日付だけの項目は端末のタイムゾーンでずれないよう "YYYY-MM-DD" の文字列で持つ
/// （設計判断点⑫）。日時（記録時刻など）は Timestamp。
library;

/// DateTime → "YYYY-MM-DD"（null はそのまま）
String? dateOnlyToString(DateTime? d) {
  if (d == null) return null;
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-$m-$day';
}

/// "YYYY-MM-DD" → DateTime（その日の 0 時・端末時刻）。形式違いは null。
DateTime? dateOnlyFromString(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v.trim());
  if (m == null) return null;
  return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

String? readString(Object? v) => v is String ? v : null;

int readInt(Object? v, int fallback) => v is num ? v.toInt() : fallback;

double? readDouble(Object? v) => v is num ? v.toDouble() : null;

List<int> readIntList(Object? v) =>
    v is List ? [for (final e in v) if (e is num) e.toInt()] : <int>[];

List<String> readStringList(Object? v) =>
    v is List ? [for (final e in v) if (e is String) e] : <String>[];

/// Firestore から読んだ値どうし・書く値どうしの比較（List / Map を中身で比べる）。
/// 数値は int と double を同じ値なら等しいとみなす（Firestore は整数値の double を
/// int で返すことがあるため）。
bool fsValueEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is num && b is num) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!fsValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !fsValueEquals(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

/// [next] のうち [base] と値が違う項目だけを返す（[base] に無い項目も含む）
Map<String, dynamic> fsChangedFields(
  Map<String, dynamic>? base,
  Map<String, dynamic> next,
) {
  if (base == null) return Map<String, dynamic>.from(next);
  return {
    for (final e in next.entries)
      if (!base.containsKey(e.key) || !fsValueEquals(base[e.key], e.value))
        e.key: e.value,
  };
}
