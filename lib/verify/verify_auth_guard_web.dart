import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// firebase_core_web は Auth の JS モジュールを window.firebase_auth に代入する。
// その代入を受け取り、initializeAuth だけを包んだ写しを置く。
const _windowVar = 'firebase_auth';

bool _connected = false;
bool _installed = false;

bool get connected => _connected;

@JS('Object.defineProperty')
external void _defineProperty(JSObject target, JSString key, JSObject desc);

@JS('Object.assign')
external JSObject _assign(JSObject target, JSObject source);

bool install(String origin) {
  if (_installed) return true;
  JSObject? stored;

  JSObject wrap(JSObject module) {
    final copy = _assign(JSObject(), module);
    final original = module['initializeAuth'] as JSFunction;
    final connect = module['connectAuthEmulator'] as JSFunction;
    copy['initializeAuth'] = ((JSAny app, JSAny? deps) {
      final auth = original.callAsFunction(module, app, deps);
      // Auth を作った直後・保存済みログインの確認通信より前にエミュレータへ向ける
      connect.callAsFunction(module, auth, origin.toJS);
      _connected = true;
      return auth;
    }).toJS;
    return copy;
  }

  final desc = JSObject()
    ..['configurable'] = true.toJS
    ..['enumerable'] = true.toJS
    ..['get'] = (() => stored).toJS
    ..['set'] = ((JSObject module) {
      stored = wrap(module);
    }).toJS;
  try {
    // 既に読み込み済み（＝包めない）なら失敗として扱う
    if (globalContext.has(_windowVar)) return false;
    _defineProperty(globalContext, _windowVar.toJS, desc);
  } catch (_) {
    return false;
  }
  _installed = true;
  return true;
}
