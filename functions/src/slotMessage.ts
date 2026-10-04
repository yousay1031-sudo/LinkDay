/**
 * 空き枠通知の Flex Message 組み立て（Day 13）
 *
 * 【postback data の設計方針】
 * LINE の postback action の `data` は **最大 300 文字**（API 仕様）。
 * 余裕を持たせるため、キー名を 1〜2 文字に切り詰めた JSON を使う。
 *   { v:1, a:'claim'|'release', s:slotId, c:linkCode }
 *
 * data はユーザー端末を経由して戻ってくる＝**改ざんされうる**前提で扱う。
 * そのため、
 *   - 応募者の身元は data ではなく **webhook の source.userId**（LINE 署名で保護）で判定する
 *   - data 内の customerId は信用しない（slotId と linkCode のみ）
 *   - linkCode は「その通知を受け取った本人か」の簡易確認にのみ使う
 * という方針にしている。data を書き換えても他人の枠は取れない。
 *
 * 仕様参照:
 *  - アクション: https://developers.line.biz/en/docs/messaging-api/actions/
 *  - Flex Message: https://developers.line.biz/en/reference/messaging-api/#flex-message
 */

/** postback data のバージョン（将来の形式変更に備える） */
export const POSTBACK_VERSION = 1;

/** LINE postback data の最大長（API 仕様） */
export const POSTBACK_DATA_MAX_LENGTH = 300;

/** 応募／キャンセルのアクション種別 */
export type SlotAction = 'claim' | 'release';

/** パース済み postback data */
export interface SlotPostbackData {
  version: number;
  action: SlotAction;
  slotId: string;
  /** 通知に同梱した短い確認コード（本人性の簡易裏付け） */
  linkCode: string;
}

/**
 * postback data を組み立てる（短縮キーの JSON）
 *
 * @throws 300 文字を超える場合（slotId が異常に長いなど）
 */
export function buildPostbackData(
  action: SlotAction,
  slotId: string,
  linkCode: string
): string {
  const json = JSON.stringify({
    v: POSTBACK_VERSION,
    a: action,
    s: slotId,
    c: linkCode,
  });
  if (json.length > POSTBACK_DATA_MAX_LENGTH) {
    throw new Error(
      `postback data が長すぎます（${json.length} > ${POSTBACK_DATA_MAX_LENGTH}）`
    );
  }
  return json;
}

/**
 * postback data をパースする。
 *
 * 不正・未知バージョンは null を返す（例外を投げない）。
 * webhook は常に 200 を返す必要があるため、呼び出し側で握り潰しやすくする。
 */
export function parsePostbackData(raw: unknown): SlotPostbackData | null {
  if (typeof raw !== 'string' || raw.length === 0) return null;
  if (raw.length > POSTBACK_DATA_MAX_LENGTH) return null;

  let obj: unknown;
  try {
    obj = JSON.parse(raw);
  } catch {
    return null;
  }
  if (obj === null || typeof obj !== 'object') return null;
  const o = obj as Record<string, unknown>;

  const version = typeof o.v === 'number' ? o.v : 0;
  if (version !== POSTBACK_VERSION) return null;

  const action = o.a === 'claim' || o.a === 'release' ? o.a : null;
  if (action === null) return null;

  const slotId = typeof o.s === 'string' ? o.s.trim() : '';
  if (slotId.length === 0 || slotId.length > 128) return null;
  // slotId は {YYYY-MM-DD}_{customerId} 形式。パス区切りの混入を拒否する。
  if (slotId.includes('/') || slotId.includes('..')) return null;

  const linkCode = typeof o.c === 'string' ? o.c.trim() : '';
  if (linkCode.length === 0 || linkCode.length > 32) return null;

  return {version, action, slotId, linkCode};
}

/**
 * 表示用に時刻を JST の「HH時MM分」へ。
 *
 * Cloud Functions のタイムゾーンは UTC のため、+9 時間して日本時間にする。
 * 日付をまたぐ場合（例: UTC 17:00 → JST 翌 2:00）も 24 で丸めて表示する。
 */
