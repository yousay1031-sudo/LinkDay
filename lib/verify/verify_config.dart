/// ローカル検証構成（Day 15）のコンパイル時設定。
///
/// 【設計】
/// - 切替は `--dart-define` のみ。debug/profile/release のどのビルドでも同じに動く
///   （`kDebugMode` には依存しない）。
/// - 既定は **すべて無効**。通常ビルド（define なし）では [enabled] が
///   コンパイル時定数 false になり、これを参照する分岐（エミュレータ接続・
///   ダミー投入・故障注入）は dart2js の tree-shaking で出力から消える。
/// - 検証構成では専用の `demo-*` プロジェクト ID だけを使い、
///   本番の [DefaultFirebaseOptions] には一切触れない。
///
/// ビルド手順は docs/VERIFY_ENV.md を参照。
class VerifyConfig {
  VerifyConfig._();

  /// 検証構成か（`--dart-define=LINKDAY_VERIFY=true`）
  static const bool enabled = bool.fromEnvironment('LINKDAY_VERIFY');

  /// 検証専用の Firebase プロジェクト ID（必ず `demo-` で始まること）
  static const String projectId = String.fromEnvironment(
    'LINKDAY_VERIFY_PROJECT',
    defaultValue: 'demo-linkday',
  );

  /// エミュレータのホスト（ループバックのみ許可）
  static const String emulatorHost = String.fromEnvironment(
    'LINKDAY_VERIFY_HOST',
    defaultValue: '127.0.0.1',
  );

  static const int authPort =
      int.fromEnvironment('LINKDAY_VERIFY_AUTH_PORT', defaultValue: 9099);

  static const int firestorePort =
      int.fromEnvironment('LINKDAY_VERIFY_FIRESTORE_PORT', defaultValue: 8080);

  /// 接続を許すホスト（外部ホストへの接続を構成の段階で拒否する）
  static const Set<String> allowedHosts = {'127.0.0.1', 'localhost', '[::1]'};

  /// 設定値を検証し、問題点の一覧を返す（空なら有効）。
  ///
  /// 引数を渡せるのはテストのため。既定は現在のコンパイル時設定。
  static List<String> validate({
    String? project,
    String? host,
    int? authPortOverride,
    int? firestorePortOverride,
  }) {
    final p = project ?? projectId;
    final h = host ?? emulatorHost;
    final ap = authPortOverride ?? authPort;
    final fp = firestorePortOverride ?? firestorePort;
    final problems = <String>[];
    if (!p.startsWith('demo-')) {
      problems.add('プロジェクトIDが demo- で始まっていません: $p');
    }
    if (p == 'linkday-proud') {
      problems.add('本番プロジェクトIDは検証構成で使えません');
    }
    if (!allowedHosts.contains(h)) {
      problems.add('エミュレータのホストがループバックではありません: $h');
    }
    if (ap < 1 || ap > 65535) problems.add('Auth ポートが不正です: $ap');
    if (fp < 1 || fp > 65535) problems.add('Firestore ポートが不正です: $fp');
    if (ap == fp) problems.add('Auth と Firestore のポートが同じです');
    return problems;
  }
}
