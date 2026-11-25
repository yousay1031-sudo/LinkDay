#!/usr/bin/env bash
# Auth(9099) / Firestore(8080) / Functions(5001) エミュレータを 127.0.0.1 のみで起動する。
#
# Functions は「個人アカウントの所属の関数」（functions/src/account）だけを読み込む
# （tool/verify/functions_account が入口。LINE の関数 sendVacancyNotice / lineWebhook は
# 読み込まない）。LINE のトークンなどの秘密情報は渡さない（.secret.local を作らない）。
# さらに、エミュレータの Node の処理がループバック以外へ接続しようとしたら止めて
# 記録する（tool/verify/block_external.cjs。記録: $LINKDAY_NET_LOG）。
set -euo pipefail
cd "$(dirname "$0")/../.."
LOG=${LINKDAY_VERIFY_EMU_LOG:-/tmp/linkday_emulators.log}
export LINKDAY_NET_LOG=${LINKDAY_NET_LOG:-/tmp/linkday_emulator_net.log}
if curl -s -m 2 http://127.0.0.1:9099/ | grep -q authEmulator; then
  if ss -ltn | grep -q '127.0.0.1:5001 '; then
    echo "既に起動しています (auth 127.0.0.1:9099 / functions 127.0.0.1:5001)"; exit 0
  fi
  echo "Functions なしの古い構成で起動しています。tool/verify/stop_emulators.sh で止めてから起動し直してください" >&2
  exit 1
fi
# 本番向け資格情報が紛れ込まないようにする
unset GOOGLE_APPLICATION_CREDENTIALS FIREBASE_TOKEN
# LINE の秘密情報を Functions エミュレータへ渡さない
for f in functions/.secret.local tool/verify/functions_account/.secret.local; do
  if [ -e "$f" ]; then echo "$f があります。検証環境では秘密情報を渡さないため中断します" >&2; exit 1; fi
done
unset LINE_CHANNEL_ACCESS_TOKEN LINE_CHANNEL_SECRET

# Functions をビルドし、検証用の入口から functions/node_modules を使えるようにする
if [ ! -d functions/node_modules ]; then
  echo "functions/node_modules がありません。(cd functions && npm ci --no-audit --no-fund --ignore-scripts) を先に実行してください" >&2
  exit 1
fi
npm --prefix functions run build > /dev/null
ln -sfn ../../../functions/node_modules tool/verify/functions_account/node_modules

: > "$LINKDAY_NET_LOG"
export NO_UPDATE_NOTIFIER=1
# エミュレータ本体が、資格情報を探しに GCE の metadata サーバー（169.254.169.254）へ
# 問い合わせないようにする（2026-11-25 に block_external.cjs の記録で見つけた）
export METADATA_SERVER_DETECTION=none
# Functions の SDK の最新版を調べる `npm show`（registry.npmjs.org）を通信なしにする
# （同上。npm は端末内のキャッシュだけを見て、無ければ調べずに終わる）
export npm_config_offline=true
export NODE_OPTIONS="--require $(pwd)/tool/verify/block_external.cjs ${NODE_OPTIONS:-}"
setsid -f firebase emulators:start -c firebase.emulator.json \
  --only auth,firestore,functions --project demo-linkday > "$LOG" 2>&1 < /dev/null
for i in $(seq 1 120); do
  if curl -s -m 1 http://127.0.0.1:9099/ | grep -q authEmulator \
     && curl -s -m 1 http://127.0.0.1:8080/ | grep -q Ok \
     && grep -q 'claimStaffMembership' "$LOG"; then
    echo "エミュレータ起動OK: auth=127.0.0.1:9099 firestore=127.0.0.1:8080 functions=127.0.0.1:5001 (log: $LOG)"
    echo "外部への接続の記録: $LINKDAY_NET_LOG（$(wc -l < "$LINKDAY_NET_LOG") 件）"
    exit 0
  fi
  sleep 1
done
echo "エミュレータが起動しませんでした。$LOG を確認してください" >&2; exit 1
