/**
 * LinkDay Cloud Functions 共通設定
 *
 * 【セキュリティ最重要】
 * LINE のチャネルアクセストークン / チャネルシークレットは
 * Secret Manager（firebase functions secrets）にのみ保持する。
 *   - ソースコードに literal で書かない
 *   - クライアント（Flutter）へ返さない
 *   - ログに出さない（マスク関数 maskSecret を使う）
 *
 * secrets の設定コマンドは docs/line_official_account_setup.md 参照。
 */
import {defineSecret} from 'firebase-functions/params';

/** デプロイリージョン（東京） */
export const REGION = 'asia-northeast1';

/**
 * LINE Messaging API チャネルアクセストークン（長期）
 * 設定: firebase functions:secrets:set LINE_CHANNEL_ACCESS_TOKEN
 */
export const LINE_CHANNEL_ACCESS_TOKEN = defineSecret(
  'LINE_CHANNEL_ACCESS_TOKEN'
);

/**
 * LINE チャネルシークレット（webhook 署名検証用）
 * 設定: firebase functions:secrets:set LINE_CHANNEL_SECRET
 */
export const LINE_CHANNEL_SECRET = defineSecret('LINE_CHANNEL_SECRET');

/** Firestore コレクション名 */
export const COLLECTIONS = {
  /** LINE 連携済み（customerId ↔ lineUserId） */
  lineLinkage: 'line_linkage',
  /** 連携コード（6桁英数・有効期限7日） */
  linkingCodes: 'linking_codes',
  /** 通知送信ログ（冪等キー兼用） */
  notificationLogs: 'notification_logs',
} as const;

/**
 * 秘匿値をログ用にマスクする（先頭4文字のみ・残りは長さだけ）
 * トークンそのものは絶対にログへ出さない。
 */
export function maskSecret(value: string | undefined): string {
  if (!value) return '(unset)';
  if (value.length <= 4) return '****';
  return `${value.slice(0, 4)}****(len=${value.length})`;
}
