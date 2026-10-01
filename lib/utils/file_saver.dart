import 'dart:typed_data';

import 'file_saver_stub.dart'
    if (dart.library.js_interop) 'file_saver_web.dart'
    if (dart.library.io) 'file_saver_io.dart' as impl;

/// ファイル保存（Web: ブラウザダウンロード / Mobile: 保存ダイアログ）
///
/// 戻り値: 保存先パス（Web は null）。キャンセル時は null。
Future<String?> saveBytesToFile({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
}) =>
    impl.saveBytesToFile(bytes: bytes, fileName: fileName, mimeType: mimeType);
