import 'page_reload_stub.dart' if (dart.library.js_interop) 'page_reload_web.dart'
    as impl;

/// ページを再読み込みする（Web のみ。その他では何もしない）。
///
/// ログアウトで Firestore を終了（terminate）した後は同じインスタンスを
/// 使えないため、再読み込みしてまっさらな状態から始める。
void reloadPage() => impl.reloadPage();
