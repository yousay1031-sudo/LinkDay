import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 静的ガード: lib 配下の「実コード」だけを検査する（コメント・文字列は除外）。
/// - 背景ぼかし（BackdropFilter / ImageFilter.blur）の使用禁止
/// - 影の blurRadius は 16 以下（AppMotion.maxShadowBlur）
///
/// 簡易トークナイザで //・/* */・'...'・"..."（三連引用符・raw 含む）を空白に置換してから正規表現を当てる。
String stripCommentsAndStrings(String src) {
  final out = StringBuffer();
  var i = 0;
  final n = src.length;
  while (i < n) {
    final c = src[i];
    final next = i + 1 < n ? src[i + 1] : '';
    if (c == '/' && next == '/') {
      while (i < n && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && next == '*') {
      var depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (src.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (src.startsWith('*/', i)) {
          depth--;
          i += 2;
        } else {
          if (src[i] == '\n') out.write('\n');
          i++;
        }
      }
    } else if (c == "'" || c == '"') {
      final raw = i > 0 && src[i - 1] == 'r';
      final triple = src.startsWith(c * 3, i);
      final q = triple ? c * 3 : c;
      i += q.length;
      while (i < n && !src.startsWith(q, i)) {
        if (!raw && src[i] == '\\') i++;
        if (i < n && src[i] == '\n') out.write('\n');
        i++;
      }
      i += q.length;
      out.write('""');
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

List<File> libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  group('stripCommentsAndStrings（誤検知防止）', () {
    test('コメント・文字列内の禁止語は除去される', () {
      const src = '''
// BackdropFilter は使わない
/* ImageFilter.blur(sigmaX: 1) */
const a = 'BackdropFilter';
const b = "blurRadius: 40";
const c = \'\'\'ImageFilter.blur\'\'\';
final d = r'BackdropFilter';
''';
      final s = stripCommentsAndStrings(src);
      expect(s.contains('BackdropFilter'), isFalse);
      expect(s.contains('ImageFilter'), isFalse);
      expect(s.contains('blurRadius'), isFalse);
    });
    test('実コードの禁止 API は残る', () {
      const src = 'final w = BackdropFilter(filter: ImageFilter.blur(sigmaX: 4));\n'
          'final s = BoxShadow(blurRadius: 40);';
      final s = stripCommentsAndStrings(src);
      expect(RegExp(r'\bBackdropFilter\b').hasMatch(s), isTrue);
      expect(RegExp(r'ImageFilter\s*\.\s*blur').hasMatch(s), isTrue);
      expect(RegExp(r'blurRadius\s*:\s*40').hasMatch(s), isTrue);
    });
  });

  test('lib に BackdropFilter / ImageFilter.blur の実使用がない', () {
    final bad = <String>[];
    for (final f in libFiles()) {
      final s = stripCommentsAndStrings(f.readAsStringSync());
      if (RegExp(r'\bBackdropFilter\b').hasMatch(s) ||
          RegExp(r'ImageFilter\s*\.\s*blur').hasMatch(s)) {
        bad.add(f.path);
      }
    }
    expect(bad, isEmpty, reason: '背景ぼかしは使用禁止: $bad');
  });

  test('lib の blurRadius リテラルは 16 以下', () {
    final bad = <String>[];
    for (final f in libFiles()) {
      final s = stripCommentsAndStrings(f.readAsStringSync());
      for (final m in RegExp(r'blurRadius\s*:\s*([0-9.]+)').allMatches(s)) {
        if (double.parse(m.group(1)!) > 16) bad.add('${f.path}: ${m.group(0)}');
      }
    }
    expect(bad, isEmpty, reason: '影のぼかしは 16 以下: $bad');
  });
}
