import 'dart:js_interop';

import 'package:web/web.dart' as web;

const String _query = '(prefers-reduced-motion: reduce)';

/// CSS の prefers-reduced-motion が reduce か
bool prefersReducedMotion() {
  try {
    return web.window.matchMedia(_query).matches;
  } catch (_) {
    return false;
  }
}

/// 設定変更を購読する。戻り値で購読解除。
void Function()? listenReducedMotion(void Function(bool) onChange) {
  try {
    final mql = web.window.matchMedia(_query);
    final listener = ((web.Event e) {
      onChange(mql.matches);
    }).toJS;
    mql.addEventListener('change', listener);
    return () => mql.removeEventListener('change', listener);
  } catch (_) {
    return null;
  }
}
