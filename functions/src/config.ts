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
  /** 空き枠（先着1名の応募受付・Day 13） */
  slots: 'slots',
  /** webhook 冪等キー（同一 webhookEventId の二重処理を防ぐ・Day 13） */
  webhookProcessed: 'webhook_processed',
  /** 枠の状態変化の監査ログ（Day 13） */
  slotAudit: 'slot_audit',
} as const;

/**
 * 空き枠の受付期限（枠の作成時刻からの既定値）
 *
 * 通知を送った当日の送迎手配に間に合わせる必要があるため、
 * 無期限に応募を受け付けない。期限切れの枠は status='expired' 相当として扱う
 * （バッチで書き換えず、読み出し時に expiresAt を見て判定する）。
 */
export const SLOT_TTL_HOURS = 6;

/** webhook 冪等レコードの保持期間（LINE の再送期間より十分長く取る） */
export const WEBHOOK_PROCESSED_TTL_HOURS = 24;

/**
 * 秘匿値をログ用にマスクする（先頭4文字のみ・残りは長さだけ）
 * トークンそのものは絶対にログへ出さない。
 */
export function maskSecret(value: string | undefined): string {
  if (!value) return '(unset)';
  if (value.length <= 4) return '****';
  return `${value.slice(0, 4)}****(len=${value.length})`;
}