export function formatTimeJst(d: Date): string {
  const jst = new Date(d.getTime() + 9 * 60 * 60 * 1000);
  const hh = jst.getUTCHours();
  const mm = String(jst.getUTCMinutes()).padStart(2, '0');
  return `${hh}時${mm}分`;
}

/** 表示用に日付を「10月3日(金)」形式へ */
export function formatDateJa(dateKey: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateKey);
  if (!m) return dateKey;
  const y = parseInt(m[1], 10);
  const mo = parseInt(m[2], 10);
  const d = parseInt(m[3], 10);
  const probe = new Date(Date.UTC(y, mo - 1, d));
  const wd = ['日', '月', '火', '水', '木', '金', '土'][probe.getUTCDay()];
  return `${mo}月${d}日(${wd})`;
}

/**
 * 応募ボタン付き Flex Message を組み立てる。
 *
 * body は既存の通知文面をそのまま載せ、footer にボタンを 1 つだけ足す。
 * （既存の文面生成ロジックには手を入れない方針）
 */
export function buildVacancyFlexMessage(params: {
  dateKey: string;
  message: string;
  slotId: string;
  linkCode: string;
  /** 受付期限（表示用） */
  expiresAt: Date;
}): unknown {
  const {dateKey, message, slotId, linkCode, expiresAt} = params;

  const deadline = formatTimeJst(expiresAt);

  return {
    type: 'flex',
    altText: `【空き枠のお知らせ】${formatDateJa(dateKey)}`,
    contents: {
      type: 'bubble',
      body: {
        type: 'box',
        layout: 'vertical',
        spacing: 'md',
        contents: [
          {
            type: 'text',
            text: '空き枠のお知らせ',
            weight: 'bold',
            size: 'lg',
            color: '#FF6B35',
          },
          {
            type: 'text',
            text: formatDateJa(dateKey),
            size: 'sm',
            color: '#666666',
          },
          {
            type: 'separator',
            margin: 'md',
          },
          {
            type: 'text',
            text: message,
            wrap: true,
            size: 'sm',
            margin: 'md',
          },
          {
            type: 'text',
            text: `先着1名です。${deadline}までにお申し込みください。`,
            wrap: true,
            size: 'xs',
            color: '#999999',
            margin: 'md',
          },
        ],
      },
      footer: {
        type: 'box',
        layout: 'vertical',
        contents: [
          {
            type: 'button',
            action: {
              type: 'postback',
              label: '【応募する】先着1名',
              data: buildPostbackData('claim', slotId, linkCode),
              displayText: '応募します',
            },
            style: 'primary',
            color: '#FF6B35',
          },
        ],
      },
    },
  };
}

/**
 * 応募確定後に送る「キャンセルできます」案内（Flex）
 *
 * 確定した保護者にだけ送る。キャンセルボタンを 1 つ持つ。
 */
export function buildClaimedFlexMessage(params: {
  dateKey: string;
  slotId: string;
  linkCode: string;
}): unknown {
  const {dateKey, slotId, linkCode} = params;
  return {
    type: 'flex',
    altText: `【確定】${formatDateJa(dateKey)}のご利用が確定しました`,
    contents: {
      type: 'bubble',
      body: {
        type: 'box',
        layout: 'vertical',
        spacing: 'md',
        contents: [
          {
            type: 'text',
            text: 'ご利用が確定しました',
            weight: 'bold',
            size: 'lg',
            color: '#2E7D32',
          },
          {
            type: 'text',
            text: formatDateJa(dateKey),
            size: 'sm',
            color: '#666666',
          },
          {
            type: 'separator',
            margin: 'md',
          },
          {
            type: 'text',
            text:
              'この日のご利用が確定しました。\n' +
              '送迎の時間などは施設からご連絡します。\n\n' +
              'ご都合が変わった場合は、下のボタンから取り消してください。',
            wrap: true,
            size: 'sm',
            margin: 'md',
          },
        ],
      },
      footer: {
        type: 'box',
        layout: 'vertical',
        contents: [
          {
            type: 'button',
            action: {
              type: 'postback',
              label: 'キャンセルする',
              data: buildPostbackData('release', slotId, linkCode),
              displayText: 'キャンセルします',
            },
            style: 'secondary',
          },
        ],
      },
    },
  };
}
