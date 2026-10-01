import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Mobile/Desktop: 保存ダイアログ（bytes 指定で直接書き込み）
Future<String?> saveBytesToFile({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
}) async {
  final ext = fileName.contains('.') ? fileName.split('.').last : null;
  return FilePicker.platform.saveFile(
    dialogTitle: 'ファイルを保存',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: ext != null ? [ext] : null,
    bytes: bytes,
  );
}
