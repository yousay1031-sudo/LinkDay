/**
 * LINE webhook 署名検証
 *
 * LINE プラットフォームは リクエストボディを
 * チャネルシークレットで HMAC-SHA256 → Base64 したものを
 * `x-line-signature` ヘッダに付与して送信する。
 * この検証を行わないと、第三者が任意の webhook を打ち込めてしまう。
 */
import * as crypto from 'crypto';

/**
 * 署名を検証する。
 *
 * @param rawBody リクエストの生ボディ（パース前の Buffer / 文字列）
 * @param signature `x-line-signature` ヘッダの値
 * @param channelSecret LINE チャネルシークレット
 * @returns 検証に成功したら true
 */
export function verifyLineSignature(
  rawBody: Buffer | string | undefined,
  signature: string | undefined,
  channelSecret: string | undefined
): boolean {
  if (!rawBody || !signature || !channelSecret) return false;

  const body = Buffer.isBuffer(rawBody) ? rawBody : Buffer.from(rawBody, 'utf8');

  const expected = crypto
    .createHmac('sha256', channelSecret)
    .update(body)
    .digest('base64');

  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(signature, 'utf8');
  // 長さが違う場合 timingSafeEqual は例外を投げるため先に判定する
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

/**
 * テスト・ローカル検証用の署名生成ヘルパー。
 * 本番コードパスからは呼ばない。
 */
export function signBodyForTest(
  rawBody: string,
  channelSecret: string
): string {
  return crypto
    .createHmac('sha256', channelSecret)
    .update(Buffer.from(rawBody, 'utf8'))
    .digest('base64');
}
