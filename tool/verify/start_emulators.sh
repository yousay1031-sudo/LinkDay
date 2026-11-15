#!/usr/bin/env bash
# Auth(9099) / Firestore(8080) エミュレータを 127.0.0.1 のみで起動する。
# Functions は起動しない（LINE 送信などの外部副作用が起こり得ないようにする）。
set -euo pipefail
cd "$(dirname "$0")/../.."
LOG=${LINKDAY_VERIFY_EMU_LOG:-/tmp/linkday_emulators.log}
if curl -s -m 2 http://127.0.0.1:9099/ | grep -q authEmulator; then
  echo "既に起動しています (auth 127.0.0.1:9099)"; exit 0
fi
# 本番向け資格情報が紛れ込まないようにする
unset GOOGLE_APPLICATION_CREDENTIALS FIREBASE_TOKEN
setsid -f firebase emulators:start -c firebase.emulator.json \
  --only auth,firestore --project demo-linkday > "$LOG" 2>&1 < /dev/null
for i in $(seq 1 90); do
  if curl -s -m 1 http://127.0.0.1:9099/ | grep -q authEmulator \
     && curl -s -m 1 http://127.0.0.1:8080/ | grep -q Ok; then
    echo "エミュレータ起動OK: auth=127.0.0.1:9099 firestore=127.0.0.1:8080 (log: $LOG)"; exit 0
  fi
  sleep 1
done
echo "エミュレータが起動しませんでした。$LOG を確認してください" >&2; exit 1
