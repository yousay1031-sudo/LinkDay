/**
 * jose@6（ESM 専用）の Jest 用スタブ。
 * firebase-admin 14 → jwks-rsa 4 → jose 6 が ESM 専用で、Jest 29 の CJS サンドボックスでは
 * 読み込めないため差し替える。テストは JWT 検証を行わない（Auth はモック）。
 * 本番ランタイム（Node 22 の require(esm)）では実物の jose がそのまま使われる。
 */
function unavailable(name) {
  return () => {
    throw new Error(`jose.${name} はテスト用スタブです（実装なし）`);
  };
}
module.exports = new Proxy({}, {
  get: (_t, prop) => (prop === '__esModule' ? false : unavailable(String(prop))),
});
